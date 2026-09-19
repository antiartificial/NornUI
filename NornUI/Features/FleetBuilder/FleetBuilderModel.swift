import Foundation
import CoreGraphics
import Observation

/// Editable state for the Fleet Builder: the draft, selection, and an undo/redo snapshot stack.
/// All derived data (graph, findings, cost, YAML) is computed from `draft` so the view stays thin.
@MainActor
@Observable
final class FleetBuilderModel {
    var draft: FleetDraft
    var selectedNodeID: String?
    /// A selected region band (0 = A, 1 = B), edited via the inspector. Mutually exclusive with a node.
    var selectedRegion: Int?

    private var undoStack: [FleetDraft] = []
    private var redoStack: [FleetDraft] = []
    private let undoLimit = 100

    init(draft: FleetDraft = FleetDraft()) {
        self.draft = draft
    }

    // MARK: Derived

    var graph: FleetGraph { draft.graph() }
    var findings: [FleetDraft.Finding] { draft.validate() }
    var costLines: [FleetDraft.CostLine] { draft.costLines() }
    var totalMonthlyUSD: Int { draft.totalMonthlyUSD() }
    var hasBlockingFindings: Bool { draft.hasBlockingFindings }
    var selectedNode: FleetGraphNode? { selectedNodeID.flatMap { graph.node($0) } }
    func clusterYAML() -> String { draft.clusterYAML() }

    // MARK: History

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Snapshot the current draft, then apply a change. Use for every discrete edit.
    func mutate(_ change: (inout FleetDraft) -> Void) {
        pushUndo()
        change(&draft)
    }

    /// Snapshot once at the start of a continuous interaction (e.g. a drag).
    func beginInteraction() { pushUndo() }

    private func pushUndo() {
        undoStack.append(draft)
        if undoStack.count > undoLimit { undoStack.removeFirst(undoStack.count - undoLimit) }
        redoStack.removeAll()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(draft)
        draft = previous
        pruneSelection()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(draft)
        draft = next
        pruneSelection()
    }

    private func pruneSelection() {
        if let id = selectedNodeID, graph.node(id) == nil { selectedNodeID = nil }
    }

    // MARK: Node movement (drag)

    /// Update a node's manual position without a snapshot (call `beginInteraction()` on drag start).
    func moveNode(id: String, to point: CGPoint) {
        draft.positions[id] = point
        if let svcID = graph.node(id)?.serviceID, let i = draft.services.firstIndex(where: { $0.id == svcID }) {
            draft.services[i].position = point
        }
        if let exID = graph.node(id)?.extraID, let i = draft.extras.firstIndex(where: { $0.id == exID }) {
            draft.extras[i].position = point
        }
    }

    func select(_ id: String?) {
        selectedNodeID = id
        if id != nil { selectedRegion = nil }
    }

    /// Select a region band for editing (clears any node selection).
    func selectRegion(_ region: Int?) {
        selectedRegion = region
        if region != nil { selectedNodeID = nil }
    }

    func clearSelection() { selectedNodeID = nil; selectedRegion = nil }

    // MARK: Toolbar mutations

    func setRegions(_ n: Int) { mutate { $0.regions = min(2, max(1, n)) }; pruneSelection() }
    func setEdge(_ mode: FleetEdgeMode) { mutate { $0.edge = mode } }
    func setRegion(_ region: String) { mutate { $0.region = region } }
    func setSecondRegion(_ region: String) { mutate { $0.secondRegion = region } }
    func setName(_ name: String) { mutate { $0.name = name } }

    func stepControlA(_ delta: Int) { mutate { $0.controlA = Self.oddStep($0.controlA, delta) } }
    func stepControlB(_ delta: Int) { mutate { $0.controlB = Self.controlBStep($0.controlB, delta) } }
    func stepAppA(_ delta: Int) { mutate { $0.appA = min(5, max(1, $0.appA + delta)) } }
    func stepAppB(_ delta: Int) { mutate { $0.appB = min(5, max(1, $0.appB + delta)) } }

    static func oddStep(_ current: Int, _ delta: Int) -> Int {
        delta > 0 ? min(7, current + 2) : max(3, current - 2)
    }
    static func controlBStep(_ current: Int, _ delta: Int) -> Int {
        if delta > 0 { return current == 0 ? 3 : min(7, current + 2) }
        return current <= 3 ? 0 : current - 2
    }

    // MARK: DB mutations

    func setDBMode(_ mode: FleetDBMode) {
        mutate {
            $0.db.mode = mode
            if mode == .selfManaged { $0.db.engine = .pg; $0.db.replica = false }
        }
    }
    func setDBEngine(_ engine: FleetDBEngine) { mutate { $0.db.engine = engine } }
    func setDBReplica(_ on: Bool) { mutate { $0.db.replica = on } }
    func setReplicaRegion(_ region: FleetReplicaRegion) { mutate { $0.db.replicaRegion = region } }
    func setManagedDBSize(_ slug: String) { mutate { $0.db.managedSize = slug } }
    func setSelfDBSize(_ slug: String) { mutate { $0.db.selfSize = slug } }
    func setControlSize(_ slug: String) { mutate { $0.sizes.control = slug } }
    func setAppSize(_ slug: String) { mutate { $0.sizes.app = slug } }

    // MARK: Independent pools

    func addCache() { addService(kind: .cache) }
    func addQueue() { addService(kind: .queue) }

    private func addService(kind: FleetServiceKind) {
        let pool = FleetServicePool(kind: kind, engine: kind.defaultEngine, size: kind.defaultSize, count: kind.defaultCount)
        mutate { $0.services.append(pool) }
        if let index = draft.services.firstIndex(where: { $0.id == pool.id }) {
            selectedNodeID = "sv\(index)"
        }
    }

    func updateService(id: UUID, _ change: (inout FleetServicePool) -> Void) {
        guard let index = draft.services.firstIndex(where: { $0.id == id }) else { return }
        mutate { change(&$0.services[index]) }
    }
    func removeService(id: UUID) {
        mutate { $0.services.removeAll { $0.id == id } }
        selectedNodeID = nil
    }

    func addTestDB() {
        let pool = FleetTestDB()
        mutate { $0.extras.append(pool) }
        if let index = draft.extras.firstIndex(where: { $0.id == pool.id }) {
            selectedNodeID = "ex\(index)"
        }
    }
    func updateExtra(id: UUID, _ change: (inout FleetTestDB) -> Void) {
        guard let index = draft.extras.firstIndex(where: { $0.id == id }) else { return }
        mutate { change(&$0.extras[index]) }
    }
    func removeExtra(id: UUID) {
        mutate { $0.extras.removeAll { $0.id == id } }
        selectedNodeID = nil
    }
}
