import CoreGraphics

/// Where a dragged row lands. A sidebar row is three targets, not one: its top and bottom
/// edges put the dragged tab before or after it, and its middle — most of the row — puts the
/// two tabs side by side in a split, which is how Arc makes one. Which of the three a few
/// pixels of pointer mean is decided here, apart from any view, rather than being something
/// you can only find out by dragging.
enum Landing {
    /// A place in one section's rows, counted as they are drawn: `index` 0 is the first row.
    /// The section is part of it because Today and Pinned are two lists whose indices would
    /// otherwise collide.
    struct Spot: Equatable, Sendable {
        var kind: TabKind
        var index: Int
    }

    /// Which part of a row the pointer is in.
    enum Band: Equatable, Sendable { case before, onto, after }

    /// A quarter at each edge, the middle half for the split — the same shape a folder row
    /// has, because the question is the same one: beside it, or into it? The edges are
    /// narrow because a reorder is a move you can see happening and correct, while a split
    /// is a thing you have to undo, so the middle is the easier target to hit.
    nonisolated static func band(y: CGFloat, height: CGFloat) -> Band {
        guard height > 0 else { return .onto }
        if y < height / 4 { return .before }
        if y >= height * 3 / 4 { return .after }
        return .onto
    }

    /// Where the dragged row ends up if the pointer is at `band` of the row at `row`, while
    /// the dragged row itself sits at `source` in the same section — or nil when nothing
    /// should move. Three things are not a move: the middle of a row (that is a split), the
    /// dragged row's own slot, and the two edges either side of that slot, which are where
    /// it already is. `source` nil is a row from the *other* section, which has no slot here
    /// and so no place that is not a move.
    ///
    /// This is what makes a live reorder settle: the row moves only when the pointer crosses
    /// into a neighbour's edge, and the move puts the row's own slot under the pointer,
    /// where the answer is nil. There is nothing for it to oscillate between.
    nonisolated static func move(row: Int, band: Band, source: Int?) -> Int? {
        guard band != .onto, row >= 0 else { return nil }
        let landing = band == .before ? row : row + 1
        guard let source else { return landing }
        guard landing != source, landing != source + 1 else { return nil }
        return landing > source ? landing - 1 : landing
    }

    /// How many more tabs a split of `panes` will take. One is a plain tab, which becomes a
    /// split of two; `Split.maxPanes` is the ceiling, and a full one is not an offer at all.
    nonisolated static func roomToSplit(panes: Int) -> Int { max(0, Split.maxPanes - panes) }
}

// MARK: - check

extension Landing {
    nonisolated static func check() -> [(String, Bool)] {
        func at(_ y: CGFloat) -> Band { band(y: y, height: 40) }
        return [
            ("the top quarter of a row drops before it", at(0) == .before && at(9) == .before),
            ("the bottom quarter drops after it", at(30) == .after && at(39) == .after),
            ("the middle half splits with it",
             at(10) == .onto && at(20) == .onto && at(29) == .onto),
            ("the bands meet exactly at the quarters, with no pixel between them",
             at(9.9) == .before && at(10) == .onto && at(29.9) == .onto && at(30) == .after),
            ("the split is the easier target, because it is the one you cannot see coming",
             [at(10), at(20), at(29)].allSatisfy { $0 == .onto }),
            ("a row of no height is all middle, not all edge", band(y: 0, height: 0) == .onto),

            // Moving. Five rows, the dragged one third (index 2).
            ("crossing into the row above moves up one", move(row: 1, band: .before, source: 2) == 1),
            ("…and past it, two", move(row: 0, band: .before, source: 2) == 0),
            ("crossing into the row below moves down one", move(row: 3, band: .after, source: 2) == 3),
            ("the end of the list is a place like any other",
             move(row: 4, band: .after, source: 2) == 4),
            ("the top of the list is too", move(row: 0, band: .before, source: 4) == 0),
            ("the dragged row's own slot moves nothing",
             move(row: 2, band: .before, source: 2) == nil
                && move(row: 2, band: .after, source: 2) == nil),
            ("nor does the edge either side of it — that is where it already is",
             move(row: 1, band: .after, source: 2) == nil
                && move(row: 3, band: .before, source: 2) == nil),
            ("the middle of a row never moves anything: it is a split",
             move(row: 0, band: .onto, source: 2) == nil
                && move(row: 4, band: .onto, source: 2) == nil),
            ("a row dragged in from the other section has no slot, so every edge is a move",
             move(row: 2, band: .before, source: nil) == 2
                && move(row: 2, band: .after, source: nil) == 3),
            ("a nonsense row index moves nothing", move(row: -1, band: .before, source: 0) == nil),

            // Splitting.
            ("a plain tab has room for the rest of a split",
             roomToSplit(panes: 1) == Split.maxPanes - 1),
            ("a split with one place left takes one more",
             roomToSplit(panes: Split.maxPanes - 1) == 1),
            ("a full split refuses", roomToSplit(panes: Split.maxPanes) == 0),
            ("…and so does one that is somehow over full, rather than owing panes",
             roomToSplit(panes: Split.maxPanes + 3) == 0),
        ]
    }
}
