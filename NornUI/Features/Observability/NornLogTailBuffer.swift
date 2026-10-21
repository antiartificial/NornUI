import Foundation

/// Bounded, de-duplicated log buffer shared by the initial query and live tail.
/// Entries stay in the order the user is viewing: newest first for `.backward`,
/// oldest first for `.forward`.
nonisolated struct NornLogTailBuffer: Equatable, Sendable {
    static let defaultCapacity = 10_000

    private(set) var entries: [NornLogEntry] = []
    private(set) var newestTime: String?
    private var newestDate = Date.distantPast
    private var seen: Set<String> = []
    let capacity: Int
    let direction: NornLogFilter.Direction

    init(direction: NornLogFilter.Direction = .backward, capacity: Int = defaultCapacity) {
        self.direction = direction
        self.capacity = max(capacity, 1)
    }

    /// Replaces the buffer with a query result (already in the viewing direction).
    mutating func replace(with result: [NornLogEntry]) {
        self = NornLogTailBuffer(direction: direction, capacity: capacity)
        let unique = result.filter { seen.insert($0.dedupKey).inserted }
        entries = direction == .backward ? Array(unique.prefix(capacity)) : Array(unique.suffix(capacity))
        seen = Set(entries.map(\.dedupKey))
        for entry in unique { noteNewest(entry) }
    }

    /// Merges a chronological (oldest first) poll result. Returns how many entries were new.
    @discardableResult
    mutating func append(chronological batch: [NornLogEntry]) -> Int {
        let fresh = batch.filter { seen.insert($0.dedupKey).inserted }
        guard !fresh.isEmpty else { return 0 }
        for entry in fresh { noteNewest(entry) }
        if direction == .backward {
            entries.insert(contentsOf: fresh.reversed(), at: 0)
            trim(dropping: entries.count - capacity, fromFront: false)
        } else {
            entries.append(contentsOf: fresh)
            trim(dropping: entries.count - capacity, fromFront: true)
        }
        return fresh.count
    }

    private mutating func noteNewest(_ entry: NornLogEntry) {
        if entry.date >= newestDate {
            newestDate = entry.date
            newestTime = entry.time
        }
    }

    private mutating func trim(dropping count: Int, fromFront: Bool) {
        guard count > 0 else { return }
        let dropped = fromFront ? entries.prefix(count) : entries.suffix(count)
        for entry in dropped { seen.remove(entry.dedupKey) }
        if fromFront { entries.removeFirst(count) } else { entries.removeLast(count) }
    }
}
