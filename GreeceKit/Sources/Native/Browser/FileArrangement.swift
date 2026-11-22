import Foundation
import UniformTypeIdentifiers

/// How a file browser shows a folder: as a list or as icons, in what order and in what groups.
/// The reader's last choice is remembered (`BrowserMemory`).
struct BrowserViewState: Codable, Equatable {
    enum Layout: String, Codable, CaseIterable {
        case list, icons

        /// As Finder's View menu names them.
        var title: String {
            switch self {
            case .list: return String(localized: "as List", bundle: .greeceKit, comment: "View menu item, tooltip and accessibility label: show files in a list (as in Finder)")
            case .icons: return String(localized: "as Icons", bundle: .greeceKit, comment: "View menu item, tooltip and accessibility label: show files as icons (as in Finder)")
            }
        }
    }

    /// The raw values are the list's column identifiers, so a column header and the Sort By menu
    /// speak the same language.
    enum SortKey: String, Codable, CaseIterable {
        case name, kind, modified, size, compressed

        /// The same words as the list's column headers.
        var title: String {
            switch self {
            case .name: return FileColumnTitles.name
            case .kind: return FileColumnTitles.kind
            case .modified: return FileColumnTitles.modified
            case .size: return FileColumnTitles.size
            case .compressed:
                return String(localized: "Compressed Size", bundle: .greeceKit, comment: "Sort By menu item: an archived file’s compressed size")
            }
        }

        /// The order a key starts in when chosen, as Finder's columns do: names and kinds from A,
        /// dates and sizes newest and largest first.
        var startsAscending: Bool { self == .name || self == .kind }
    }

    enum GroupKey: String, Codable, CaseIterable {
        case none, kind, modified, size

        var title: String {
            switch self {
            case .none: return String(localized: "None [group by]", defaultValue: "None", bundle: .greeceKit, comment: "Group By menu item: don’t group files (as in Finder)")
            case .kind: return FileColumnTitles.kind
            case .modified: return FileColumnTitles.modified
            case .size: return FileColumnTitles.size
            }
        }

        /// The sort key that orders the same thing this groups by.
        var sortKey: SortKey? {
            switch self {
            case .none: return nil
            case .kind: return .kind
            case .modified: return .modified
            case .size: return .size
            }
        }
    }

    var layout = Layout.list
    var sort = SortKey.name
    var ascending = true
    var group = GroupKey.none

    init(layout: Layout = .list, sort: SortKey = .name, ascending: Bool = true, group: GroupKey = .none) {
        self.layout = layout
        self.sort = sort
        self.ascending = ascending
        self.group = group
    }

    /// Tolerant: unknown or missing values keep their defaults, so builds can share what's stored.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layout = (try? c.decodeIfPresent(Layout.self, forKey: .layout)) ?? .list
        sort = (try? c.decodeIfPresent(SortKey.self, forKey: .sort)) ?? .name
        ascending = (try? c.decodeIfPresent(Bool.self, forKey: .ascending)) ?? sort.startsAscending
        group = (try? c.decodeIfPresent(GroupKey.self, forKey: .group)) ?? GroupKey.none
    }
}

/// Finder's words for a file's columns, shared by the list's headers, the Sort By and Group By
/// menus and Get Info, so each is translated once, as Finder has it.
enum FileColumnTitles {
    static var name: String {
        String(localized: "Name", bundle: .greeceKit, comment: "Column header and Sort By menu item: a file’s name (as in Finder)")
    }
    static var kind: String {
        String(localized: "Kind", bundle: .greeceKit, comment: "Column header, Sort By and Group By menu item: a file’s type (as in Finder)")
    }
    static var modified: String {
        String(localized: "Date Modified", bundle: .greeceKit, comment: "Column header, Sort By and Group By menu item (as in Finder)")
    }
    static var size: String {
        String(localized: "Size", bundle: .greeceKit, comment: "Column header, Sort By and Group By menu item, Get Info row: a file’s size (as in Finder)")
    }
    static var compressed: String {
        String(localized: "Compressed", bundle: .greeceKit, comment: "Column header and Get Info row: an archived file’s compressed size")
    }
}

/// A run of files under one heading ("Images", "Yesterday", "1 MB to 10 MB").
struct FileGroup {
    /// Stable across rebuilds, so views can keep what they know about a group.
    let id: String
    let title: String
    var nodes: [FileNode]
}

/// Finder's group headings other than kinds' and months', looked up once: grouping asks for one
/// per file.
enum FileGroupTitles {
    static let folders = String(localized: "Folders", bundle: .greeceKit, comment: "Group By Kind or Size heading (as in Finder)")
    static let unknownSize = String(localized: "Unknown Size", bundle: .greeceKit, comment: "Group By Size heading: files whose size isn’t known")
    static let zeroKB = String(localized: "Zero KB", bundle: .greeceKit, comment: "Group By Size heading: empty files (as in Finder)")
    static let noDate = String(localized: "No Date", bundle: .greeceKit, comment: "Group By Date Modified heading: files without a date")
    static let today = String(localized: "Today", bundle: .greeceKit, comment: "Group By Date Modified heading (as in Finder)")
    static let yesterday = String(localized: "Yesterday", bundle: .greeceKit, comment: "Group By Date Modified heading (as in Finder)")
    static let previousWeek = String(localized: "Previous 7 Days", bundle: .greeceKit, comment: "Group By Date Modified heading (as in Finder)")
    static let previousMonth = String(localized: "Previous 30 Days", bundle: .greeceKit, comment: "Group By Date Modified heading (as in Finder)")
}

/// Finder's broad kinds, as its Group By Kind headings name them.
enum KindGroup: String, CaseIterable {
    case folders, applications, archives, developer, diskImages, documents, fonts, images, movies, music,
         pdf, presentations, spreadsheets, text, other

    /// Looked up once: grouping asks for every file's.
    var title: String { KindGroup.titles[self] ?? rawValue }

    private static let titles = Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.localizedTitle) })

    private var localizedTitle: String {
        switch self {
        case .folders: return FileGroupTitles.folders
        case .applications: return String(localized: "Applications", bundle: .greeceKit, comment: "Group By Kind heading (as in Finder)")
        case .archives: return String(localized: "Archives", bundle: .greeceKit, comment: "Group By Kind heading (as in Finder)")
        case .developer: return String(localized: "Developer", bundle: .greeceKit, comment: "Group By Kind heading: source code and other developer files (as in Finder)")
        case .diskImages: return String(localized: "Disk Images", bundle: .greeceKit, comment: "Group By Kind heading (as in Finder)")
        case .documents: return String(localized: "Documents", bundle: .greeceKit, comment: "Group By Kind heading (as in Finder)")
        case .fonts: return String(localized: "Fonts", bundle: .greeceKit, comment: "Group By Kind heading (as in Finder)")
        case .images: return String(localized: "Images", bundle: .greeceKit, comment: "Group By Kind heading (as in Finder)")
        case .movies: return String(localized: "Movies", bundle: .greeceKit, comment: "Group By Kind heading (as in Finder)")
        case .music: return String(localized: "Music", bundle: .greeceKit, comment: "Group By Kind heading (as in Finder)")
        case .pdf: return String(localized: "PDF Documents", bundle: .greeceKit, comment: "Group By Kind heading (as in Finder)")
        case .presentations: return String(localized: "Presentations", bundle: .greeceKit, comment: "Group By Kind heading (as in Finder)")
        case .spreadsheets: return String(localized: "Spreadsheets", bundle: .greeceKit, comment: "Group By Kind heading (as in Finder)")
        case .text: return String(localized: "Text", bundle: .greeceKit, comment: "Group By Kind heading: plain text files (as in Finder)")
        case .other: return String(localized: "Other", bundle: .greeceKit, comment: "Group By Kind heading: files of any other kind (as in Finder)")
        }
    }

    private static var cache: [String: KindGroup] = [:]
    private static let lock = NSLock()

    static func of(_ node: FileNode) -> KindGroup {
        if node.isDirectory && !node.isPackage { return .folders }
        let ext = (node.name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return .other }
        let key = node.isPackage ? ext + "/" : ext
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let group = of(type: UTType(filenameExtension: ext, conformingTo: node.isPackage ? .package : .data)
                       ?? UTType(filenameExtension: ext))
        cache[key] = group
        return group
    }

    static func of(type: UTType?) -> KindGroup {
        guard let type, !type.isDynamic else { return .other }
        func any(_ types: [UTType]) -> Bool { types.contains { type.conforms(to: $0) } }
        func prefixed(_ prefixes: [String]) -> Bool { prefixes.contains { type.identifier.hasPrefix($0) } }
        if any([.application, .applicationBundle]) { return .applications }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .images }
        if type.conforms(to: .audio) { return .music }
        if any([.movie, .video, .audiovisualContent]) { return .movies }
        if type.conforms(to: .font) { return .fonts }
        if type.conforms(to: .diskImage) { return .diskImages }
        // Office and iWork files are zip packages underneath: they're documents before archives.
        if type.conforms(to: .presentation) || prefixed(["com.apple.iwork.keynote", "org.openxmlformats.presentationml",
                                                         "com.microsoft.powerpoint", "org.oasis-open.opendocument.presentation"]) {
            return .presentations
        }
        if type.conforms(to: .spreadsheet) || prefixed(["com.apple.iwork.numbers", "org.openxmlformats.spreadsheetml",
                                                        "com.microsoft.excel", "org.oasis-open.opendocument.spreadsheet"]) {
            return .spreadsheets
        }
        if any([.rtf, .rtfd, .flatRTFD, .webArchive, .epub])
            || prefixed(["com.apple.iwork.pages", "org.openxmlformats.wordprocessingml", "com.microsoft.word",
                         "org.oasis-open.opendocument.text"]) {
            return .documents
        }
        if type.conforms(to: .archive) { return .archives }
        if any([.sourceCode, .script, .json, .xml, .yaml, .propertyList, .html]) || type.identifier == "public.css"
            || prefixed(["com.apple.xcode", "com.apple.dt."]) {
            return .developer
        }
        if type.conforms(to: .text) { return .text }
        if type.conforms(to: .compositeContent) { return .documents }
        return .other
    }
}

/// Sorting and grouping a folder's files: pure functions shared by the list and the icons.
enum FileArrangement {

    /// Whether `a` comes before `b`. Folders first (when asked), then the key, then Finder's name
    /// order, so the order is total and stable from one reload to the next.
    static func precedes(_ a: FileNode, _ b: FileNode, by key: BrowserViewState.SortKey, ascending up: Bool, foldersFirst folders: Bool) -> Bool {
        if folders && a.isDirectory != b.isDirectory && !(a.isPackage || b.isPackage) { return a.isDirectory }
        switch key {
        case .size:
            let x = a.size ?? 0, y = b.size ?? 0
            if x != y { return up ? x < y : x > y }
        case .compressed:
            let x = a.compressedSize ?? 0, y = b.compressedSize ?? 0
            if x != y { return up ? x < y : x > y }
        case .modified:
            let x = a.modified ?? .distantPast, y = b.modified ?? .distantPast
            if x != y { return up ? x < y : x > y }
        case .kind:
            let x = FileTreeView.kindName(of: a), y = FileTreeView.kindName(of: b)
            if x != y {
                let order = x.localizedStandardCompare(y)
                if order != .orderedSame { return up ? order == .orderedAscending : order == .orderedDescending }
            }
        case .name:
            break
        }
        let order = FileTreeView.finderOrder(a.name, b.name)
        return (key == .name && !up) ? order == .orderedDescending : order == .orderedAscending
    }

    static func sorted(_ nodes: [FileNode], by key: BrowserViewState.SortKey, ascending: Bool, foldersFirst: Bool) -> [FileNode] {
        nodes.sorted { precedes($0, $1, by: key, ascending: ascending, foldersFirst: foldersFirst) }
    }

    /// Where a group goes: with the folders at the top, in the middle by rank, or at the end
    /// (things without a value: no date, no size, other kinds).
    private enum Pin: Int { case first, middle, last }

    private struct Bucket {
        let id: String
        let title: String
        /// Order among the middle groups, smallest first, in the group's natural direction.
        let rank: Int
        let pin: Pin
    }

    /// Splits already-sorted files into groups, keeping their order inside each group. Groups go
    /// in Finder's order (kinds from A, newest dates and largest sizes first); sorting by the same
    /// thing in the other direction turns them around.
    static func groups(_ nodes: [FileNode], by key: BrowserViewState.GroupKey, sort: BrowserViewState.SortKey = .name,
                       ascending: Bool = true, foldersFirst: Bool = true, now: Date = Date(), calendar: Calendar = .current) -> [FileGroup] {
        guard key != .none else { return [FileGroup(id: "all", title: "", nodes: nodes)] }
        let dates = DateBuckets(now: now, calendar: calendar)
        var order: [String: Int] = [:]
        var buckets: [Bucket] = []
        var members: [[FileNode]] = []
        for node in nodes {
            let bucket: Bucket
            switch key {
            case .none: return []
            case .kind: bucket = kindBucket(node, foldersFirst: foldersFirst)
            case .modified: bucket = dates.bucket(node.modified)
            case .size: bucket = sizeBucket(node, foldersFirst: foldersFirst)
            }
            if let index = order[bucket.id] {
                members[index].append(node)
            } else {
                order[bucket.id] = buckets.count
                buckets.append(bucket)
                members.append([node])
            }
        }
        // The natural direction: kinds A to Z (ascending), dates and sizes descending.
        let natural = key == .kind
        let reversed = key.sortKey == sort && ascending != natural
        let indices = buckets.indices.sorted { i, j in
            let a = buckets[i], b = buckets[j]
            if a.pin != b.pin { return a.pin.rawValue < b.pin.rawValue }
            if a.rank != b.rank { return reversed ? a.rank > b.rank : a.rank < b.rank }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        return indices.map { FileGroup(id: buckets[$0].id, title: buckets[$0].title, nodes: members[$0]) }
    }

    // MARK: Kinds

    private static let kindRanks: [KindGroup: Int] = {
        let sorted = KindGroup.allCases.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($1, $0) })
    }()

    private static func kindBucket(_ node: FileNode, foldersFirst: Bool) -> Bucket {
        let kind = KindGroup.of(node)
        let pin: Pin
        switch kind {
        case .folders: pin = foldersFirst ? .first : .middle
        case .other: pin = .last
        default: pin = .middle
        }
        return Bucket(id: "kind." + kind.rawValue, title: kind.title, rank: kindRanks[kind] ?? 0, pin: pin)
    }

    // MARK: Sizes

    /// Finder's size bands, a factor of ten apart (decimal units, as the Size column counts).
    static let sizeBands: [(limit: UInt64, title: String)] = [
        (10_000, String(localized: "Less than 10 KB", bundle: .greeceKit, comment: "Group By Size heading (as in Finder)")),
        (100_000, String(localized: "10 KB to 100 KB", bundle: .greeceKit, comment: "Group By Size heading (as in Finder)")),
        (1_000_000, String(localized: "100 KB to 1 MB", bundle: .greeceKit, comment: "Group By Size heading (as in Finder)")),
        (10_000_000, String(localized: "1 MB to 10 MB", bundle: .greeceKit, comment: "Group By Size heading (as in Finder)")),
        (100_000_000, String(localized: "10 MB to 100 MB", bundle: .greeceKit, comment: "Group By Size heading (as in Finder)")),
        (1_000_000_000, String(localized: "100 MB to 1 GB", bundle: .greeceKit, comment: "Group By Size heading (as in Finder)")),
        (10_000_000_000, String(localized: "1 GB to 10 GB", bundle: .greeceKit, comment: "Group By Size heading (as in Finder)")),
        (UInt64.max, String(localized: "More than 10 GB", bundle: .greeceKit, comment: "Group By Size heading (as in Finder)")),
    ]

    /// A size rounded as the Size column shows it (whole kilobytes, tenths of megabytes,
    /// hundredths of gigabytes), so a file listed as "10 KB" isn't filed under "Less than 10 KB".
    static func displayedSize(_ size: UInt64) -> UInt64 {
        func rounded(to unit: UInt64) -> UInt64 { (size / unit + (size % unit >= unit / 2 ? 1 : 0)) * unit }
        switch size {
        case ..<1_000: return size
        case ..<1_000_000: return rounded(to: 1_000)
        case ..<1_000_000_000: return rounded(to: 100_000)
        default: return rounded(to: 10_000_000)
        }
    }

    private static func sizeBucket(_ node: FileNode, foldersFirst: Bool) -> Bucket {
        guard let size = node.size else {
            if node.isDirectory && !node.isPackage {
                return Bucket(id: "size.folders", title: FileGroupTitles.folders, rank: 0, pin: foldersFirst ? .first : .last)
            }
            return Bucket(id: "size.unknown", title: FileGroupTitles.unknownSize, rank: 0, pin: .last)
        }
        if size == 0 { return Bucket(id: "size.zero", title: FileGroupTitles.zeroKB, rank: sizeBands.count, pin: .middle) }
        let shown = displayedSize(size)
        let band = sizeBands.firstIndex { shown < $0.limit } ?? sizeBands.count - 1
        // Largest first: the top band has the smallest rank.
        return Bucket(id: "size.\(band)", title: sizeBands[band].title, rank: sizeBands.count - 1 - band, pin: .middle)
    }

    // MARK: Dates

    /// Finder's date headings: Today, Yesterday, Previous 7 Days, Previous 30 Days, then the
    /// months of this year, then earlier years.
    private struct DateBuckets {
        let calendar: Calendar
        let today: Date
        let yesterday: Date
        let week: Date
        let month: Date
        let year: Int
        let months: [String]

        init(now: Date, calendar: Calendar) {
            self.calendar = calendar
            today = calendar.startOfDay(for: now)
            yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
            week = calendar.date(byAdding: .day, value: -7, to: today) ?? today
            month = calendar.date(byAdding: .day, value: -30, to: today) ?? today
            year = calendar.component(.year, from: now)
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = calendar.locale ?? .current
            months = formatter.standaloneMonthSymbols ?? formatter.monthSymbols ?? []
        }

        func bucket(_ date: Date?) -> Bucket {
            guard let date else { return Bucket(id: "date.none", title: FileGroupTitles.noDate, rank: 0, pin: .last) }
            // Dates in the future (a clock set ahead, a file from elsewhere) count as today.
            if date >= today { return Bucket(id: "date.today", title: FileGroupTitles.today, rank: 0, pin: .middle) }
            if date >= yesterday { return Bucket(id: "date.yesterday", title: FileGroupTitles.yesterday, rank: 1, pin: .middle) }
            if date >= week { return Bucket(id: "date.week", title: FileGroupTitles.previousWeek, rank: 2, pin: .middle) }
            if date >= month { return Bucket(id: "date.month", title: FileGroupTitles.previousMonth, rank: 3, pin: .middle) }
            let parts = calendar.dateComponents([.year, .month], from: date)
            let itsYear = parts.year ?? year
            if itsYear == year, let number = parts.month, number >= 1, number <= months.count {
                return Bucket(id: "date.m\(number)", title: months[number - 1], rank: 100 + (12 - number), pin: .middle)
            }
            return Bucket(id: "date.y\(itsYear)", title: String(itsYear), rank: 1000 + max(0, year - itsYear), pin: .middle)
        }
    }
}
