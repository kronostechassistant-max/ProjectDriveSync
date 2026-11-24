import SwiftUI
import AppKit
import Quartz

/// One tree, a column for each drive, and what will happen in between.
struct CompareView: View {
    let model: AppModel
    @Bindable var comparison: Comparison
    @State private var confirm: PendingApply?

    struct PendingApply: Identifiable {
        let id = UUID()
        var limit: Set<String>?
        var totals: Comparison.Totals
    }

    private static let sideWidth: CGFloat = 150
    private static let actionWidth: CGFloat = 210

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !comparison.notice.isEmpty {
                Label(comparison.notice, systemImage: "hand.raised.fill")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if model.isBusy { ProgressPanel(model: model) }
            tree
            detail
            footer
        }
        .padding(16)
        .sheet(item: Binding(get: { model.reviewing }, set: { model.reviewing = $0 })) { item in
            ReviewSheet(model: model, comparison: comparison, item: item)
        }
        .alert("Move to the Trash?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { p in
            Button("Apply", role: .destructive) { model.apply(limit: p.limit) }
            Button("Cancel", role: .cancel) {}
        } message: { p in
            Text(Self.trashMessage(p.totals))
        }
    }

    private static func trashMessage(_ t: Comparison.Totals) -> String {
        let shown = t.trashNames.prefix(12).joined(separator: "\n")
        let more = t.trashNames.count > 12 ? "\n…and \(t.trashNames.count - 12) more" : ""
        return "These go to the Trash, with their _past versions, wherever they are:\n\n\(shown)\(more)"
    }

    private func requestApply(limit: Set<String>? = nil) {
        let t = comparison.totals(limit: limit)
        if t.trashNames.isEmpty { model.apply(limit: limit) } else { confirm = PendingApply(limit: limit, totals: t) }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Compare: \(comparison.pair.name)").font(.title3.bold())
                Text("as of \(Fmt.time(comparison.made)) · nothing changes until you apply")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Compare Again", systemImage: "arrow.clockwise") { model.refreshComparison() }.disabled(model.isBusy)
                Button("Save Report…") { saveReport() }
            }
            HStack(spacing: 10) {
                Picker("Show", selection: $comparison.filter) {
                    Text("Changes \(comparison.changeCount)").tag(Comparison.Filter.changes)
                    Text("Review \(comparison.reviewCount)").tag(Comparison.Filter.review)
                    Text("All \(comparison.items.count)").tag(Comparison.Filter.all)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                TextField("Search names", text: $comparison.search).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Spacer()
                Button("Open All") { comparison.expandAll(true) }.controlSize(.small)
                Button("Close All") { comparison.expandAll(false) }.controlSize(.small)
            }
        }
    }

    // MARK: Tree

    private var tree: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                Text(comparison.labels.a).lineLimit(1).frame(width: Self.sideWidth, alignment: .leading)
                Text("What will happen").frame(width: Self.actionWidth, alignment: .leading)
                Text(comparison.labels.b).lineLimit(1).frame(width: Self.sideWidth, alignment: .leading)
            }
            .font(.caption.bold()).foregroundStyle(.secondary)
            .padding(.leading, 18).padding(.trailing, 9).padding(.vertical, 5)
            Divider()
            if comparison.rows.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: comparison.changeCount == 0 ? "checkmark.circle" : "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                    Text(comparison.changeCount == 0 && comparison.search.isEmpty ? "Both folders are the same." : "Nothing to show here.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $comparison.selection) {
                    ForEach(comparison.rows) { row in
                        rowView(row).tag(row.id).listRowSeparator(.visible)
                    }
                }
                .listStyle(.plain)
                .contextMenu(forSelectionType: String.self) { ids in
                    if !ids.isEmpty { menu(for: ids) }
                } primaryAction: { ids in
                    guard ids.count == 1, let item = ids.first.flatMap({ comparison.items[$0] }) else { return }
                    if item.isFolder { comparison.toggle(item.id) } else { model.reviewing = item }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
    }

    @ViewBuilder private func menu(for ids: Set<String>) -> some View {
        let single = ids.count == 1 ? ids.first.flatMap { comparison.items[$0] } : nil
        ForEach(comparison.allowed(for: ids), id: \.self) { d in
            Button(comparison.title(d, single)) { comparison.set(d, for: ids) }
        }
        Divider()
        Button("Do This Now") { requestApply(limit: comparison.scope(ids)) }
            .disabled(model.isBusy || comparison.totals(limit: comparison.scope(ids)).actions == 0)
        if let item = single {
            Divider()
            if !item.isFolder { Button("Review Side by Side…") { model.reviewing = item } }
            if let a = item.a { Button("Show in Finder: \(comparison.labels.a)") { model.reveal(url(.a, a).path) } }
            if let b = item.b { Button("Show in Finder: \(comparison.labels.b)") { model.reveal(url(.b, b).path) } }
        }
    }

    private func url(_ side: Side, _ info: SideInfo) -> URL {
        (side == .a ? comparison.pair.urlA : comparison.pair.urlB).appendingPathComponent(info.relPath)
    }

    private func rowView(_ row: Comparison.Row) -> some View {
        let item = row.item
        return HStack(spacing: 8) {
            HStack(spacing: 5) {
                Group {
                    if row.hasChildren {
                        Button { comparison.toggle(item.id) } label: {
                            Image(systemName: comparison.isExpanded(item.id) ? "chevron.down" : "chevron.right").font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(comparison.isExpanded(item.id) ? "Close folder" : "Open folder")
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 12, height: 12)
                Image(systemName: item.isFolder ? "folder.fill" : "doc").foregroundStyle(item.isFolder ? Color.blue : Color.secondary)
                Text(item.name).lineLimit(1).truncationMode(.middle)
                if item.kind.isChange {
                    Text(Comparison.word(item.kind))
                        .font(.caption2.weight(.semibold)).foregroundStyle(Self.color(item.kind))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Self.color(item.kind).opacity(0.14), in: Capsule())
                        .fixedSize()
                } else if row.changesInside > 0 {
                    Text("\(row.changesInside) inside").font(.caption2).foregroundStyle(.secondary).fixedSize()
                }
            }
            .padding(.leading, CGFloat(row.depth) * 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            sideCell(item, .a)
            actionCell(item).frame(width: Self.actionWidth, alignment: .leading)
            sideCell(item, .b)
        }
        .padding(.vertical, 1)
        .help(item.reason)
    }

    private func sideCell(_ item: DiffItem, _ side: Side) -> some View {
        let info = side == .a ? item.a : item.b
        let text: String
        if let info {
            text = item.isFolder ? "folder" : "\(Fmt.display(info.mtime)) · \(Fmt.bytes(info.size))"
        } else {
            text = item.kind == .deleted || item.kind == .deletedButChanged ? "deleted" : "—"
        }
        let strong = item.kind == .clash || (item.side == side && item.kind != .tidy && item.kind != .unchanged)
        return Text(text)
            .font(.caption).monospacedDigit().lineLimit(2)
            .foregroundStyle(info == nil ? AnyShapeStyle(.tertiary) : (strong ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
            .frame(width: Self.sideWidth, alignment: .leading)
    }

    @ViewBuilder private func actionCell(_ item: DiffItem) -> some View {
        if item.kind == .blocked {
            Label("Left alone", systemImage: "nosign").font(.caption).foregroundStyle(.secondary)
        } else if item.allowed.isEmpty {
            Text(item.kind == .unchanged && !item.isFolder ? "Same" : "").font(.caption).foregroundStyle(.tertiary)
        } else {
            let d = comparison.decision(item)
            Menu {
                ForEach(item.allowed, id: \.self) { option in
                    Button { comparison.set(option, for: item.id) } label: {
                        Label(comparison.title(option, item) + (option == item.suggested && item.kind != .clash && item.kind != .olderCopy ? "  (suggested)" : ""),
                              systemImage: comparison.symbol(option, item))
                    }
                }
                if !item.isFolder {
                    Divider()
                    Button("Review Side by Side…") { model.reviewing = item }
                }
            } label: {
                if comparison.isUnchosen(item) {
                    Label("Choose…", systemImage: "exclamationmark.triangle.fill")
                } else {
                    Label(comparison.title(d, item), systemImage: comparison.symbol(d, item))
                }
            }
            .menuStyle(.borderlessButton)
            .font(.caption)
            .tint(comparison.isUnchosen(item) ? .orange : (d == .deleteBoth ? .red : nil))
            .disabled(model.isBusy)
        }
    }

    static func color(_ k: DiffKind) -> Color {
        switch k {
        case .unchanged, .tidy: return .secondary
        case .added, .onlyHere: return .green
        case .edited, .differs: return .blue
        case .deleted: return .red
        case .deletedButChanged, .clash, .olderCopy, .blocked: return .orange
        }
    }

    // MARK: Detail

    private var selected: DiffItem? {
        comparison.selection.count == 1 ? comparison.selection.first.flatMap { comparison.items[$0] } : nil
    }

    private var detail: some View {
        GroupBox {
            Group {
                if let item = selected {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text((item.a ?? item.b)?.relPath ?? item.name).font(.headline).lineLimit(1).truncationMode(.middle)
                            Text(item.reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        if !item.isFolder { Button("Review Side by Side…") { model.reviewing = item } }
                        if item.kind.isChange && !item.allowed.isEmpty {
                            Button("Do This Now") { requestApply(limit: comparison.scope([item.id])) }
                                .disabled(model.isBusy || comparison.totals(limit: comparison.scope([item.id])).actions == 0)
                        }
                    }
                } else {
                    Text(comparison.selection.isEmpty
                         ? "Select an item to see why it is listed. Change what will happen with the menu on its row, or right-click several at once."
                         : "\(comparison.selection.count) items selected. Right-click to choose for all of them.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            .padding(4)
        }
    }

    // MARK: Footer

    private var footer: some View {
        let t = comparison.totals
        return HStack(spacing: 14) {
            if t.copies > 0 { Label("\(t.copies) to copy · \(Fmt.bytes(t.bytes))", systemImage: "doc.on.doc") }
            if !t.trashNames.isEmpty { Label("\(t.trashNames.count) to Trash", systemImage: "trash").foregroundStyle(.red) }
            if t.choose > 0 { Label("\(t.choose) to choose", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            if t.skipped > 0 { Label("\(t.skipped) skipped", systemImage: "minus.circle").foregroundStyle(.secondary) }
            if t.blocked > 0 { Label("\(t.blocked) can't sync", systemImage: "nosign").foregroundStyle(.secondary) }
            if t.actions == 0 && t.choose == 0 { Text("Nothing to do.").foregroundStyle(.secondary) }
            Spacer()
            Button("Reset Choices") { comparison.reset() }.disabled(!comparison.hasChoices || model.isBusy)
            Button("Close") { model.closeComparison() }.keyboardShortcut(.cancelAction).disabled(model.isBusy)
            Button("Apply") { requestApply() }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy || (t.actions == 0 && comparison.changeCount > 0))
                .help(t.choose > 0 ? "Items you haven't chosen for are left alone." : "Carry out everything in the middle column.")
        }
        .font(.callout)
    }

    private func saveReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(comparison.pair.name), comparison - \(Fmt.fileStamp(comparison.made)).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try comparison.report().write(to: url, atomically: true, encoding: .utf8) }
        catch { model.errorMessage = "Couldn't save the report: \(error.localizedDescription)" }
    }
}

// MARK: - Side-by-side review

struct ReviewSheet: View {
    let model: AppModel
    let comparison: Comparison
    let item: DiffItem
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [DiffLine]?
    @State private var ready = false
    @State private var onlyDifferences = false

    private func url(_ side: Side) -> URL? {
        guard let info = side == .a ? item.a : item.b else { return nil }
        return (side == .a ? comparison.pair.urlA : comparison.pair.urlB).appendingPathComponent(info.relPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.name).font(.title3.bold()).lineLimit(1).truncationMode(.middle)
                Text(Comparison.word(item.kind)).font(.caption.weight(.semibold)).foregroundStyle(CompareView.color(item.kind))
                Spacer()
                if let lines {
                    let n = lines.filter { $0.leftMark != .same || $0.rightMark != .same }.count
                    Text(n == 0 ? "The text is the same" : "\(n) line(s) differ").font(.caption).foregroundStyle(.secondary)
                    Toggle("Only differences", isOn: $onlyDifferences).toggleStyle(.checkbox).controlSize(.small)
                }
            }
            Text(item.reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                sideHeader(.a)
                sideHeader(.b)
            }
            Group {
                if !ready { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let lines { textDiff(lines) }
                else {
                    HStack(spacing: 12) { preview(.a); preview(.b) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                if !item.allowed.isEmpty {
                    Text("Choose:").foregroundStyle(.secondary)
                    ForEach(item.allowed, id: \.self) { d in
                        Button { comparison.set(d, for: item.id); dismiss() } label: {
                            Label(comparison.title(d, item), systemImage: comparison.symbol(d, item))
                        }
                    }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("Choosing here only sets what Apply will do.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 820, idealWidth: 960, minHeight: 560, idealHeight: 660)
        .task {
            if let a = url(.a), let b = url(.b) {
                lines = await Task.detached { () -> [DiffLine]? in
                    guard let l = TextDiff.text(a), let r = TextDiff.text(b) else { return nil }
                    return TextDiff.lines(l, r)
                }.value
            }
            ready = true
        }
    }

    private func sideHeader(_ side: Side) -> some View {
        let info = side == .a ? item.a : item.b
        let name = side == .a ? comparison.labels.a : comparison.labels.b
        return VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.headline)
            if let info, let u = url(side) {
                Text("\(Fmt.display(info.mtime)) · \(Fmt.bytes(info.size))" + (info.pastMtime.map { " · _past from \(Fmt.display($0))" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack {
                    Button("Open Copy") { openCopy(u, label: name) }
                        .help("Opens a read-only copy labelled with the drive's name, so both can be open at once")
                    Button("Edit Original") { NSWorkspace.shared.open(u) }
                        .help("Opens the real file. Press Compare Again when you have finished editing")
                    Button("Finder") { model.reveal(u.path) }
                }
                .controlSize(.small)
            } else {
                Text("Not on this drive").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openCopy(_ source: URL, label: String) {
        Task {
            do {
                let copy = try await Task.detached { try ReviewFiles.labelledCopy(of: source, label: label) }.value
                NSWorkspace.shared.open(copy)
            } catch {
                model.errorMessage = "Couldn't open a copy: \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder private func preview(_ side: Side) -> some View {
        if let u = url(side) {
            QuickLookPreview(url: u).frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
        } else {
            Text("Not on this drive").foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func textDiff(_ all: [DiffLine]) -> some View {
        let shown = onlyDifferences ? all.filter { $0.leftMark != .same || $0.rightMark != .same } : all
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(shown) { line in
                    HStack(alignment: .top, spacing: 12) {
                        diffCell(line.left, line.leftMark)
                        diffCell(line.right, line.rightMark)
                    }
                }
            }
            .padding(6)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
    }

    private func diffCell(_ text: String, _ mark: DiffLine.Mark) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(mark == .changed ? "●" : " ").foregroundStyle(.orange)
            Text(text.isEmpty ? " " : text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.vertical, 1).padding(.horizontal, 4)
        .background(mark == .changed ? Color.orange.opacity(0.16) : (mark == .missing ? Color.secondary.opacity(0.08) : .clear))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct QuickLookPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> NSView {
        guard let v = QLPreviewView(frame: .zero, style: .normal) else { return NSView() }
        v.autostarts = false
        v.previewItem = url as NSURL
        return v
    }
    func updateNSView(_ view: NSView, context: Context) {}
    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        // Let go of the file so the drive can be ejected.
        (view as? QLPreviewView)?.previewItem = nil
        (view as? QLPreviewView)?.close()
    }
}

/// Read-only copies used for looking at both versions at once.
nonisolated enum ReviewFiles {
    static var folder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("ProjectDriveSync Review", isDirectory: true) }

    static func clear() { try? FileManager.default.removeItem(at: folder) }

    static func labelledCopy(of source: URL, label: String) throws -> URL {
        let fm = FileManager.default
        let dir = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let (stem, ext) = Naming.split(source.lastPathComponent)
        let dest = dir.appendingPathComponent(Naming.join("\(stem) (\(Place.fileSafe(label)))", ext))
        try fm.copyItem(at: source, to: dest)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dest.path, isDirectory: &isDir), !isDir.boolValue {
            try? fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: dest.path)
        }
        return dest
    }
}
