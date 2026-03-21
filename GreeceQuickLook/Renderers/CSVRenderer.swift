import Cocoa

/// Renders CSV/TSV files as native NSTableView with sortable columns.
final class CSVRenderer: FileRenderer {

    func render(fileAt url: URL, completion: @escaping (Error?) -> Void) -> NSView {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            completion(NSError(domain: "GreeceQL", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot read CSV file"]))
            return NSView()
        }

        let ext = url.pathExtension.lowercased()
        let delimiter: Character = (ext == "tsv" || ext == "tab") ? "\t" : ","

        let rows = parseCSV(content, delimiter: delimiter)
        guard !rows.isEmpty else {
            completion(NSError(domain: "GreeceQL", code: 3, userInfo: [NSLocalizedDescriptionKey: "Empty CSV file"]))
            return NSView()
        }

        let settings = GreeceSettings.shared
        let maxRows = settings.csvMaxRows
        let truncated = rows.count - 1 > maxRows

        // First row is headers
        let headers = rows[0]
        let dataRows = Array(rows.dropFirst().prefix(maxRows))

        // Create container
        let container = NSView()
        container.wantsLayer = true

        // Create scroll view with table
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let tableView = GreeceTableView()
        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = settings.csvAlternatingRows
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsMultipleSelection = false
        tableView.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        tableView.gridColor = .separatorColor
        tableView.rowHeight = 22
        tableView.intercellSpacing = NSSize(width: 8, height: 2)

        // Create columns
        for (index, header) in headers.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col_\(index)"))
            column.title = header.isEmpty ? "Column \(index + 1)" : header
            column.minWidth = 60
            column.maxWidth = 500
            column.width = max(100, CGFloat(header.count * 9))
            column.sortDescriptorPrototype = NSSortDescriptor(key: "\(index)", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:)))
            tableView.addTableColumn(column)
        }

        let dataSource = CSVDataSource(headers: headers, rows: dataRows)
        tableView.dataSource = dataSource
        tableView.delegate = dataSource
        tableView.dataSourceRef = dataSource  // Prevent dealloc

        scrollView.documentView = tableView
        container.addSubview(scrollView)

        // Truncation notice
        if truncated {
            let notice = NSTextField(labelWithString: "⚠ Showing \(maxRows.formatted()) of \(rows.count - 1) rows")
            notice.font = .systemFont(ofSize: 11)
            notice.textColor = .secondaryLabelColor
            notice.alignment = .center
            notice.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(notice)

            NSLayoutConstraint.activate([
                scrollView.topAnchor.constraint(equalTo: container.topAnchor),
                scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                scrollView.bottomAnchor.constraint(equalTo: notice.topAnchor, constant: -4),
                notice.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                notice.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                notice.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
                notice.heightAnchor.constraint(equalToConstant: 20),
            ])
        } else {
            NSLayoutConstraint.activate([
                scrollView.topAnchor.constraint(equalTo: container.topAnchor),
                scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }

        completion(nil)
        return container
    }

    // MARK: - CSV Parser

    private func parseCSV(_ content: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var currentField = ""
        var inQuotes = false
        var i = content.startIndex

        while i < content.endIndex {
            let char = content[i]

            if inQuotes {
                if char == "\"" {
                    let next = content.index(after: i)
                    if next < content.endIndex && content[next] == "\"" {
                        // Escaped quote
                        currentField.append("\"")
                        i = content.index(after: next)
                        continue
                    } else {
                        inQuotes = false
                    }
                } else {
                    currentField.append(char)
                }
            } else {
                if char == "\"" {
                    inQuotes = true
                } else if char == delimiter {
                    currentRow.append(currentField)
                    currentField = ""
                } else if char == "\n" || char == "\r" {
                    currentRow.append(currentField)
                    currentField = ""
                    if !currentRow.allSatisfy({ $0.isEmpty }) || !currentRow.isEmpty {
                        rows.append(currentRow)
                    }
                    currentRow = []
                    // Handle \r\n
                    if char == "\r" {
                        let next = content.index(after: i)
                        if next < content.endIndex && content[next] == "\n" {
                            i = next
                        }
                    }
                } else {
                    currentField.append(char)
                }
            }
            i = content.index(after: i)
        }

        // Last field/row
        if !currentField.isEmpty || !currentRow.isEmpty {
            currentRow.append(currentField)
            rows.append(currentRow)
        }

        return rows
    }
}

// MARK: - Table View subclass to hold strong ref

class GreeceTableView: NSTableView {
    var dataSourceRef: AnyObject?
}

// MARK: - Data Source

final class CSVDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let headers: [String]
    private var rows: [[String]]

    init(headers: [String], rows: [[String]]) {
        self.headers = headers
        self.rows = rows
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        return rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn = tableColumn,
              let colIndex = Int(tableColumn.identifier.rawValue.replacingOccurrences(of: "col_", with: "")) else {
            return nil
        }

        let cell = NSTextField(labelWithString: "")
        cell.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        cell.lineBreakMode = .byTruncatingTail

        if colIndex < rows[row].count {
            cell.stringValue = rows[row][colIndex]
        }

        return cell
    }

    // Sorting support
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let sortDescriptor = tableView.sortDescriptors.first,
              let key = sortDescriptor.key,
              let colIndex = Int(key) else { return }

        rows.sort { row1, row2 in
            let val1 = colIndex < row1.count ? row1[colIndex] : ""
            let val2 = colIndex < row2.count ? row2[colIndex] : ""

            // Try numeric comparison first
            if let num1 = Double(val1), let num2 = Double(val2) {
                return sortDescriptor.ascending ? num1 < num2 : num1 > num2
            }
            let result = val1.localizedStandardCompare(val2)
            return sortDescriptor.ascending ? result == .orderedAscending : result == .orderedDescending
        }

        tableView.reloadData()
    }
}
