import Foundation

/// Reads a bill of materials ("BOMStore"): the list of everything a package installs.
///
/// Big-endian throughout. The header points at a block table (address, length pairs) and a list
/// of named variables; "Paths" is a B+tree whose leaves pair a file key (parent id, name) with a
/// value pointing at the path's metadata (type, mode, owner, size, modification time).
enum Bom {
    struct Entry: Equatable {
        enum Kind: UInt8 { case file = 1, directory = 2, symlink = 3, device = 4 }
        /// Relative to the package root, without the leading "./" ("zoom.us.app/Contents/Info.plist").
        var path: String
        var kind: Kind
        var mode: UInt16
        var uid: UInt32
        var gid: UInt32
        var size: UInt64
        var modified: Date?
        var linkTarget: String?
    }

    struct Listing {
        var entries: [Entry]
        var truncated: Bool
        var fileCount: Int { entries.lazy.filter { $0.kind != .directory }.count }
        var totalSize: UInt64 { entries.reduce(0) { $1.kind == .file ? $0.saturatingAdd($1.size) : $0 } }
    }

    enum Failure: Error, Equatable { case notBom, corrupt(String) }

    static let magic: [UInt8] = Array("BOMStore".utf8)

    static func read(_ data: Data, limit: Int = 200_000, seconds: TimeInterval = 1.5) throws -> Listing {
        let reader = BinaryReader(data, bigEndian: true)
        guard data.count >= 32, data.prefix(8).elementsEqual(magic),
              let indexOffset = reader.u32(at: 16).map(Int.init), let indexLength = reader.u32(at: 20).map(Int.init),
              let varsOffset = reader.u32(at: 24).map(Int.init), let varsLength = reader.u32(at: 28).map(Int.init),
              reader.has(indexLength, at: indexOffset), reader.has(varsLength, at: varsOffset),
              let blockCount = reader.u32(at: indexOffset).map(Int.init) else { throw Failure.notBom }
        let maxBlocks = min(blockCount, (indexLength - 4) / 8)

        func block(_ number: UInt32) -> (start: Int, length: Int)? {
            let index = Int(number)
            guard index < maxBlocks,
                  let address = reader.u32(at: indexOffset + 4 + index * 8).map(Int.init),
                  let length = reader.u32(at: indexOffset + 8 + index * 8).map(Int.init),
                  reader.has(length, at: address) else { return nil }
            return (address, length)
        }

        // Variables: count, then (block index, name length, name).
        var variables: [String: UInt32] = [:]
        if let count = reader.u32(at: varsOffset) {
            var position = varsOffset + 4
            for _ in 0..<min(Int(count), 64) {
                guard let number = reader.u32(at: position), let length = reader.u8(at: position + 4).map(Int.init),
                      let name = reader.bytes(at: position + 5, count: length) else { break }
                variables[String(decoding: name, as: UTF8.self)] = number
                position += 5 + length
            }
        }

        guard let pathsVariable = variables["Paths"], let tree = block(pathsVariable), tree.length >= 21,
              reader.bytes(at: tree.start, count: 4) == Data("tree".utf8),
              let rootNode = reader.u32(at: tree.start + 8) else { throw Failure.corrupt("no Paths tree") }

        let deadline = Date().addingTimeInterval(seconds)
        // Descend to the leftmost leaf, refusing cycles.
        var visited = Set<UInt32>()
        var node = rootNode
        while true {
            guard visited.insert(node).inserted, visited.count < 64, let location = block(node), location.length >= 12,
                  let isLeaf = reader.u16(at: location.start), let count = reader.u16(at: location.start + 2) else {
                throw Failure.corrupt("unreadable path tree")
            }
            if isLeaf != 0 { break }
            guard count > 0, let child = reader.u32(at: location.start + 12) else { throw Failure.corrupt("empty branch") }
            node = child
        }

        // Walk the leaves through their forward links.
        struct Raw { let id: UInt32; let parent: UInt32; let name: String; let info: UInt32 }
        var raws: [Raw] = []
        var truncated = false
        var leaves = Set<UInt32>()
        var leaf: UInt32 = node
        walk: while leaf != 0 {
            guard leaves.insert(leaf).inserted, let location = block(leaf),
                  let count = reader.u16(at: location.start + 2).map(Int.init),
                  let forward = reader.u32(at: location.start + 4) else { break }
            if Date() > deadline { truncated = true; break }
            for index in 0..<count {
                let pair = location.start + 12 + index * 8
                guard pair + 8 <= location.start + location.length,
                      let valueIndex = reader.u32(at: pair), let keyIndex = reader.u32(at: pair + 4),
                      let value = block(valueIndex), value.length >= 8, let key = block(keyIndex), key.length >= 5,
                      let id = reader.u32(at: value.start), let info = reader.u32(at: value.start + 4),
                      let parent = reader.u32(at: key.start),
                      let nameBytes = reader.bytes(at: key.start + 4, count: key.length - 4) else { continue }
                let name = String(decoding: nameBytes.prefix { $0 != 0 }, as: UTF8.self)
                raws.append(Raw(id: id, parent: parent, name: name, info: info))
                if raws.count >= limit { truncated = true; break walk }
            }
            leaf = forward
        }

        // Full paths: follow parent ids, memoised, with a depth cap against cycles.
        var byID: [UInt32: Raw] = [:]
        for raw in raws where byID[raw.id] == nil { byID[raw.id] = raw }
        var resolved: [UInt32: String] = [:]
        func path(of raw: Raw) -> String? {
            var chain: [Raw] = [raw]
            var current = raw
            var seen: Set<UInt32> = [raw.id]
            while current.parent != 0 {
                if let known = resolved[current.parent] {
                    return chain.reversed().reduce(known) { $0.isEmpty ? $1.name : $0 + "/" + $1.name }
                }
                guard let next = byID[current.parent], seen.insert(next.id).inserted, chain.count < 256 else { return nil }
                chain.append(next)
                current = next
            }
            return chain.reversed().map(\.name).joined(separator: "/")
        }

        var entries: [Entry] = []
        entries.reserveCapacity(raws.count)
        for raw in raws {
            guard var full = path(of: raw) else { continue }
            resolved[raw.id] = full
            while full.hasPrefix("./") { full.removeFirst(2) }
            if full == "." || full.isEmpty { continue }
            guard let info = block(raw.info), info.length >= 31,
                  let type = reader.u8(at: info.start), let kind = Entry.Kind(rawValue: type) else { continue }
            let mode = reader.u16(at: info.start + 4) ?? 0
            let uid = reader.u32(at: info.start + 6) ?? 0
            let gid = reader.u32(at: info.start + 10) ?? 0
            let modified = reader.u32(at: info.start + 14).flatMap { $0 == 0 ? nil : Date(timeIntervalSince1970: TimeInterval($0)) }
            let size = UInt64(reader.u32(at: info.start + 18) ?? 0)
            var target: String?
            if kind == .symlink, let length = reader.u32(at: info.start + 27).map(Int.init), length > 0, length < 4096,
               length <= info.length - 31, let bytes = reader.bytes(at: info.start + 31, count: length) {
                target = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            entries.append(Entry(path: full, kind: kind, mode: mode, uid: uid, gid: gid, size: size, modified: modified, linkTarget: target))
        }
        if entries.isEmpty && !raws.isEmpty { throw Failure.corrupt("no readable paths") }
        return Listing(entries: entries, truncated: truncated)
    }
}
