import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var showCreate = false
    @State private var pairToRemove: SyncPair?

    @AppStorage(AppModel.compareFirstKey) private var compareFirst = false

    var body: some View {
        Group {
            if let c = model.comparison {
                CompareView(model: model, comparison: c)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    actionBar
                    ProgressPanel(model: model)
                    pairsSection
                    logSection
                }
                .padding(20)
            }
        }
        .frame(minWidth: 860, minHeight: 700, alignment: .top)
        .sheet(isPresented: $showCreate) { CreatePairSheet(model: model) }
        .alert(model.update?.title ?? "", isPresented: Binding(
            get: { model.update != nil },
            set: { if !$0 { model.update = nil } }
        ), presenting: model.update) { u in
            if let page = u.page {
                Button("Open Download Page") { NSWorkspace.shared.open(page) }
                Button("Later", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { u in
            Text(u.message)
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog("Remove this pair?", isPresented: Binding(
            get: { pairToRemove != nil },
            set: { if !$0 { pairToRemove = nil } }
        ), presenting: pairToRemove) { pair in
            Button("Remove Pair", role: .destructive) { model.removePair(pair) }
        } message: { pair in
            Text("\"\(pair.name)\" will be removed from this list. No files or folders are touched.")
        }
    }

    // MARK: Buttons

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button { showCreate = true } label: {
                Label("Create Synced Pair", systemImage: "plus.circle")
            }
            .controlSize(.large)

            Divider().frame(height: 22)

            Button { model.startSync() } label: {
                Label("Sync Pair", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isBusy || model.selectedPair == nil)
            .keyboardShortcut("s", modifiers: .command)

            Button { model.startCompare() } label: {
                Label("Compare", systemImage: "rectangle.split.2x1")
            }
            .controlSize(.large)
            .help("See what is different between the two folders. Nothing is changed.")
            .disabled(model.isBusy || model.selectedPair == nil)
            .keyboardShortcut("d", modifiers: .command)

            Picker("Pair", selection: $model.selectedPairID) {
                if model.availablePairs.isEmpty {
                    Text("No pairs available").tag(UUID?.none)
                }
                ForEach(model.availablePairs) { pair in
                    Text("\(pair.name)  (\(model.route(for: pair)))").tag(Optional(pair.id))
                }
            }
            .labelsHidden()
            .frame(minWidth: 180, maxWidth: 400)
            .disabled(model.isBusy)

            Button { model.refreshAvailability(manual: true) } label: {
                Label("Check Pairs", systemImage: "arrow.clockwise")
            }
            .help("Check which pairs have both locations connected")
            .disabled(model.isBusy)

            Spacer(minLength: 0)
        }
    }

    // MARK: Pairs list

    private var pairsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Synced Pairs").font(.title3.bold())
                Text("\(model.availablePairs.count) of \(model.pairs.count) available")
                    .foregroundStyle(.secondary)
                Spacer()
                if let checked = model.lastChecked {
                    Text("Checked \(Fmt.time(checked))").font(.caption).foregroundStyle(.secondary)
                }
            }
            GroupBox {
                if model.pairs.isEmpty {
                    Text("No pairs yet. Use Create Synced Pair to choose two folders with the same name, for example \"Photos\" on this Mac and on an external drive.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(sortedPairs) { pair in
                                pairRow(pair)
                                if pair.id != sortedPairs.last?.id { Divider() }
                            }
                        }
                    }
                    .frame(minHeight: 70, maxHeight: 210)
                }
            }
        }
    }

    private var sortedPairs: [SyncPair] {
        model.pairs.sorted { a, b in
            let aa = model.statuses[a.id]?.isAvailable == true, ba = model.statuses[b.id]?.isAvailable == true
            if aa != ba { return aa }
            return (a.lastSync ?? .distantPast) > (b.lastSync ?? .distantPast)
        }
    }

    private func pairRow(_ pair: SyncPair) -> some View {
        let status = model.statuses[pair.id] ?? .missingBoth
        let color: Color = status.isAvailable ? .green : (status == .missingBoth ? .red : .orange)
        return HStack(alignment: .top, spacing: 10) {
            Circle().fill(color).frame(width: 9, height: 9).padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(pair.name).font(.headline)
                    Text(model.route(for: pair)).foregroundStyle(.secondary)
                }
                pathLine("A", pair.pathA, ok: status == .available || status == .missingB)
                pathLine("B", pair.pathB, ok: status == .available || status == .missingA)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(status.label).font(.caption.weight(.medium)).foregroundStyle(color)
                Text("Last synced: \(pair.lastSync.map(Fmt.display) ?? "Never")")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Menu {
                Button("Show Location A in Finder") { model.reveal(pair.pathA) }
                    .disabled(!PairStore.isDirectory(pair.pathA))
                Button("Show Location B in Finder") { model.reveal(pair.pathB) }
                    .disabled(!PairStore.isDirectory(pair.pathB))
                Divider()
                Button("Remove Pair…", role: .destructive) { pairToRemove = pair }
                    .disabled(model.isBusy)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture { if status.isAvailable && !model.isBusy { model.selectedPairID = pair.id } }
        .background(model.selectedPairID == pair.id ? Color.accentColor.opacity(0.08) : .clear)
    }

    private func pathLine(_ label: String, _ path: String, ok: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption.bold()).frame(width: 12)
            Text(path)
                .font(.caption)
                .foregroundStyle(ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    // MARK: Log

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Log").font(.title3.bold())
                Text("latest \(AppModel.visibleLogLines) · refreshes every \(AppModel.logRefreshEvery) entries")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("Always compare before syncing", isOn: $compareFirst)
                    .toggleStyle(.checkbox).controlSize(.small)
                Text("Version \(Fmt.appVersion)").font(.caption).foregroundStyle(.secondary)
                Button(model.isCheckingUpdate ? "Checking…" : "Check for Updates") { model.checkForUpdates() }
                    .controlSize(.small).disabled(model.isCheckingUpdate)
                Button("Open Full Log") { model.openFullLog() }.controlSize(.small)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(model.visibleLog) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(Fmt.time(entry.time)).foregroundStyle(.tertiary)
                            Text(entry.text)
                                .foregroundStyle(color(for: entry.level))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity, alignment: .topLeading)
                .padding(4)
                .textSelection(.enabled)
            }
        }
    }

    private func color(for level: LogEntry.Level) -> Color {
        switch level {
        case .info: return .primary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

// MARK: - Progress

struct ProgressPanel: View {
    let model: AppModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if let p = model.progress {
                    HStack {
                        Text(p.phase).font(.headline)
                        Spacer()
                        if let f = p.fraction {
                            Text(f.formatted(.percent.precision(.fractionLength(0))))
                                .font(.headline).monospacedDigit()
                        }
                        if model.isBusy {
                            Button("Cancel", role: .destructive) { model.cancelSync() }
                                .controlSize(.small)
                        }
                    }
                    if let f = p.fraction, !(model.isBusy && p.phase.hasPrefix("Verifying")) {
                        ProgressView(value: f)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    HStack(spacing: 14) {
                        if p.bytesTotal > 0 {
                            stat("arrow.down.doc", "\(Fmt.bytes(p.bytesDone)) of \(Fmt.bytes(p.bytesTotal))")
                            stat("speedometer", model.isBusy ? Fmt.rate(p.bytesPerSecond) : "—")
                            if model.isBusy, let eta = p.secondsRemaining {
                                stat("clock", "about \(Fmt.duration(eta)) left")
                            }
                        }
                        if p.itemsTotal > 0 {
                            stat("checklist", "\(p.itemsDone) of \(p.itemsTotal) items")
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    Text(p.currentItem.isEmpty ? " " : p.currentItem)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Ready").font(.headline)
                    ProgressView(value: 0)
                    Text("Choose a pair from the drop-down and press Sync Pair, or Compare to look first. Progress and transfer speed show here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
    }

    private func stat(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).monospacedDigit()
    }
}

// MARK: - Create pair sheet

struct CreatePairSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var pathA = ""
    @State private var pathB = ""
    @State private var error: String?

    private var nameA: String { (PairStore.normalize(pathA) as NSString).lastPathComponent }
    private var nameB: String { (PairStore.normalize(pathB) as NSString).lastPathComponent }

    private var resolved: PairStore.ResolvedPicks? { PairStore.resolve(pathA: pathA, pathB: pathB) }

    /// Two ordinary folders with different names: offer to use/create A's folder inside B.
    private var suggestedB: (path: String, exists: Bool)? {
        let a = PairStore.normalize(pathA), b = PairStore.normalize(pathB)
        guard !a.isEmpty, !b.isEmpty, PairStore.isDirectory(a), PairStore.isDirectory(b),
              !PairStore.isDriveRoot(a), !PairStore.isDriveRoot(b),
              nameA.lowercased() != nameB.lowercased() else { return nil }
        let candidate = (b as NSString).appendingPathComponent(nameA)
        return (candidate, PairStore.isDirectory(candidate))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create Synced Pair").font(.title2.bold())
            Text("Choose the same folder in two places, for example \"Photos\" on two drives. Both folders must have the same name. If you choose a whole drive for one side, a folder with the other side's name is made on it. If you choose whole drives for both, \"\(PairStore.untitledFolderName)\" is made on each.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            folderRow("Location A", $pathA)
            folderRow("Location B", $pathB)

            if let r = resolved, r.pathA != PairStore.normalize(pathA) || r.pathB != PairStore.normalize(pathB) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Will sync these folders:", systemImage: "info.circle").foregroundStyle(.blue)
                    ForEach([("A", r.pathA), ("B", r.pathB)], id: \.0) { side, path in
                        Text("\(side)  \(path)\(r.toCreate.contains(path) ? "   (new folder)" : "")")
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            if let s = suggestedB {
                HStack {
                    Image(systemName: "lightbulb").foregroundStyle(.yellow)
                    Text(s.exists ? "Use the \"\(nameA)\" folder inside Location B?" : "Create a \"\(nameA)\" folder inside Location B?")
                    Button(s.exists ? "Use It" : "Create Folder") {
                        if !s.exists {
                            do { try FileManager.default.createDirectory(atPath: s.path, withIntermediateDirectories: false) }
                            catch { self.error = error.localizedDescription; return }
                        }
                        pathB = s.path
                        error = nil
                    }
                }
                .font(.callout)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Pair") { createPair() }
                .keyboardShortcut(.defaultAction)
                .disabled(pathA.trimmingCharacters(in: .whitespaces).isEmpty || pathB.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 600)
    }

    private func createPair() {
        let r = resolved ?? PairStore.ResolvedPicks(pathA: pathA, pathB: pathB, toCreate: [])
        if Set(r.toCreate.map { $0.lowercased() }).count < r.toCreate.count || r.pathA.lowercased() == r.pathB.lowercased() {
            error = "Location A and B are the same place. Choose two different drives or folders."
            return
        }
        var created: [String] = []
        for path in r.toCreate {
            do {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
                created.append(path)
            } catch {
                for c in created { try? FileManager.default.removeItem(atPath: c) }  // just-made, empty
                self.error = "Couldn't create \(path): \(error.localizedDescription)"
                return
            }
        }
        if let message = model.createPair(pathA: r.pathA, pathB: r.pathB) {
            for c in created { try? FileManager.default.removeItem(atPath: c) }
            error = message
        } else {
            dismiss()
        }
    }

    private func folderRow(_ label: String, _ path: Binding<String>) -> some View {
        HStack {
            Text(label).frame(width: 82, alignment: .leading)
            TextField("Choose a folder…", text: path)
                .textFieldStyle(.roundedBorder)
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.allowsMultipleSelection = false
                panel.prompt = "Choose"
                panel.message = "Choose the folder to sync for \(label)"
                if panel.runModal() == .OK, let url = panel.url {
                    path.wrappedValue = url.path
                    error = nil
                }
            }
        }
    }
}
