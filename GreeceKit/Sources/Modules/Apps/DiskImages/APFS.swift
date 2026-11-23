import Foundation

/// An APFS container: finds the latest checkpoint, its object map, and the volumes in it.
/// Layout from Apple's "Apple File System Reference" (all little-endian).
final class APFSContainer {
    let device: DiskDevice
    let blockSize: Int
    let blockCount: UInt64
    let xid: UInt64
    let volumeOIDs: [UInt64]
    private let omapRoot: UInt64

    static let maximumNodes = 200_000

    init(device: DiskDevice) throws {
        self.device = device
        guard let first = try? device.read(at: 0, count: 4096), first.count == 4096 else { throw DiskImageError.corrupt("APFS superblock") }
        let r = BinaryReader(first)
        guard r.bytes(at: 32, count: 4) == Data("NXSB".utf8), let size = r.u32(at: 36), [4096, 8192, 16384, 32768, 65536].contains(Int(size)) else {
            throw DiskImageError.notADiskImage
        }
        blockSize = Int(size)
        var best = first.count == blockSize ? first : (try device.readExactly(at: 0, count: blockSize))
        // The checkpoint descriptor area holds newer copies of the superblock; the highest valid xid wins.
        let descriptorBase = r.u64(at: 112) ?? 0
        let descriptorBlocks = r.u32(at: 104) ?? 0
        var bestXID = BinaryReader(best).u64(at: 16) ?? 0
        if descriptorBlocks & 0x8000_0000 == 0 {
            for index in 0..<UInt64(min(descriptorBlocks, 4096)) {
                let (address, o1) = descriptorBase.addingReportingOverflow(index)
                let (offset, o2) = address.multipliedReportingOverflow(by: UInt64(blockSize))
                guard !o1, !o2, let block = try? device.read(at: offset, count: blockSize), block.count == blockSize else { break }
                let b = BinaryReader(block)
                guard b.bytes(at: 32, count: 4) == Data("NXSB".utf8), (b.u32(at: 24) ?? 0) & 0xFFFF == 1,
                      let xid = b.u64(at: 16), xid > bestXID, APFSContainer.checksumValid(block) else { continue }
                best = block
                bestXID = xid
            }
        }
        xid = bestXID
        let s = BinaryReader(best)
        blockCount = s.u64(at: 40) ?? 0
        let maxVolumes = Int(min(s.u32(at: 180) ?? 0, 100))
        volumeOIDs = (0..<maxVolumes).compactMap { s.u64(at: 184 + $0 * 8) }.filter { $0 != 0 }
        guard let omap = s.u64(at: 160), !omap.multipliedReportingOverflow(by: UInt64(blockSize)).overflow,
              let omapBlock = try? device.readExactly(at: omap * UInt64(blockSize), count: blockSize),
              let root = BinaryReader(omapBlock).u64(at: 48) else {
            throw DiskImageError.corrupt("APFS object map")
        }
        omapRoot = root
    }

    func block(_ address: UInt64) throws -> Data {
        let (offset, overflow) = address.multipliedReportingOverflow(by: UInt64(blockSize))
        guard !overflow, address < max(blockCount, 1) || blockCount == 0 else { throw DiskImageError.corrupt("block out of range") }
        return try device.readExactly(at: offset, count: blockSize)
    }

    /// Resolves a virtual object id through an object map tree (physical nodes).
    func lookup(_ oid: UInt64, xid: UInt64, omapRoot root: UInt64) throws -> UInt64? {
        var address = root
        for _ in 0..<16 {
            let node = try APFSNode(try block(address), blockSize: blockSize)
            if node.isLeaf {
                var best: (xid: UInt64, address: UInt64)?
                for index in 0..<node.count {
                    guard let (key, value) = node.entry(index, fixedKey: 16, fixedValue: 16) else { continue }
                    let k = BinaryReader(key), v = BinaryReader(value)
                    guard k.u64(at: 0) == oid, let entryXID = k.u64(at: 8), entryXID <= xid, let paddr = v.u64(at: 8) else { continue }
                    if best == nil || entryXID > best!.xid { best = (entryXID, paddr) }
                }
                return best?.address
            }
            // Index node: the last key not greater than (oid, xid).
            var child: UInt64?
            for index in 0..<node.count {
                guard let (key, value) = node.entry(index, fixedKey: 16, fixedValue: 8) else { continue }
                let k = BinaryReader(key)
                let keyOID = k.u64(at: 0) ?? 0, keyXID = k.u64(at: 8) ?? 0
                if keyOID < oid || (keyOID == oid && keyXID <= xid) { child = BinaryReader(value).u64(at: 0) } else { break }
            }
            guard let child else { return nil }
            address = child
        }
        return nil
    }

    func lookup(_ oid: UInt64) throws -> UInt64? { try lookup(oid, xid: xid, omapRoot: omapRoot) }

    /// The first volume that can be read (DMGs have one).
    func firstVolume() throws -> APFSVolume? {
        var lastError: Error?
        for oid in volumeOIDs {
            do {
                guard let address = try lookup(oid) else { continue }
                return try APFSVolume(container: self, superblock: try block(address))
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        return nil
    }

    static func checksumValid(_ block: Data) -> Bool {
        guard block.count >= 8, block.count % 4 == 0 else { return false }
        let stored = BinaryReader(block).u64(at: 0) ?? 0
        return fletcher64(block) == stored
    }

    static func fletcher64(_ block: Data) -> UInt64 {
        var sum1: UInt64 = 0, sum2: UInt64 = 0
        let modulus: UInt64 = 0xFFFF_FFFF
        block.withUnsafeBytes { buffer in
            for index in 2..<(buffer.count / 4) {
                let word = UInt64(UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)))
                sum1 = (sum1 + word) % modulus
                sum2 = (sum2 + sum1) % modulus
            }
        }
        let check1 = modulus - ((sum1 + sum2) % modulus)
        let check2 = modulus - ((sum1 + check1) % modulus)
        return (check2 << 32) | check1
    }
}

/// One B-tree node: a table of contents, keys growing down from it, values growing up from the end.
struct APFSNode {
    let data: Data
    let flags: UInt16
    let level: UInt16
    let count: Int
    private let tableStart: Int
    private let keyStart: Int
    private let valueEnd: Int

    var isRoot: Bool { flags & 1 != 0 }
    var isLeaf: Bool { flags & 2 != 0 }
    var isFixed: Bool { flags & 4 != 0 }

    init(_ data: Data, blockSize: Int) throws {
        let r = BinaryReader(data)
        guard let flags = r.u16(at: 32), let level = r.u16(at: 34), let keys = r.u32(at: 36),
              let tableOffset = r.u16(at: 40).map(Int.init), let tableLength = r.u16(at: 42).map(Int.init) else { throw DiskImageError.corrupt("node") }
        let objectType = (r.u32(at: 24) ?? 0) & 0xFFFF
        guard objectType == 2 || objectType == 3 else { throw DiskImageError.corrupt("not a B-tree node") }
        self.data = data
        self.flags = flags
        self.level = level
        tableStart = 56 + tableOffset
        keyStart = 56 + tableOffset + tableLength
        valueEnd = data.count - (flags & 1 != 0 ? 40 : 0)
        let entrySize = flags & 4 != 0 ? 4 : 8
        count = min(Int(keys), max(0, tableLength / entrySize))
        guard keyStart <= data.count else { throw DiskImageError.corrupt("node table") }
    }

    /// The key and value at `index`. Fixed-size trees (object maps) pass their sizes.
    func entry(_ index: Int, fixedKey: Int = 0, fixedValue: Int = 0) -> (Data, Data)? {
        let r = BinaryReader(data)
        let keyOffset: Int, keyLength: Int, valueOffset: Int, valueLength: Int
        if isFixed {
            guard let k = r.u16(at: tableStart + index * 4), let v = r.u16(at: tableStart + index * 4 + 2) else { return nil }
            keyOffset = Int(k); keyLength = fixedKey; valueOffset = Int(v); valueLength = fixedValue
        } else {
            guard let k = r.u16(at: tableStart + index * 8), let kl = r.u16(at: tableStart + index * 8 + 2),
                  let v = r.u16(at: tableStart + index * 8 + 4), let vl = r.u16(at: tableStart + index * 8 + 6) else { return nil }
            keyOffset = Int(k); keyLength = Int(kl); valueOffset = Int(v); valueLength = Int(vl)
        }
        guard valueOffset != 0xFFFF, valueOffset <= valueEnd,
              let key = r.bytes(at: keyStart + keyOffset, count: keyLength),
              let value = r.bytes(at: valueEnd - valueOffset, count: valueLength) else { return nil }
        return (key, value)
    }
}

/// An APFS volume: its own object map and file-system tree of inodes, directory entries and extents.
final class APFSVolume: DiskFileSystem {
    struct Inode {
        var parent: UInt64
        var privateID: UInt64
        var modified: Date?
        var bsdFlags: UInt32
        var mode: UInt16
        var size: UInt64
        var isCompressed: Bool { bsdFlags & 0x20 != 0 }
        var isDirectory: Bool { mode & 0xF000 == 0x4000 }
        var isSymlink: Bool { mode & 0xF000 == 0xA000 }
    }
    struct DirectoryEntry { var name: String; var id: UInt64; var type: UInt16 }
    struct FileExtent { var logical: UInt64; var length: UInt64; var physical: UInt64 }
    enum XattrValue { case embedded(Data); case stream(id: UInt64, size: UInt64) }

    let kind = FileSystemKind.apfs
    let volumeName: String
    let fileCount: UInt64
    let directoryCount: UInt64
    let usedBytes: UInt64?
    let capacity: UInt64?
    let isCaseSensitive: Bool
    private let container: APFSContainer
    private let omapRoot: UInt64
    private let rootTree: UInt64

    private var scanned = false
    private var scanTruncated = false
    private var inodes: [UInt64: Inode] = [:]
    private var directories: [UInt64: [DirectoryEntry]] = [:]
    private var xattrs: [UInt64: [String: XattrValue]] = [:]
    private var extents: [UInt64: [FileExtent]] = [:]

    static let rootDirectory: UInt64 = 2
    static let maximumRecords = 1_000_000

    init(container: APFSContainer, superblock: Data) throws {
        self.container = container
        let r = BinaryReader(superblock)
        guard r.bytes(at: 32, count: 4) == Data("APSB".utf8) else { throw DiskImageError.corrupt("APFS volume") }
        let flags = r.u64(at: 264) ?? 0
        // Software-encrypted volumes keep their metadata encrypted.
        guard flags & 0x1 != 0 else { throw DiskImageError.encrypted }
        let incompatible = r.u64(at: 56) ?? 0
        isCaseSensitive = incompatible & 0x1 == 0
        volumeName = r.cString(at: 704, maxLength: 256) ?? ""
        fileCount = r.u64(at: 184) ?? 0
        directoryCount = r.u64(at: 192) ?? 0
        let blocks = r.u64(at: 88) ?? 0
        usedBytes = blocks.multipliedReportingOverflow(by: UInt64(container.blockSize)).overflow ? nil : blocks * UInt64(container.blockSize)
        capacity = container.blockCount.multipliedReportingOverflow(by: UInt64(container.blockSize)).overflow ? nil : container.blockCount * UInt64(container.blockSize)
        guard let omap = r.u64(at: 128), let omapBlock = try? container.block(omap), let root = BinaryReader(omapBlock).u64(at: 48),
              let treeOID = r.u64(at: 136), let tree = try container.lookup(treeOID, xid: container.xid, omapRoot: root) else {
            throw DiskImageError.corrupt("APFS volume tree")
        }
        omapRoot = root
        rootTree = tree
    }

    // MARK: Scanning

    /// Walks the whole file-system tree once, keeping what listing and reading need.
    private func scan(deadline: DiskDeadline) {
        guard !scanned else { return }
        scanned = true
        var stack: [(UInt64, Int)] = [(rootTree, 0)]
        var visited = Set<UInt64>()
        var records = 0
        while let (address, depth) = stack.popLast() {
            guard depth < 32, visited.count < APFSContainer.maximumNodes, visited.insert(address).inserted else { continue }
            if deadline.expired || records >= APFSVolume.maximumRecords { scanTruncated = true; return }
            guard let block = try? container.block(address), let node = try? APFSNode(block, blockSize: container.blockSize) else { continue }
            if node.isLeaf {
                for index in 0..<node.count {
                    guard let (key, value) = node.entry(index) else { continue }
                    record(key: key, value: value)
                    records += 1
                }
            } else {
                // Children are virtual: resolve each through the volume's object map. Push in reverse to visit in order.
                var children: [UInt64] = []
                for index in 0..<node.count {
                    guard let (_, value) = node.entry(index), let oid = BinaryReader(value).u64(at: 0),
                          let child = try? container.lookup(oid, xid: container.xid, omapRoot: omapRoot) else { continue }
                    children.append(child)
                }
                for child in children.reversed() { stack.append((child, depth + 1)) }
            }
        }
    }

    private func record(key: Data, value: Data) {
        let k = BinaryReader(key), v = BinaryReader(value)
        guard let header = k.u64(at: 0) else { return }
        let id = header & 0x0FFF_FFFF_FFFF_FFFF
        switch header >> 60 {
        case 3:   // inode
            guard let parent = v.u64(at: 0), let privateID = v.u64(at: 8) else { return }
            let nanoseconds = v.u64(at: 24) ?? 0
            var size = v.u64(at: 84) ?? 0
            // Extended fields: the data stream (type 8) carries the logical size.
            if let fieldCount = v.u16(at: 92).map(Int.init), fieldCount < 64 {
                var dataOffset = 96 + fieldCount * 4
                for field in 0..<fieldCount {
                    guard let type = v.u8(at: 96 + field * 4), let length = v.u16(at: 96 + field * 4 + 2).map(Int.init) else { break }
                    if type == 8, let streamSize = v.u64(at: dataOffset) { size = streamSize }
                    dataOffset += (length + 7) & ~7
                }
            }
            inodes[id] = Inode(parent: parent, privateID: privateID,
                               modified: nanoseconds > 0 ? Date(timeIntervalSince1970: TimeInterval(nanoseconds) / 1e9) : nil,
                               bsdFlags: v.u32(at: 68) ?? 0, mode: v.u16(at: 80) ?? 0, size: size)
        case 9:   // directory entry
            var name: String?
            if let lengthAndHash = k.u32(at: 8), key.count == 12 + Int(lengthAndHash & 0x3FF) {
                name = k.cString(at: 12, maxLength: 1024)
            } else if let length = k.u16(at: 8), key.count == 10 + Int(length) {
                name = k.cString(at: 10, maxLength: 1024)
            }
            guard let name, !name.isEmpty, let child = v.u64(at: 0) else { return }
            directories[id, default: []].append(DirectoryEntry(name: name.precomposedStringWithCanonicalMapping, id: child, type: (v.u16(at: 16) ?? 0) & 0xF))
        case 4:   // extended attribute: only the ones Greece uses
            guard let nameLength = k.u16(at: 8).map(Int.init), let name = k.cString(at: 10, maxLength: nameLength),
                  name == "com.apple.decmpfs" || name == "com.apple.ResourceFork" || name == "com.apple.fs.symlink",
                  let flags = v.u16(at: 0), let length = v.u16(at: 2).map(Int.init) else { return }
            if flags & 0x2 != 0, let data = v.bytes(at: 4, count: length) {
                xattrs[id, default: [:]][name] = .embedded(data)
            } else if flags & 0x1 != 0, let stream = v.u64(at: 4), let size = v.u64(at: 12) {
                xattrs[id, default: [:]][name] = .stream(id: stream, size: size)
            }
        case 8:   // file extent
            guard let logical = k.u64(at: 8), let lengthAndFlags = v.u64(at: 0), let physical = v.u64(at: 8) else { return }
            extents[id, default: []].append(FileExtent(logical: logical, length: lengthAndFlags & 0x00FF_FFFF_FFFF_FFFF, physical: physical))
        default:
            break
        }
    }

    // MARK: DiskFileSystem

    func entries(limit: Int, deadline: DiskDeadline) throws -> (entries: [VolumeEntry], truncated: Bool) {
        scan(deadline: deadline)
        var result: [VolumeEntry] = []
        var truncated = scanTruncated
        var queue: [(UInt64, String, Int)] = [(APFSVolume.rootDirectory, "", 0)]
        var head = 0
        var visited: Set<UInt64> = [APFSVolume.rootDirectory]
        while head < queue.count {
            let (directory, prefix, depth) = queue[head]
            head += 1
            if deadline.expired { truncated = true; break }
            for entry in (directories[directory] ?? []).sorted(by: { $0.name < $1.name }) {
                if result.count >= limit { truncated = true; break }
                let path = prefix.isEmpty ? entry.name : prefix + "/" + entry.name
                let inode = inodes[entry.id]
                let isDirectory = inode?.isDirectory ?? (entry.type == 4)
                if isDirectory {
                    result.append(VolumeEntry(path: path, isDirectory: true, isSymlink: false, size: 0, modified: inode?.modified))
                    if depth < 128, visited.insert(entry.id).inserted { queue.append((entry.id, path, depth + 1)) }
                } else {
                    var size = inode?.size ?? 0
                    if let inode, inode.isCompressed, case .embedded(let header)? = xattrs[entry.id]?["com.apple.decmpfs"],
                       let real = Decmpfs.header(header)?.size { size = real }
                    result.append(VolumeEntry(path: path, isDirectory: false, isSymlink: inode?.isSymlink ?? (entry.type == 10),
                                              size: size, modified: inode?.modified))
                }
            }
        }
        return (result, truncated)
    }

    private func inodeID(at path: String) throws -> UInt64 {
        scan(deadline: DiskDeadline(seconds: 2))
        var current = APFSVolume.rootDirectory
        for component in DiskFileSystems.components(path) {
            let target = component.precomposedStringWithCanonicalMapping
            guard let match = (directories[current] ?? []).first(where: {
                isCaseSensitive ? $0.name == target : $0.name.caseInsensitiveCompare(target) == .orderedSame
            }) else { throw DiskImageError.corrupt("no such file") }
            current = match.id
        }
        return current
    }

    private func readStream(_ id: UInt64, size: UInt64, limit: Int) throws -> Data {
        guard size <= UInt64(limit) else { throw DiskImageError.tooLarge }
        var output = Data(count: Int(size))
        let blockSize = UInt64(container.blockSize)
        for extent in (extents[id] ?? []).sorted(by: { $0.logical < $1.logical }) {
            guard extent.logical < size, extent.physical != 0 else { continue }
            let length = Int(min(extent.length, size - extent.logical))
            let (offset, overflow) = extent.physical.multipliedReportingOverflow(by: blockSize)
            guard !overflow else { continue }
            let chunk = try container.device.read(at: offset, count: length)
            output.replaceSubrange(Int(extent.logical)..<(Int(extent.logical) + chunk.count), with: chunk)
        }
        return output
    }

    private func xattr(_ name: String, of id: UInt64, limit: Int) throws -> Data? {
        switch xattrs[id]?[name] {
        case .embedded(let data)?: return data
        case .stream(let stream, let size)?: return try readStream(stream, size: size, limit: limit)
        case nil: return nil
        }
    }

    func readFile(_ path: String, limit: Int) throws -> Data {
        let id = try inodeID(at: path)
        guard let inode = inodes[id], !inode.isDirectory else { throw DiskImageError.corrupt("not a file") }
        if inode.isCompressed, let header = try xattr("com.apple.decmpfs", of: id, limit: 16 << 20) {
            return try Decmpfs.decompress(xattr: header, resourceFork: { [self] in
                try xattr("com.apple.ResourceFork", of: id, limit: 256 << 20)
            }, limit: limit)
        }
        return try readStream(inode.privateID, size: inode.size, limit: limit)
    }

    func linkTarget(_ path: String) throws -> String? {
        let id = try inodeID(at: path)
        guard let data = try xattr("com.apple.fs.symlink", of: id, limit: 4096) else { return nil }
        return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
    }
}
