import AppKit
import Modeling
import SwiftUI

/// F3: Blender's operator search. What the mode's menus offer, by name: typing narrows the list (every word typed in
/// the menu path), the arrows pick, Return runs, Esc closes. What ran last comes first.
struct OperatorSearch {
    var query = ""
    var selected = 0
}

/// One operator the search can run: where its menu has it ("Edge ▸ Bridge Edge Loops"), its key, what it does.
struct SearchEntry {
    var path: String
    var title: String
    var shortcut: String
    var action: () -> Void
}

extension ModelingModel {
    /// The menus the mode has, as the search lists them.
    private func searchMenus() -> [ModelingMenu] {
        let select = ModelingMenu(title: "Select", items: [
            .init(title: "All", shortcut: "A", action: { [weak self] in self?.perform(.selectAll) }),
            .init(title: "None", shortcut: "Alt A", action: { [weak self] in self?.perform(.deselectAll) }),
            .init(title: "Invert", shortcut: "Ctrl I", action: { [weak self] in self?.perform(.invertSelection) }),
            .init(title: "Box Select", shortcut: "B", action: { [weak self] in self?.perform(.boxSelect) }),
            .init(title: "Circle Select", shortcut: "C", action: { [weak self] in self?.perform(.circleSelect) }),
        ] + (mode == .edit ? [
            .init(title: "Select Linked", shortcut: "Ctrl L", action: { [weak self] in self?.perform(.selectLinked(pick: false)) }),
            .init(title: "Select More", shortcut: "Ctrl +", action: { [weak self] in self?.perform(.selectMore) }),
            .init(title: "Select Less", shortcut: "Ctrl -", action: { [weak self] in self?.perform(.selectLess) }),
        ] : []))
        let common = [viewMenu(), shadingMenu(), modeMenu()]
        switch mode {
        case .object:
            return [contextMenu(), addMenu(), applyMenu(), snapMenu(), select] + common
        case .edit:
            return [vertexMenu(), edgeMenu(), faceMenu(), extrudeMenu(), mergeMenu(), deleteMenu(), separateMenu(), normalsMenu(), uvMenu(),
                    addMenu(), snapMenu(), select] + common
        case .sculpt:
            return [sculpt?.menu(model: self) ?? ModelingMenu(title: "Sculpt", items: [])] + common
        }
    }

    /// Every operator of the mode's menus, once each (by name: the first menu that has it).
    func searchEntries() -> [SearchEntry] {
        var out: [SearchEntry] = [], seen = Set<String>()
        func walk(_ m: ModelingMenu, _ path: String) {
            for item in m.items where !item.separator {
                let p = path + " ▸ " + item.title
                if let sub = item.submenu { walk(sub, p); continue }
                guard let a = item.action, seen.insert(item.title.lowercased()).inserted else { continue }
                out.append(SearchEntry(path: p, title: item.title, shortcut: item.shortcut, action: a))
            }
        }
        for m in searchMenus() { walk(m, m.title) }
        return out
    }

    /// The entries whose menu path has every word of `query` (any case), best first: the name starting with what was
    /// typed, then a word of it starting so, then the rest; what ran last before the others.
    func searchResults(_ query: String) -> [SearchEntry] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let all = searchEntries()
        let recent = Dictionary(recentOperators.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        func rank(_ e: SearchEntry) -> (Int, Int) {
            let title = e.title.lowercased()
            let q = words.joined(separator: " ")
            let r = q.isEmpty ? 0 : title.hasPrefix(q) ? 0 : title.split(separator: " ").contains { $0.hasPrefix(words[0]) } ? 1 : 2
            return (r, recent[e.path] ?? Int.max)
        }
        return all.enumerated()
            .filter { _, e in let p = e.path.lowercased(); return words.allSatisfy { p.contains($0) } }
            .sorted { a, b in let ra = rank(a.element), rb = rank(b.element); return ra != rb ? ra < rb : a.offset < b.offset }
            .map(\.element)
    }

    func openSearch() {
        cancelModal()
        search = OperatorSearch()
    }

    func closeSearch() {
        search = nil
        focusViewport()
    }

    /// Runs an entry (the search closed first, so it runs with the viewport's keyboard, a modal one too).
    func runSearch(_ e: SearchEntry) {
        closeSearch()
        recentOperators.removeAll { $0 == e.path }
        recentOperators.insert(e.path, at: 0)
        if recentOperators.count > 12 { recentOperators.removeLast() }
        e.action()
    }

    /// The search's own keys: the arrows move the pick, Return runs it.
    func searchMove(_ by: Int) {
        guard var s = search else { return }
        let n = searchResults(s.query).count
        s.selected = n == 0 ? 0 : (s.selected + by + n) % n
        search = s
    }

    func searchRun() {
        guard let s = search else { return }
        let results = searchResults(s.query)
        guard results.indices.contains(s.selected) else { return }
        runSearch(results[s.selected])
    }
}

/// The search's popup: the field, then the list (the pick highlighted).
struct OperatorSearchView: View {
    @EnvironmentObject var model: ModelingModel
    private let shown = 14

    var body: some View {
        let query = model.search?.query ?? ""
        let results = Array(model.searchResults(query).prefix(shown))
        let selected = model.search?.selected ?? 0
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(BlenderTheme.textDim)
                SearchField(text: Binding(get: { model.search?.query ?? "" }, set: { model.search?.query = $0; model.search?.selected = 0 }),
                            move: { model.searchMove($0) }, run: { model.searchRun() }, close: { model.closeSearch() })
                    .frame(height: 20)
            }
            .padding(6)
            .background(BlenderTheme.widgetDark)
            if results.isEmpty {
                Text("Nothing called that here").font(BlenderTheme.font).foregroundColor(BlenderTheme.textDim).padding(8)
            }
            ForEach(Array(results.enumerated()), id: \.offset) { k, e in
                HStack {
                    Text(e.path).font(BlenderTheme.font).foregroundColor(BlenderTheme.text).lineLimit(1)
                    Spacer(minLength: 12)
                    Text(e.shortcut).font(BlenderTheme.small).foregroundColor(BlenderTheme.textDim)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(k == selected ? BlenderTheme.selectedRow : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture { model.runSearch(e) }
            }
        }
        .frame(width: 420)
        .background(BlenderTheme.panel)
        .cornerRadius(5)
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(BlenderTheme.outline))
        .shadow(radius: 8)
    }
}

/// A text field that hands the arrows, Return and Esc to the search, and takes the keyboard when it appears.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var move: (Int) -> Void
    var run: () -> Void
    var close: () -> Void

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField
        init(_ p: SearchField) { parent = p }

        func controlTextDidChange(_ note: Notification) {
            if let f = note.object as? NSTextField { parent.text = f.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            case #selector(NSResponder.insertNewline(_:)): parent.run()
            case #selector(NSResponder.cancelOperation(_:)): parent.close()
            default: return false
            }
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 12)
        f.textColor = .white
        f.placeholderString = "Search…"
        f.delegate = context.coordinator
        DispatchQueue.main.async { f.window?.makeFirstResponder(f) }
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text { f.stringValue = text }
    }
}
