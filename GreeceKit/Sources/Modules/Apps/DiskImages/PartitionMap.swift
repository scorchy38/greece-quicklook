import Foundation

/// The file systems Greece recognises inside an image.
enum FileSystemKind: String, Equatable {
    case apfs = "APFS"
    case hfsPlus = "Mac OS Extended"
    case hfsX = "Mac OS Extended (Case-sensitive)"
    case hfs = "Mac OS Standard"
    case iso9660 = "ISO 9660"
    case fat = "MS-DOS (FAT)"
    case exfat = "ExFAT"
    case ntfs = "NTFS"
    case udf = "UDF"

    /// Reads the signatures at the start of a partition.
    static func detect(_ device: DiskDevice) -> FileSystemKind? {
        guard let head = try? device.read(at: 0, count: 4096), head.count >= 1536 else { return nil }
        let r = BinaryReader(head, bigEndian: true)
        if r.bytes(at: 32, count: 4) == Data("NXSB".utf8) { return .apfs }
        switch r.u16(at: 1024) {
        case 0x482B: return .hfsPlus
        case 0x4858: return .hfsX
        case 0x4244:
            // Classic HFS, possibly wrapping an HFS+ volume (embedded signature at 124).
            return r.u16(at: 1024 + 124) == 0x482B ? .hfsPlus : .hfs
        default: break
        }
        if r.bytes(at: 3, count: 8) == Data("EXFAT   ".utf8) { return .exfat }
        if r.bytes(at: 3, count: 8) == Data("NTFS    ".utf8) { return .ntfs }
        if head.count >= 512, head[510] == 0x55, head[511] == 0xAA,
           r.bytes(at: 54, count: 3) == Data("FAT".utf8) || r.bytes(at: 82, count: 3) == Data("FAT".utf8) { return .fat }
        if let descriptor = try? device.read(at: 16 * 2048, count: 8), descriptor.count == 8 {
            let id = descriptor.subdata(in: 1..<6)
            if id == Data("CD001".utf8) { return .iso9660 }
            if id == Data("BEA01".utf8) || id == Data("NSR02".utf8) || id == Data("NSR03".utf8) { return .udf }
        }
        return nil
    }
}

struct DiskPartition: Equatable {
    var name: String
    /// "Apple_APFS", "EFI", "Microsoft Basic Data"…
    var type: String
    var offset: UInt64
    var length: UInt64
    var fileSystem: FileSystemKind?
}

struct PartitionMap: Equatable {
    enum Scheme: String { case guid = "GUID Partition Map", apple = "Apple Partition Map", mbr = "Master Boot Record", none = "None" }
    var scheme: Scheme
    var partitions: [DiskPartition]

    static let maximumPartitions = 256

    static func read(_ device: DiskDevice) -> PartitionMap {
        if let gpt = guid(device) { return gpt }
        if let apm = apple(device) { return apm }
        // A bare file system (or an ISO) wins over an MBR that merely sits in front of it.
        if let kind = FileSystemKind.detect(device) {
            return PartitionMap(scheme: .none, partitions: [DiskPartition(name: "", type: kind.rawValue, offset: 0, length: device.size, fileSystem: kind)])
        }
        if let mbr = mbr(device) { return mbr }
        return PartitionMap(scheme: .none, partitions: [])
    }

    /// The partitions with a file system Greece can list, best first (APFS and HFS+ over the rest).
    var readable: [DiskPartition] {
        let order: [FileSystemKind] = [.apfs, .hfsPlus, .hfsX, .iso9660]
        return partitions.filter { $0.fileSystem.map(order.contains) ?? false }
            .sorted { order.firstIndex(of: $0.fileSystem!)! < order.firstIndex(of: $1.fileSystem!)! }
    }

    // MARK: GPT

    private static func guid(_ device: DiskDevice) -> PartitionMap? {
        for sectorSize in [UInt64(512), 4096] {
            guard let header = try? device.read(at: sectorSize, count: 92), header.count == 92,
                  header.prefix(8) == Data("EFI PART".utf8) else { continue }
            let r = BinaryReader(header)
            guard let entriesLBA = r.u64(at: 72), let count = r.u32(at: 80), let entrySize = r.u32(at: 84),
                  entrySize >= 128, entrySize <= 4096 else { return nil }
            let usable = min(Int(count), maximumPartitions)
            let (tableStart, overflow) = entriesLBA.multipliedReportingOverflow(by: sectorSize)
            guard !overflow, let table = try? device.read(at: tableStart, count: usable * Int(entrySize)) else { return nil }
            let t = BinaryReader(table)
            var partitions: [DiskPartition] = []
            for index in 0..<usable {
                let at = index * Int(entrySize)
                guard let type = t.bytes(at: at, count: 16), type.contains(where: { $0 != 0 }),
                      let first = t.u64(at: at + 32), let last = t.u64(at: at + 40), last >= first,
                      let nameBytes = t.bytes(at: at + 56, count: 72) else { continue }
                let units = stride(from: 0, to: nameBytes.count, by: 2).map { UInt16(nameBytes[$0]) | UInt16(nameBytes[$0 + 1]) << 8 }
                let name = String(decoding: units.prefix { $0 != 0 }, as: UTF16.self)
                let (count, o0) = (last - first).addingReportingOverflow(1)
                let (offset, o1) = first.multipliedReportingOverflow(by: sectorSize)
                let (length, o2) = count.multipliedReportingOverflow(by: sectorSize)
                guard !o0, !o1, !o2 else { continue }
                var partition = DiskPartition(name: name, type: guidName(type), offset: offset, length: length)
                partition.fileSystem = FileSystemKind.detect(SliceDevice(device, start: offset, length: length))
                partitions.append(partition)
            }
            return PartitionMap(scheme: .guid, partitions: partitions)
        }
        return nil
    }

    static func guidString(_ bytes: Data) -> String {
        let b = [UInt8](bytes)
        guard b.count == 16 else { return "" }
        let d1 = String(format: "%02X%02X%02X%02X", b[3], b[2], b[1], b[0])
        let d2 = String(format: "%02X%02X", b[5], b[4])
        let d3 = String(format: "%02X%02X", b[7], b[6])
        let d4 = b[8...9].map { String(format: "%02X", $0) }.joined()
        let d5 = b[10...15].map { String(format: "%02X", $0) }.joined()
        return "\(d1)-\(d2)-\(d3)-\(d4)-\(d5)"
    }

    private static func guidName(_ bytes: Data) -> String {
        let known = [
            "48465300-0000-11AA-AA11-00306543ECAC": "Apple_HFS",
            "7C3457EF-0000-11AA-AA11-00306543ECAC": "Apple_APFS",
            "426F6F74-0000-11AA-AA11-00306543ECAC": "Apple_Boot",
            "55465300-0000-11AA-AA11-00306543ECAC": "Apple_UFS",
            "52414944-0000-11AA-AA11-00306543ECAC": "Apple_RAID",
            "C12A7328-F81F-11D2-BA4B-00A0C93EC93B": "EFI",
            "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7": "Microsoft Basic Data",
            "E3C9E316-0B5C-4DB8-817D-F92DF00215AE": "Microsoft Reserved",
            "0FC63DAF-8483-4772-8E79-3D69D8477DE4": "Linux",
            "0657FD6D-A4AB-43C4-84E5-0933C84B4F4F": "Linux Swap",
        ]
        let text = guidString(bytes)
        return known[text] ?? text
    }

    // MARK: Apple Partition Map

    private static func apple(_ device: DiskDevice) -> PartitionMap? {
        guard let block0 = try? device.read(at: 0, count: 512), block0.count == 512, block0.prefix(2) == Data("ER".utf8) else { return nil }
        let blockSize = UInt64(BinaryReader(block0, bigEndian: true).u16(at: 2) ?? 512)
        let size = [512, 1024, 2048, 4096].contains(blockSize) ? blockSize : 512
        guard let first = try? device.read(at: size, count: 512), first.prefix(2) == Data("PM".utf8) else { return nil }
        let count = min(Int(BinaryReader(first, bigEndian: true).u32(at: 4) ?? 0), maximumPartitions)
        var partitions: [DiskPartition] = []
        for index in 0..<count {
            guard let entry = try? device.read(at: size * UInt64(index + 1), count: 512), entry.prefix(2) == Data("PM".utf8) else { break }
            let r = BinaryReader(entry, bigEndian: true)
            let start = UInt64(r.u32(at: 8) ?? 0) * size
            let length = UInt64(r.u32(at: 12) ?? 0) * size
            let name = r.fixedString(at: 16, length: 32) ?? ""
            let type = r.fixedString(at: 48, length: 32) ?? ""
            if type == "Apple_partition_map" || type == "Apple_Free" || length == 0 { continue }
            var partition = DiskPartition(name: name, type: type, offset: start, length: length)
            partition.fileSystem = FileSystemKind.detect(SliceDevice(device, start: start, length: length))
            partitions.append(partition)
        }
        return PartitionMap(scheme: .apple, partitions: partitions)
    }

    // MARK: MBR

    private static func mbr(_ device: DiskDevice) -> PartitionMap? {
        guard let sector = try? device.read(at: 0, count: 512), sector.count == 512, sector[510] == 0x55, sector[511] == 0xAA else { return nil }
        let r = BinaryReader(sector)
        var partitions: [DiskPartition] = []
        for index in 0..<4 {
            let at = 446 + index * 16
            guard let type = r.u8(at: at + 4), type != 0, type != 0xEE,
                  let first = r.u32(at: at + 8), let count = r.u32(at: at + 12), count > 0 else { continue }
            let names: [UInt8: String] = [0x01: "FAT12", 0x04: "FAT16", 0x06: "FAT16", 0x07: "NTFS/exFAT", 0x0B: "FAT32", 0x0C: "FAT32",
                                          0x0E: "FAT16", 0x83: "Linux", 0xAF: "Apple_HFS", 0xA8: "Apple_UFS"]
            let offset = UInt64(first) * 512
            let length = UInt64(count) * 512
            var partition = DiskPartition(name: "", type: names[type] ?? String(format: "Type 0x%02X", type), offset: offset, length: length)
            partition.fileSystem = FileSystemKind.detect(SliceDevice(device, start: offset, length: length))
            partitions.append(partition)
        }
        return partitions.isEmpty ? nil : PartitionMap(scheme: .mbr, partitions: partitions)
    }
}
