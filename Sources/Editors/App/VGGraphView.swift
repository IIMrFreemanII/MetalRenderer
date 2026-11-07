import AppKit
import MetalRenderer

/// Virtual geometry's history, oldest left: the cut's time (line), BLASes swapped in per frame (bars), triangles in the
/// cut and BLAS megabytes (lines), each scaled to its own maximum, which the legend prints.
final class VGGraphView: NSView {
    private var history: [VirtualBLAS.HistorySample] = []

    func set(_ samples: [VirtualBLAS.HistorySample]) {
        history = samples
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        NSColor.quaternaryLabelColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        guard history.count > 1 else { return }
        let plot = r.insetBy(dx: 4, dy: 4)
        let capacity = max(history.count, 2)
        func x(_ i: Int) -> CGFloat { plot.minX + CGFloat(i) / CGFloat(capacity - 1) * plot.width }
        func y(_ v: Double, _ top: Double) -> CGFloat { plot.minY + CGFloat(top > 0 ? min(v / top, 1) : 0) * plot.height }

        let cut = history.map { Double($0.cutMs) }, swaps = history.map { Double($0.rebuilds) }
        let tris = history.map { Double($0.triangles) }, mb = history.map { Double($0.megabytes) }
        let maxes = (cut.max() ?? 0, swaps.max() ?? 0, tris.max() ?? 0, mb.max() ?? 0)

        NSColor.systemGray.withAlphaComponent(0.5).setFill()
        let barWidth = max(plot.width / CGFloat(capacity), 1)
        for (i, v) in swaps.enumerated() where v > 0 {
            NSRect(x: x(i), y: plot.minY, width: barWidth, height: y(v, maxes.1) - plot.minY).fill()
        }
        func line(_ values: [Double], _ top: Double, _ color: NSColor) {
            let path = NSBezierPath()
            for (i, v) in values.enumerated() {
                let p = NSPoint(x: x(i), y: y(v, top))
                if i == 0 { path.move(to: p) } else { path.line(to: p) }
            }
            path.lineWidth = 1.25
            color.setStroke()
            path.stroke()
        }
        line(tris, maxes.2, .systemGreen)
        line(mb, maxes.3, .systemPurple)
        line(cut, maxes.0, .systemOrange)

        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        let legends: [(String, NSColor)] = [
            (String(format: "cut %.1f ms (max %.1f)", cut.last ?? 0, maxes.0), .systemOrange),
            (String(format: "swaps %d (max %d)", Int(swaps.last ?? 0), Int(maxes.1)), .systemGray),
            (String(format: "triangles %.2fM (max %.2fM)", (tris.last ?? 0) / 1e6, maxes.2 / 1e6), .systemGreen),
            (String(format: "BLAS %.1f MB (max %.1f)", mb.last ?? 0, maxes.3), .systemPurple),
        ]
        for (i, l) in legends.enumerated() {
            (l.0 as NSString).draw(at: NSPoint(x: plot.minX + 2, y: plot.maxY - 12 - CGFloat(i) * 12),
                                   withAttributes: [.font: font, .foregroundColor: l.1])
        }
    }
}

/// The per-instance table: the nearest 64 virtual instances, sorted by the clicked header. `show` keeps the scroll
/// position and the sort.
final class VGInstanceTable: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    private struct Column {
        let id: String, title: String, width: CGFloat
        let text: (VirtualBLAS.InstanceStats) -> String
        let less: (VirtualBLAS.InstanceStats, VirtualBLAS.InstanceStats) -> Bool
    }
    private static func num<T: Comparable>(_ id: String, _ title: String, _ width: CGFloat, _ key: @escaping (VirtualBLAS.InstanceStats) -> T,
                                           _ text: @escaping (VirtualBLAS.InstanceStats) -> String) -> Column {
        Column(id: id, title: title, width: width, text: text, less: { key($0) < key($1) })
    }
    private static let columns: [Column] = [
        num("name", "name", 90, { $0.name }, { "\($0.name) #\($0.instance)" }),
        num("distance", "dist m", 52, { $0.distance }, { String(format: "%.1f", $0.distance) }),
        num("clusters", "clusters", 56, { $0.clusters }, { "\($0.clusters)" }),
        num("triangles", "triangles", 64, { $0.triangles }, { "\($0.triangles)" }),
        num("finest", "finest", 64, { $0.finestTriangles }, { "\($0.finestTriangles)" }),
        num("levels", "levels", 46, { $0.maxLevel }, { "\($0.minLevel)–\($0.maxLevel)" }),
        num("waited", "waited", 46, { $0.waited }, { "\($0.waited)" }),
        num("slack", "slack", 52, { $0.slack }, { $0.slack.isFinite ? String(format: "%.2f", $0.slack) : "∞" }),
        num("rebuilds", "rebuilds", 56, { $0.rebuilds }, { "\($0.rebuilds)" }),
        num("mb", "MB", 48, { $0.bytes }, { String(format: "%.2f", Double($0.bytes) / 1_048_576) }),
        num("gather", "gather ms", 62, { $0.gatherMs }, { String(format: "%.2f", $0.gatherMs) }),
        num("faults", "faults", 46, { $0.faults }, { "\($0.faults)" }),
    ]

    private let table = NSTableView()
    private var rows: [VirtualBLAS.InstanceStats] = []
    private var source: [VirtualBLAS.InstanceStats] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        for c in Self.columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(c.id))
            column.title = c.title
            column.width = c.width
            column.minWidth = 36
            column.headerCell.font = .systemFont(ofSize: 10)
            column.sortDescriptorPrototype = NSSortDescriptor(key: c.id, ascending: true)
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 14
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.sortDescriptors = [NSSortDescriptor(key: "distance", ascending: true)]
        documentView = table
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        borderType = .lineBorder
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The nearest 64 of `stats`, in the table's sort order.
    func show(_ stats: [VirtualBLAS.InstanceStats]) {
        source = Array(stats.sorted { $0.distance < $1.distance }.prefix(64))
        resort()
        let origin = contentView.bounds.origin
        table.reloadData()
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }

    private func resort() {
        guard let d = table.sortDescriptors.first, let key = d.key,
              let column = Self.columns.first(where: { $0.id == key }) else { rows = source; return }
        rows = source.sorted { d.ascending ? column.less($0, $1) : column.less($1, $0) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, let c = Self.columns.first(where: { $0.id == id.rawValue }), rows.indices.contains(row) else { return nil }
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField) ?? {
            let t = NSTextField(labelWithString: "")
            t.identifier = id
            t.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            t.lineBreakMode = .byTruncatingTail
            return t
        }()
        cell.stringValue = c.text(rows[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        resort()
        table.reloadData()
    }
}
