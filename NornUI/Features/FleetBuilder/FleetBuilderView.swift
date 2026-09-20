import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Design-time Fleet Builder: compose a fleet as a node topology with live validation and cost,
/// then export a `norn.dev/fleet/v1` cluster.yaml. Applying is deferred to the GitOps/apply path.
struct FleetBuilderView: View {
    @State private var model = FleetBuilderModel()
    @State private var exporting = false
    @State private var exportingJSON = false
    @State private var importingJSON = false
    @State private var showYAML = false
    @State private var shareError: String?

    var body: some View {
        VStack(spacing: 0) {
            compositionBar
            Divider()
            HSplitView {
                FleetBuilderCanvas(model: model)
                    .frame(minWidth: 420)
                if showYAML {
                    yamlPane
                        .frame(minWidth: 280, idealWidth: 360, maxWidth: 560)
                }
                inspector
                    .frame(minWidth: 300, idealWidth: 322, maxWidth: 390)
            }
        }
        .toolbar { toolbarItems }
        .navigationTitle("Fleet Builder")
        .fileExporter(
            isPresented: $exporting,
            document: YAMLDocument(text: model.clusterYAML()),
            contentType: .plainText,
            defaultFilename: "\(model.draft.name)-fleet.yaml"
        ) { _ in }
        .fileExporter(
            isPresented: $exportingJSON,
            document: JSONDocument(data: (try? model.exportDraftJSON()) ?? Data()),
            contentType: .json,
            defaultFilename: "\(model.draft.name).fleet.json"
        ) { _ in }
        .fileImporter(isPresented: $importingJSON, allowedContentTypes: [.json]) { result in
            importDraft(result)
        }
        .alert("Import failed", isPresented: Binding(get: { shareError != nil }, set: { if !$0 { shareError = nil } })) {
            Button("OK", role: .cancel) { shareError = nil }
        } message: { Text(shareError ?? "") }
    }

    // MARK: Window toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo).help("Undo").keyboardShortcut("z", modifiers: .command)
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo).help("Redo").keyboardShortcut("z", modifiers: [.command, .shift])
            Toggle(isOn: $showYAML) { Label("YAML", systemImage: "chevron.left.forwardslash.chevron.right") }
                .help("Show the generated cluster.yaml").keyboardShortcut("y", modifiers: .command)
            Button { copyYAML() } label: { Label("Copy YAML", systemImage: "doc.on.doc") }
                .help("Copy cluster.yaml to the clipboard")
            Button { exporting = true } label: { Label("Export", systemImage: "square.and.arrow.down") }
                .help("Save cluster.yaml")
            Menu {
                Button { copyJSON() } label: { Label("Copy fleet JSON", systemImage: "doc.on.doc") }
                Button { exportingJSON = true } label: { Label("Export fleet JSON…", systemImage: "square.and.arrow.up") }
                Button { importingJSON = true } label: { Label("Import fleet JSON…", systemImage: "square.and.arrow.down.on.square") }
            } label: { Label("Share", systemImage: "square.and.arrow.up.on.square") }
                .help("Share this fleet as a portable JSON config")
        }
    }

    private func copyJSON() {
        guard let data = try? model.exportDraftJSON(), let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func importDraft(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try model.importDraftJSON(try Data(contentsOf: url))
            } catch {
                shareError = error.localizedDescription
            }
        case .failure(let error):
            shareError = error.localizedDescription
        }
    }

    // MARK: Composition bar

    private var compositionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                HStack(spacing: 5) {
                    Text("Cluster").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    TextField("cluster name", text: Binding(get: { model.draft.name }, set: { model.draft.name = $0 }))
                        .textFieldStyle(.roundedBorder).font(.callout.monospaced()).frame(width: 132)
                }
                labeledPicker(model.draft.regions == 2 ? "Region A" : "Region",
                              selection: Binding(get: { model.draft.region }, set: { model.setRegion($0) })) {
                    ForEach(FleetCatalog.regionOptions, id: \.self) { region in
                        Text(region + (FleetCatalog.hasSpaces(region) ? "" : " ⚠")).tag(region)
                    }
                }
                if model.draft.regions == 2 {
                    labeledPicker("Region B", selection: Binding(get: { model.draft.secondRegion }, set: { model.setSecondRegion($0) })) {
                        ForEach(FleetCatalog.regionOptions, id: \.self) { region in
                            Text(region + (FleetCatalog.hasSpaces(region) ? "" : " ⚠")).tag(region)
                        }
                    }
                }
                labeledPicker("Edge", selection: Binding(get: { model.draft.edge }, set: { model.setEdge($0) })) {
                    ForEach(FleetEdgeMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                stepperControl("Regions", value: model.draft.regions) { model.setRegions(model.draft.regions + $0) }
                stepperControl(model.draft.regions == 2 ? "Control · A" : "Control", value: model.draft.controlA) { model.stepControlA($0) }
                if model.draft.regions == 2 {
                    stepperControl("Control · B", value: model.draft.controlB) { model.stepControlB($0) }
                }
                stepperControl(model.draft.regions == 2 ? "App · A" : "App", value: model.draft.appA) { model.stepAppA($0) }
                if model.draft.regions == 2 {
                    stepperControl("App · B", value: model.draft.appB) { model.stepAppB($0) }
                }
                Menu {
                    Button("Cache pool (Valkey)") { model.addCache() }
                    Button("Queue pool (Redpanda)") { model.addQueue() }
                    Button("Test database") { model.addTestDB() }
                } label: { Label("Add", systemImage: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                Spacer(minLength: 8)
                statusPill
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
        }
    }

    private var statusPill: some View {
        let blocking = model.findings.filter { $0.severity == "error" }.count
        let warnings = model.findings.filter { $0.severity == "warning" }.count
        let status: NornStatus = blocking > 0 ? .critical : warnings > 0 ? .attention : .healthy
        let text = blocking > 0 ? "\(blocking) blocking" : warnings > 0 ? "\(warnings) warning" : "Valid"
        return NornStatusBadge(status: status, label: text)
    }

    // MARK: Generated cluster.yaml

    private var yamlPane: some View {
        let yaml = model.clusterYAML()
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right").foregroundStyle(.secondary)
                Text("cluster.yaml").font(.callout.weight(.semibold))
                Text("norn.dev/fleet/v1").font(.caption2.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button { copyYAML() } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy to clipboard")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                Text(yaml)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityLabel("Generated cluster.yaml document")
    }

    // MARK: Inspector

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                nodeInspector
                validationPanel
                costPanel
            }
            .padding(16)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var nodeInspector: some View {
        if let node = model.selectedNode {
            NornSurfaceCard(title: inspectorTitle(node)) {
                nodeEditor(node)
            }
        } else if let region = model.selectedRegion {
            NornSurfaceCard(title: region == 0 ? "Region A" : "Region B") {
                regionEditor(region)
            }
        } else {
            NornSurfaceCard(title: "Fleet Builder") {
                Text("Select a node to configure it, or click a region label to reassign it. Drag nodes to rearrange. Use the bar above to add regions, control planes, app pools, cache, queue, and databases.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func regionEditor(_ region: Int) -> some View {
        let current = region == 0 ? model.draft.region : model.draft.secondRegion
        Picker("Region", selection: Binding(
            get: { current },
            set: { region == 0 ? model.setRegion($0) : model.setSecondRegion($0) }
        )) {
            ForEach(FleetCatalog.regionOptions, id: \.self) { r in
                Text(r + (FleetCatalog.hasSpaces(r) ? "" : " ⚠ no Spaces")).tag(r)
            }
        }
        .pickerStyle(.inline)
        if model.draft.regions == 2 && model.draft.region == model.draft.secondRegion {
            Text("Region A and B are both \(current). A second region should be distinct for HA — pick another (you can override).")
                .font(.caption).foregroundStyle(.orange)
        } else if !FleetCatalog.hasSpaces(current) {
            Text("\(current) has no DO Spaces — state + WAL backup need a Spaces region.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text(region == 0 ? "Primary region — hosts the managed/self database." : "Secondary region for the HA app pool.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func inspectorTitle(_ node: FleetGraphNode) -> String {
        switch node.kind {
        case .control: "Control plane"
        case .app: "App pool"
        case .dbPrimary: "Database"
        case .dbReplica: "Read replica"
        case .dbExtra: "Test database"
        case .cache: "Cache"
        case .queue: "Queue"
        case .lb, .edgeCloudflare, .edgeDNS: "Ingress"
        case .spaces: "Object storage"
        }
    }

    @ViewBuilder
    private func nodeEditor(_ node: FleetGraphNode) -> some View {
        switch node.kind {
        case .control:
            sizePicker("Node size", selection: Binding(get: { model.draft.sizes.control }, set: { model.setControlSize($0) }), sizes: FleetCatalog.nodeSizes)
            Text("Region \(node.region == 0 ? model.draft.region : model.draft.secondRegion) · shared control-plane size")
                .font(.caption).foregroundStyle(.secondary)
        case .app:
            sizePicker("Node size", selection: Binding(get: { model.draft.sizes.app }, set: { model.setAppSize($0) }), sizes: FleetCatalog.nodeSizes)
            Text(model.draft.regions == 2 ? "A: \(model.draft.appA) · B: \(model.draft.appB) nodes" : "\(model.draft.appA) nodes")
                .font(.caption).foregroundStyle(.secondary)
        case .dbPrimary, .dbReplica:
            databaseEditor
        case .dbExtra:
            if let id = node.extraID { testDBEditor(id) }
        case .cache, .queue:
            if let id = node.serviceID { serviceEditor(id, kind: node.kind == .cache ? .cache : .queue) }
        case .lb, .edgeCloudflare, .edgeDNS:
            ingressEditor
        case .spaces:
            Text(model.draft.hasSpaces ? "\(model.draft.region) has DO Spaces for terraform state and WAL backup." : "\(model.draft.region) has no DO Spaces — choose a Spaces region.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var databaseEditor: some View {
        Picker("Deployment", selection: Binding(get: { model.draft.db.mode }, set: { model.setDBMode($0) })) {
            ForEach(FleetDBMode.allCases, id: \.self) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented)
        Picker("Engine", selection: Binding(get: { model.draft.db.engine }, set: { model.setDBEngine($0) })) {
            ForEach(FleetDBEngine.allCases, id: \.self) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented).disabled(model.draft.db.mode == .selfManaged)
        if model.draft.db.mode == .managed {
            sizePicker("Size", selection: Binding(get: { model.draft.db.managedSize }, set: { model.setManagedDBSize($0) }), sizes: FleetCatalog.managedSizes)
            Toggle("Read replica", isOn: Binding(get: { model.draft.db.replica }, set: { model.setDBReplica($0) }))
            if model.draft.db.replica && model.draft.regions == 2 {
                Picker("Replica region", selection: Binding(get: { model.draft.db.replicaRegion }, set: { model.setReplicaRegion($0) })) {
                    Text("Same region").tag(FleetReplicaRegion.same)
                    Text("Region B").tag(FleetReplicaRegion.b)
                }.pickerStyle(.segmented)
            }
            Text("Provider-run HA, backups & failover. Replicas default to the primary's region.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            sizePicker("Size", selection: Binding(get: { model.draft.db.selfSize }, set: { model.setSelfDBSize($0) }), sizes: FleetCatalog.nodeSizes)
            Text("Patroni ×3 in-VPC HA. Managed is recommended for production.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func testDBEditor(_ id: UUID) -> some View {
        if let extra = model.draft.extras.first(where: { $0.id == id }) {
            Picker("Deployment", selection: Binding(get: { extra.mode }, set: { newValue in model.updateExtra(id: id) { e in e.mode = newValue; if newValue == .selfManaged { e.engine = .pg; e.size = "s-2vcpu-4gb" } else { e.size = "db-s-2vcpu-4gb" } } })) {
                ForEach(FleetDBMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Picker("Engine", selection: Binding(get: { extra.engine }, set: { newValue in model.updateExtra(id: id) { $0.engine = newValue } })) {
                ForEach(FleetDBEngine.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).disabled(extra.mode == .selfManaged)
            sizePicker("Size", selection: Binding(get: { extra.size }, set: { newValue in model.updateExtra(id: id) { $0.size = newValue } }),
                       sizes: extra.mode == .managed ? FleetCatalog.managedSizes : FleetCatalog.nodeSizes)
            Button("Remove pool", role: .destructive) { model.removeExtra(id: id) }
        }
    }

    @ViewBuilder
    private func serviceEditor(_ id: UUID, kind: FleetServiceKind) -> some View {
        if let svc = model.draft.services.first(where: { $0.id == id }) {
            Picker("Engine", selection: Binding(get: { svc.engine }, set: { newValue in model.updateService(id: id) { $0.engine = newValue } })) {
                ForEach(kind.engineOptions, id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented)
            sizePicker("Node size", selection: Binding(get: { svc.size }, set: { newValue in model.updateService(id: id) { $0.size = newValue } }), sizes: FleetCatalog.nodeSizes)
            Stepper("Nodes: \(svc.count)", onIncrement: { model.updateService(id: id) { $0.count = min(9, $0.count + 1) } },
                    onDecrement: { model.updateService(id: id) { $0.count = max(1, $0.count - 1) } })
            Text("Runs on its own nodes with durable storage — independent of the stateless app pool.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Remove pool", role: .destructive) { model.removeService(id: id) }
        }
    }

    @ViewBuilder
    private var ingressEditor: some View {
        Picker("Edge", selection: Binding(get: { model.draft.edge }, set: { model.setEdge($0) })) {
            ForEach(FleetEdgeMode.allCases, id: \.self) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented)
        Text(model.draft.edge == .cloudflare
             ? "Cloudflare → regional LB → apps. Global anycast/WAF; the DO LB stays the origin."
             : "DigitalOcean regional load balancer in front of the app pool.")
            .font(.caption).foregroundStyle(.secondary)
    }

    // MARK: Validation + cost

    private var validationPanel: some View {
        NornSurfaceCard(title: "Validation") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.findings) { finding in
                    HStack(alignment: .top, spacing: 8) {
                        NornStatusGlyph(status: status(for: finding.severity), size: 12, pulsesWhenActive: false)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(finding.message).font(.caption)
                            if let remediation = finding.remediation {
                                Text(remediation).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var costPanel: some View {
        NornSurfaceCard(title: "Estimated cost") {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(model.costLines) { line in
                    HStack {
                        Text(line.label).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(line.usdMonthly == 0 ? "free" : "$\(line.usdMonthly)").font(.caption.monospacedDigit())
                    }
                }
                Divider()
                HStack {
                    Text("Total").font(.callout.weight(.semibold))
                    Spacer()
                    Text("$\(model.totalMonthlyUSD)/mo").font(.callout.weight(.bold).monospacedDigit())
                }
            }
        }
    }

    private func status(for severity: String) -> NornStatus {
        switch severity {
        case "error": .critical
        case "warning": .attention
        default: .neutral
        }
    }

    // MARK: Reusable controls

    private func labeledPicker<S: Hashable, Content: View>(_ label: String, selection: Binding<S>, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Picker(label, selection: selection, content: content).labelsHidden().fixedSize()
        }
    }

    private func stepperControl(_ label: String, value: Int, onStep: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Text("\(value)").font(.caption.monospacedDigit().weight(.semibold)).frame(minWidth: 14)
            Stepper(label, onIncrement: { onStep(1) }, onDecrement: { onStep(-1) }).labelsHidden()
        }
    }

    private func sizePicker(_ label: String, selection: Binding<String>, sizes: [FleetCatalog.Size]) -> some View {
        Picker(label, selection: selection) {
            ForEach(sizes) { size in
                Text("\(size.slug) · \(size.specLabel) · $\(size.usdMonthly)/mo").tag(size.slug)
            }
        }
    }

    // MARK: Export

    private func copyYAML() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.clusterYAML(), forType: .string)
    }
}

/// Minimal text document for `.fileExporter` (cluster.yaml).
struct YAMLDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Minimal document for exporting the shareable fleet JSON.
struct JSONDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
