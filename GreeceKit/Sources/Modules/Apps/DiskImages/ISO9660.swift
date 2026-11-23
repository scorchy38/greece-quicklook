import Foundation

/// ISO 9660 (CD and DVD images), preferring Joliet's Unicode names and reading Rock Ridge names and links.
final class ISO9660Volume: DiskFileSystem {
    struct Record {
        var name: String
        var extent: UInt64
        var length: UInt64
        var isDirectory: Bool
        var isSymlink: Bool
        var linkTarget: String?
        var modified: Date?
    }

    let kind = FileSystemKind.iso9660
    let volumeName: String
    let usedBytes: UInt64?
    let capacity: UInt64?
    let isJoliet: Bool
    private let device: DiskDevice
    private let blockSize: UInt64
    private let root: Record

    init(device: DiskDevice) throws {
        self.device = device
        var primary: Data?
        var joliet: Data?
        // Volume descriptors start at sector 16 and end with type 255.
        for index in 16..<64 {
            guard let descriptor = try? device.read(at: UInt64(index) * 2048, count: 2048), descriptor.count == 2048,
                  descriptor.subdata(in: 1..<6) == Data("CD001".utf8) else { break }
            let type = descriptor[0]
            if type == 255 { break }
            if type == 1, primary == nil { primary = descriptor }
            if type == 2, joliet == nil {
                let escape = descriptor.subdata(in: 88..<91)
                if [Data("%/@".utf8), Data("%/C".utf8), Data("%/E".utf8)].contains(escape) { joliet = descriptor }
            }
        }
        guard let primary else { throw DiskImageError.notADiskImage }
        let chosen = joliet ?? primary
        isJoliet = joliet != nil
        let r = BinaryReader(chosen)
        let block = UInt64(r.u16(at: 128) ?? 2048)
        blockSize = [512, 1024, 2048, 4096].contains(block) ? block : 2048
        let blocks = UInt64(r.u32(at: 80) ?? 0)
        capacity = blocks * blockSize
        usedBytes = capacity
        if let joliet {
            let raw = joliet.subdata(in: 40..<72)
            volumeName = ISO9660Volume.ucs2(raw).trimmingCharacters(in: .whitespaces)
        } else {
            volumeName = (BinaryReader(primary).fixedString(at: 40, length: 32) ?? "").trimmingCharacters(in: .whitespaces)
        }
        guard let rootRecord = ISO9660Volume.parseRecord(chosen.subdata(in: 156..<190), joliet: isJoliet) else {
            throw DiskImageError.corrupt("ISO root directory")
        }
        root = rootRecord
    }

    static func ucs2(_ data: Data) -> String {
        let units = stride(from: 0, to: data.count - 1, by: 2).map { UInt16(data[data.startIndex + $0]) << 8 | UInt16(data[data.startIndex + $0 + 1]) }
        return String(decoding: units.prefix { $0 != 0 }, as: UTF16.self)
    }

    static func parseRecord(_ data: Data, joliet: Bool) -> Record? {
        let r = BinaryReader(data)
        guard let length = r.u8(at: 0), length >= 34, Int(length) <= data.count, let extent = r.u32(at: 2), let size = r.u32(at: 10),
              let flags = r.u8(at: 25), let nameLength = r.u8(at: 32).map(Int.init), 33 + nameLength <= Int(length),
              let nameBytes = r.bytes(at: 33, count: nameLength) else { return nil }
        var name: String
        if nameLength == 1 && (nameBytes[0] == 0 || nameBytes[0] == 1) {
            name = nameBytes[0] == 0 ? "." : ".."
        } else if joliet {
            name = ucs2(nameBytes)
        } else {
            name = String(decoding: nameBytes, as: UTF8.self)
        }
        if let semicolon = name.lastIndex(of: ";") { name = String(name[..<semicolon]) }
        if !joliet && name.hasSuffix(".") && name.count > 1 { name.removeLast() }
        var record = Record(name: name, extent: UInt64(extent), length: UInt64(size), isDirectory: flags & 0x02 != 0,
                            isSymlink: false, modified: date(r, at: 18))
        // Rock Ridge (System Use area after the name): NM long names, SL symbolic links.
        var use = 33 + nameLength + (nameLength % 2 == 0 ? 1 : 0)
        var rockName = ""
        var linkParts: [String] = []
        while use + 4 <= Int(length) {
            guard let signature = r.bytes(at: use, count: 2), let entryLength = r.u8(at: use + 2).map(Int.init), entryLength >= 4,
                  use + entryLength <= Int(length) else { break }
            if signature == Data("NM".utf8), let flags = r.u8(at: use + 4), flags & 0x06 == 0,
               let part = r.bytes(at: use + 5, count: entryLength - 5) {
                rockName += String(decoding: part, as: UTF8.self)
            } else if signature == Data("SL".utf8) {
                record.isSymlink = true
                var component = use + 5
                while component + 2 <= use + entryLength {
                    guard let componentFlags = r.u8(at: component), let componentLength = r.u8(at: component + 1).map(Int.init) else { break }
                    if componentFlags & 0x08 != 0 { linkParts.append("/") }
                    else if componentFlags & 0x02 != 0 { linkParts.append(".") }
                    else if componentFlags & 0x04 != 0 { linkParts.append("..") }
                    else if let text = r.bytes(at: component + 2, count: componentLength) { linkParts.append(String(decoding: text, as: UTF8.self)) }
                    component += 2 + componentLength
                }
            }
            use += entryLength
        }
        if !rockName.isEmpty { record.name = rockName }
        if record.isSymlink { record.linkTarget = linkParts.joined(separator: "/").replacingOccurrences(of: "//", with: "/") }
        return record
    }

    private static func date(_ r: BinaryReader, at offset: Int) -> Date? {
        guard let year = r.u8(at: offset), let month = r.u8(at: offset + 1), let day = r.u8(at: offset + 2),
              let hour = r.u8(at: offset + 3), let minute = r.u8(at: offset + 4), let second = r.u8(at: offset + 5),
              let zone = r.u8(at: offset + 6), month >= 1, month <= 12, day >= 1, day <= 31 else { return nil }
        var components = DateComponents()
        components.year = 1900 + Int(year)
        components.month = Int(month)
        components.day = Int(day)
        components.hour = Int(hour)
        components.minute = Int(minute)
        components.second = Int(second)
        components.timeZone = TimeZone(secondsFromGMT: Int(Int8(bitPattern: zone)) * 15 * 60)
        return Calendar(identifier: .gregorian).date(from: components)
    }

    private func children(of directory: Record) -> [Record] {
        let length = min(directory.length, 16 << 20)
        guard let data = try? device.read(at: directory.extent * blockSize, count: Int(length)) else { return [] }
        var result: [Record] = []
        var offset = 0
        while offset < data.count && result.count < 100_000 {
            let recordLength = Int(data[offset])
            if recordLength == 0 {
                // Records never span sectors: skip to the next one.
                offset = (offset / Int(blockSize) + 1) * Int(blockSize)
                continue
            }
            guard offset + recordLength <= data.count else { break }
            if let record = ISO9660Volume.parseRecord(data.subdata(in: offset..<(offset + recordLength)), joliet: isJoliet),
               record.name != ".", record.name != ".." {
                result.append(record)
            }
            offset += recordLength
        }
        return result
    }

    func entries(limit: Int, deadline: DiskDeadline) throws -> (entries: [VolumeEntry], truncated: Bool) {
        var result: [VolumeEntry] = []
        var truncated = false
        var queue: [(Record, String, Int)] = [(root, "", 0)]
        var visited: Set<UInt64> = [root.extent]
        var head = 0
        while head < queue.count {
            let (directory, prefix, depth) = queue[head]
            head += 1
            if deadline.expired { truncated = true; break }
            for child in children(of: directory) {
                if result.count >= limit { truncated = true; break }
                let path = prefix.isEmpty ? child.name : prefix + "/" + child.name
                result.append(VolumeEntry(path: path, isDirectory: child.isDirectory, isSymlink: child.isSymlink,
                                          size: child.isDirectory ? 0 : child.length, modified: child.modified))
                if child.isDirectory, depth < 64, visited.insert(child.extent).inserted { queue.append((child, path, depth + 1)) }
            }
        }
        return (result, truncated)
    }

    private func record(at path: String) throws -> Record {
        var current = root
        for component in DiskFileSystems.components(path) {
            guard let match = children(of: current).first(where: { $0.name.caseInsensitiveCompare(component) == .orderedSame }) else {
                throw DiskImageError.corrupt("no such file")
            }
            current = match
        }
        return current
    }

    func readFile(_ path: String, limit: Int) throws -> Data {
        let record = try record(at: path)
        guard !record.isDirectory else { throw DiskImageError.corrupt("folder") }
        guard record.length <= UInt64(limit) else { throw DiskImageError.tooLarge }
        return try device.read(at: record.extent * blockSize, count: Int(record.length))
    }

    func linkTarget(_ path: String) throws -> String? { try record(at: path).linkTarget }
}
