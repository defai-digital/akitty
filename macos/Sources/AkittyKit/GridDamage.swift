/// Damage relative to the last raster submitted, including coalesced screen scrolls.
struct GridDamage {
    private(set) var rows: Set<Int>?
    private(set) var scroll = 0

    init(rows: Set<Int>? = nil) { self.rows = rows }

    mutating func merge(_ snapshot: Snapshot) {
        guard snapshot.partial == true, let dirty = snapshot.dirty,
              dirty.allSatisfy({ (0..<snapshot.rows).contains($0) }) else {
            self = GridDamage(); return
        }
        guard var rows else { return } // A full repaint is already pending.
        let shift = snapshot.shift ?? 0
        guard shift >= 0, shift < snapshot.rows, scroll + shift < snapshot.rows else {
            self = GridDamage(); return
        }
        if shift > 0 {
            rows = Set(rows.compactMap { $0 >= shift ? $0 - shift : nil })
            scroll += shift
            rows.formUnion(snapshot.rows - shift..<snapshot.rows)
        }
        rows.formUnion(dirty)
        self.rows = rows
    }
}
