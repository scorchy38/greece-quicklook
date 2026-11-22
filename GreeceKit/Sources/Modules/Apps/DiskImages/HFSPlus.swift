import Foundation

/// Mac OS Extended (HFS+ and HFSX), read from its catalog B-tree without mounting.
final class HFSPlusVolume: DiskFileSystem {
    struct Extent { var start: UInt32; var count: UInt32 }
    struct Fork {
        var logicalSize: UInt64
        var totalBlocks: UInt32
        var extents: [Extent]
    }

    struct Item {
        var id: UInt32
        var parent: UInt32
        var name: String
        var isFolder: Bool
        var mode: UInt16
        var ownerFlags: UInt8
        var fileType: UInt32
        var creator: UInt32
        var special: UInt32
        var modified: Date?
        var dataFork: Fork?
        var resourceFork: Fork?
        var isSymlink: Bool { mode & 0xF000 == 0xA000 }
        var isHardLink: Bool { fileType == 0x686C_6E6B && creator == 0x6866_732B }   // 'hlnk' 'hfs+'
        var isCompressed: Bool { ownerFlags & 0x20 != 0 }
    }

    static let maximumItems = 400_000
    static let rootID: UInt32 = 2

    let kind: FileSystemKind
    let blockSize: UInt64
    let totalBlocks: UInt64
    let freeBlocks: UInt64
    let fileCount: UInt32
    let folderCount: UInt32
    private let device: DiskDevice
    private let catalog: HFSBTree
    private let extentsTree: HFSBTree?
    private let attributesTree: HFSBTree?

    private(set) var volumeName = ""
    private var items: [UInt32: Item] = [:]
    private var children: [UInt32: [UInt32]] = [:]
    private var scanned = false
    private var scanTruncated = false
    private var decmpfs: [UInt32: Data]?

    var usedBytes: UInt64? { (totalBlocks - min(freeBlocks, totalBlocks)) * blockSize }
    var capacity: UInt64? { totalBlocks * blockSize }

    init(device: DiskDevice) throws {
        var volume: DiskDevice = device
        guard let header = try? device.read(at: 1024, count: 512), header.count == 512 else { throw DiskImageError.corrupt("HFS+ header") }
        var r = BinaryReader(header, bigEndian: true)
        // An HFS+ volume wrapped in a classic HFS volume: find the embedded one.
        if r.u16(at: 0) == 0x4244, r.u16(at: 124) == 0x482B {
            let allocationBlockSize = UInt64(r.u32(at: 20) ?? 0)
            let firstBlock = UInt64(r.u16(at: 28) ?? 0)
            let embeddedStart = UInt64(r.u16(at: 126) ?? 0)
            let embeddedCount = UInt64(r.u16(at: 128) ?? 0)
            let start = firstBlock * 512 + embeddedStart * allocationBlockSize
            volume = SliceDevice(device, start: start, length: embeddedCount * allocationBlockSize)
            guard let inner = try? volume.read(at: 1024, count: 512), inner.count == 512 else { throw DiskImageError.corrupt("embedded HFS+") }
            r = BinaryReader(inner, bigEndian: true)
        }
        switch r.u16(at: 0) {
        case 0x482B: kind = .hfsPlus
        case 0x4858: kind = .hfsX
        default: throw DiskImageError.notADiskImage
        }
        guard let size = r.u32(at: 40), size >= 512, size <= 1 << 26, size % 512 == 0 else { throw DiskImageError.corrupt("block size") }
        self.device = volume
        blockSize = UInt64(size)
        totalBlocks = UInt64(r.u32(at: 44) ?? 0)
        freeBlocks = UInt64(r.u32(at: 48) ?? 0)
        fileCount = r.u32(at: 32) ?? 0
        folderCount = r.u32(at: 36) ?? 0

        func fork(at offset: Int) -> Fork {
            var extents: [Extent] = []
            for index in 0..<8 {
                let start = r.u32(at: offset + 16 + index * 8) ?? 0
                let count = r.u32(at: offset + 20 + index * 8) ?? 0
                if count > 0 { extents.append(Extent(start: start, count: count)) }
            }
            return Fork(logicalSize: r.u64(at: offset) ?? 0, totalBlocks: r.u32(at: offset + 12) ?? 0, extents: extents)
        }
        let extentsFork = fork(at: 192)
        let catalogFork = fork(at: 272)
        let attributesFork = fork(at: 352)
        extentsTree = extentsFork.logicalSize > 0 ? try? HFSBTree(reader: HFSForkReader(device: volume, blockSize: blockSize, fork: extentsFork)) : nil
        let overflow = extentsTree
        func fullFork(_ fork: Fork, id: UInt32) -> Fork {
            HFSPlusVolume.complete(fork, fileID: id, forkType: 0, extents: overflow)
        }
        catalog = try HFSBTree(reader: HFSForkReader(device: volume, blockSize: blockSize, fork: fullFork(catalogFork, id: 4)))
        attributesTree = attributesFork.logicalSize > 0
            ? try? HFSBTree(reader: HFSForkReader(device: volume, blockSize: blockSize, fork: fullFork(attributesFork, id: 8))) : nil
    }

    /// Adds extents from the overflow tree when the eight in the catalog don't cover the fork.
    static func complete(_ fork: Fork, fileID: UInt32, forkType: UInt8, extents tree: HFSBTree?) -> Fork {
        let covered = fork.extents.reduce(UInt64(0)) { $0 + UInt64($1.count) }
        guard covered < UInt64(fork.totalBlocks), let tree else { return fork }
        var result = fork
        var found: [(UInt32, [Extent])] = []
        tree.forEachLeafRecord(deadline: DiskDeadline(seconds: 0.5)) { key, value in
            let k = BinaryReader(key, bigEndian: true)
            guard k.u8(at: 2) == forkType, k.u32(at: 4) == fileID, let startBlock = k.u32(at: 8) else { return true }
            let v = BinaryReader(value, bigEndian: true)
            var list: [Extent] = []
            for index in 0..<8 {
                let start = v.u32(at: index * 8) ?? 0
                let count = v.u32(at: index * 8 + 4) ?? 0
                if count > 0 { list.append(Extent(start: start, count: count)) }
            }
            found.append((startBlock, list))
            return found.count < 4096
        }
        for (_, list) in found.sorted(by: { $0.0 < $1.0 }) { result.extents += list }
        return result
    }

    // MARK: Catalog

    private func scan(deadline: DiskDeadline) {
        guard !scanned else { return }
        scanned = true
        var count = 0
        let completed = catalog.forEachLeafRecord(deadline: deadline) { key, value in
            let k = BinaryReader(key, bigEndian: true)
            let v = BinaryReader(value, bigEndian: true)
            guard let parent = k.u32(at: 2), let type = v.u16(at: 0), type == 1 || type == 2 else { return true }
            let nameLength = Int(min(k.u16(at: 6) ?? 0, 255))
            var units: [UInt16] = []
            units.reserveCapacity(nameLength)
            for index in 0..<nameLength { if let unit = k.u16(at: 8 + index * 2) { units.append(unit) } }
            let name = String(decoding: units, as: UTF16.self).precomposedStringWithCanonicalMapping
                .replacingOccurrences(of: "/", with: ":")
            func date(_ at: Int) -> Date? {
                guard let seconds = v.u32(at: at), seconds > 0 else { return nil }
                return Date(timeIntervalSince1970: TimeInterval(seconds) - 2_082_844_800)
            }
            func fork(_ at: Int) -> Fork {
                var extents: [Extent] = []
                for index in 0..<8 {
                    let start = v.u32(at: at + 16 + index * 8) ?? 0
                    let blocks = v.u32(at: at + 20 + index * 8) ?? 0
                    if blocks > 0 { extents.append(Extent(start: start, count: blocks)) }
                }
                return Fork(logicalSize: v.u64(at: at) ?? 0, totalBlocks: v.u32(at: at + 12) ?? 0, extents: extents)
            }
            guard let id = v.u32(at: 8) else { return true }
            let item = Item(id: id, parent: parent, name: name, isFolder: type == 1, mode: v.u16(at: 42) ?? 0,
                            ownerFlags: v.u8(at: 41) ?? 0, fileType: v.u32(at: 48) ?? 0, creator: v.u32(at: 52) ?? 0,
                            special: v.u32(at: 44) ?? 0, modified: date(16),
                            dataFork: type == 2 ? fork(88) : nil, resourceFork: type == 2 ? fork(168) : nil)
            if id == HFSPlusVolume.rootID && type == 1 { volumeName = name }
            if items[id] == nil {
                items[id] = item
                children[parent, default: []].append(id)
            }
            count += 1
            return count < HFSPlusVolume.maximumItems
        }
        scanTruncated = !completed
    }

    private static let hiddenSystemNames: Set<String> = ["\u{0}\u{0}\u{0}\u{0}HFS+ Private Data", ".HFS+ Private Directory Data\r",
                                                       ".journal", ".journal_info_block"]

    func entries(limit: Int, deadline: DiskDeadline) throws -> (entries: [VolumeEntry], truncated: Bool) {
        scan(deadline: deadline)
        let sizes = compressedSizes(deadline: deadline)
        var hardLinkTargets: [UInt32: Item] = [:]
        if let privateDir = children[HFSPlusVolume.rootID]?.compactMap({ items[$0] }).first(where: { $0.name == "\u{0}\u{0}\u{0}\u{0}HFS+ Private Data" }) {
            for id in children[privateDir.id] ?? [] {
                if let item = items[id], item.name.hasPrefix("iNode"), let number = UInt32(item.name.dropFirst(5)) { hardLinkTargets[number] = item }
            }
        }
        var result: [VolumeEntry] = []
        var truncated = scanTruncated
        // Breadth-first from the root, so a cap keeps the top of the tree.
        var queue: [(UInt32, String, Int)] = [(HFSPlusVolume.rootID, "", 0)]
        var head = 0
        var visited: Set<UInt32> = [HFSPlusVolume.rootID]
        while head < queue.count {
            let (folder, prefix, depth) = queue[head]
            head += 1
            if deadline.expired { truncated = true; break }
            for id in children[folder] ?? [] {
                guard let item = items[id] else { continue }
                if folder == HFSPlusVolume.rootID && HFSPlusVolume.hiddenSystemNames.contains(item.name) { continue }
                if result.count >= limit { truncated = true; break }
                let path = prefix.isEmpty ? item.name : prefix + "/" + item.name
                if item.isFolder {
                    result.append(VolumeEntry(path: path, isDirectory: true, isSymlink: false, size: 0, modified: item.modified))
                    if depth < 128, visited.insert(item.id).inserted { queue.append((item.id, path, depth + 1)) }
                } else {
                    var size = item.dataFork?.logicalSize ?? 0
                    if item.isHardLink, let target = hardLinkTargets[item.special] { size = target.dataFork?.logicalSize ?? size }
                    if item.isCompressed, let real = sizes[item.id] { size = real }
                    result.append(VolumeEntry(path: path, isDirectory: false, isSymlink: item.isSymlink, size: size, modified: item.modified))
                }
            }
        }
        return (result, truncated)
    }

    // MARK: Attributes (compression)

    /// The decmpfs attribute of every compressed file (inline data only), read in one pass.
    private func decmpfsAttributes(deadline: DiskDeadline) -> [UInt32: Data] {
        if let decmpfs { return decmpfs }
        var found: [UInt32: Data] = [:]
        let target = Array("com.apple.decmpfs".utf16)
        attributesTree?.forEachLeafRecord(deadline: deadline) { key, value in
            let k = BinaryReader(key, bigEndian: true)
            guard let fileID = k.u32(at: 4), let nameLength = k.u16(at: 12), Int(nameLength) == target.count else { return true }
            for (index, unit) in target.enumerated() where k.u16(at: 14 + index * 2) != unit { return true }
            let v = BinaryReader(value, bigEndian: true)
            guard v.u32(at: 0) == 0x10, let size = v.u32(at: 12), let data = v.bytes(at: 16, count: Int(min(size, 1 << 20))) else { return true }
            found[fileID] = data
            return found.count < HFSPlusVolume.maximumItems
        }
        decmpfs = found
        return found
    }

    private func compressedSizes(deadline: DiskDeadline) -> [UInt32: UInt64] {
        guard items.values.contains(where: { $0.isCompressed }) else { return [:] }
        return decmpfsAttributes(deadline: deadline).compactMapValues { Decmpfs.header($0)?.size }
    }

    // MARK: Reading

    private func item(at path: String) throws -> Item {
        scan(deadline: DiskDeadline(seconds: 2))
        var current = HFSPlusVolume.rootID
        var found: Item?
        for component in DiskFileSystems.components(path) {
            let target = component.precomposedStringWithCanonicalMapping
            let match = (children[current] ?? []).compactMap { items[$0] }.first {
                kind == .hfsX ? $0.name == target : $0.name.caseInsensitiveCompare(target) == .orderedSame
            }
            guard let match else { throw DiskImageError.corrupt("no such file") }
            found = match
            current = match.id
        }
        guard let found else { throw DiskImageError.corrupt("no such file") }
        return found
    }

    private func forkData(_ fork: Fork, fileID: UInt32, forkType: UInt8, limit: Int) throws -> Data {
        guard fork.logicalSize <= UInt64(limit) else { throw DiskImageError.tooLarge }
        let full = HFSPlusVolume.complete(fork, fileID: fileID, forkType: forkType, extents: extentsTree)
        return try HFSForkReader(device: device, blockSize: blockSize, fork: full).read(at: 0, count: Int(fork.logicalSize))
    }

    func readFile(_ path: String, limit: Int) throws -> Data {
        var item = try item(at: path)
        guard !item.isFolder else { throw DiskImageError.corrupt("folder") }
        if item.isHardLink, let target = (children[HFSPlusVolume.rootID] ?? []).compactMap({ items[$0] })
            .first(where: { $0.name == "\u{0}\u{0}\u{0}\u{0}HFS+ Private Data" })
            .flatMap({ dir in (children[dir.id] ?? []).compactMap { items[$0] }.first { $0.name == "iNode\(item.special)" } }) {
            item = target
        }
        if item.isCompressed, let xattr = decmpfsAttributes(deadline: DiskDeadline(seconds: 1))[item.id] {
            let resource = item.resourceFork
            return try Decmpfs.decompress(xattr: xattr, resourceFork: { [self] in
                guard let resource, resource.logicalSize > 0 else { return nil }
                return try forkData(resource, fileID: item.id, forkType: 0xFF, limit: 256 << 20)
            }, limit: limit)
        }
        guard let fork = item.dataFork else { return Data() }
        return try forkData(fork, fileID: item.id, forkType: 0, limit: limit)
    }

    func linkTarget(_ path: String) throws -> String? {
        let item = try item(at: path)
        guard item.isSymlink, let fork = item.dataFork else { return nil }
        let data = try forkData(fork, fileID: item.id, forkType: 0, limit: 4096)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Reads a fork (a list of extents of allocation blocks) as one contiguous stream.
final class HFSForkReader {
    let device: DiskDevice
    let blockSize: UInt64
    let fork: HFSPlusVolume.Fork

    init(device: DiskDevice, blockSize: UInt64, fork: HFSPlusVolume.Fork) {
        self.device = device
        self.blockSize = blockSize
        self.fork = fork
    }

    var length: UInt64 { fork.logicalSize }

    func read(at offset: UInt64, count: Int) throws -> Data {
        guard offset < fork.logicalSize, count > 0 else { return Data() }
        let total = Int(min(UInt64(count), fork.logicalSize - offset))
        var output = Data(capacity: total)
        var position = offset
        var extentStart: UInt64 = 0
        for extent in fork.extents {
            let extentLength = UInt64(extent.count) * blockSize
            let (extentEnd, overflow) = extentStart.addingReportingOverflow(extentLength)
            if overflow { break }
            if position < extentEnd {
                let within = position - extentStart
                let length = Int(min(UInt64(total - output.count), extentLength - within))
                let chunk = try device.read(at: UInt64(extent.start) * blockSize + within, count: length)
                output.append(chunk)
                if chunk.count < length { break }
                position += UInt64(length)
                if output.count >= total { break }
            }
            extentStart = extentEnd
        }
        if output.count < total { output.append(Data(count: total - output.count)) }
        return output
    }
}

/// An HFS+ B-tree (catalog, extents overflow, attributes): node 0 is the header, leaves are linked.
final class HFSBTree {
    let reader: HFSForkReader
    let nodeSize: Int
    let firstLeaf: UInt32
    let totalNodes: UInt32

    init(reader: HFSForkReader) throws {
        self.reader = reader
        let header = try reader.read(at: 0, count: 512)
        let r = BinaryReader(header, bigEndian: true)
        guard header.count >= 106, r.u8(at: 8) == 1 /* header node */, let size = r.u16(at: 14 + 18),
              [512, 1024, 2048, 4096, 8192, 16384, 32768].contains(Int(size)) else { throw DiskImageError.corrupt("B-tree header") }
        nodeSize = Int(size)
        firstLeaf = r.u32(at: 14 + 10) ?? 0
        totalNodes = r.u32(at: 14 + 22) ?? 0
    }

    /// Calls `body` with each leaf record's key and value, following the leaf chain. Returns false if it
    /// stopped early (deadline, a loop, or `body` returning false).
    @discardableResult
    func forEachLeafRecord(deadline: DiskDeadline, _ body: (Data, Data) -> Bool) -> Bool {
        var node = firstLeaf
        var visited = Set<UInt32>()
        while node != 0 {
            guard node < max(totalNodes, 1), visited.insert(node).inserted, !deadline.expired else { return false }
            guard let data = try? reader.read(at: UInt64(node) * UInt64(nodeSize), count: nodeSize), data.count == nodeSize else { return false }
            let r = BinaryReader(data, bigEndian: true)
            guard Int8(bitPattern: r.u8(at: 8) ?? 0) == -1 /* leaf */ else { return false }
            let count = Int(r.u16(at: 10) ?? 0)
            for index in 0..<min(count, nodeSize / 2) {
                guard let start = r.u16(at: nodeSize - 2 * (index + 1)).map(Int.init),
                      let end = r.u16(at: nodeSize - 2 * (index + 2)).map(Int.init),
                      start >= 14, end > start, end <= nodeSize,
                      let keyLength = r.u16(at: start).map(Int.init) else { continue }
                let valueStart = start + 2 + keyLength
                guard valueStart <= end else { continue }
                let key = data.subdata(in: start..<(valueStart))
                let value = data.subdata(in: valueStart..<end)
                if !body(key, value) { return false }
            }
            node = r.u32(at: 0) ?? 0
        }
        return true
    }
}
