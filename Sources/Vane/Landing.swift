import CoreGraphics

/// A normal sidebar drag picks the nearest gap. Option-drag additionally offers a split
/// in the middle of a row; ordinary reordering never has to aim at a narrow edge.
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

    /// The whole row offers before/after unless the user explicitly requests a split.
    nonisolated static func band(y: CGFloat, height: CGFloat, splitting: Bool = false) -> Band {
        guard height > 0 else { return splitting ? .onto : .before }
        if !splitting { return y < height / 2 ? .before : .after }
        if y < height / 4 { return .before }
        if y >= height * 3 / 4 { return .after }
        return .onto
    }

    /// Which pane of the split the dragged tab becomes: the first, or the one after it.
    enum Side: Equatable, Sendable { case leading, trailing }

    /// Which half of the row the pointer is in, and so which side of the target the dragged
    /// tab takes: the left half of a row makes it the leading pane (left, or top when the
    /// split is stacked), the right half the trailing one. There is no middle — the middle
    /// of the row is what said "split" in the first place — and a pointer exactly half way
    /// takes the trailing side, the same way `band` resolves the boundary between two of its
    /// three.
    ///
    /// `rtl` mirrors it: a right-to-left window draws the leading pane on the *right*, so the
    /// left half of the row there is asking for the trailing one. The x is the view's own,
    /// which counts up to the right whichever way the window reads.
    nonisolated static func side(x: CGFloat, width: CGFloat, rtl: Bool = false) -> Side {
        guard width > 0 else { return .leading }
        return (x < width / 2) != rtl ? .leading : .trailing
    }

    /// Which physical end of the row the lit half is drawn at — true for the left — once
    /// SwiftUI has resolved the alignment the row draws it with. `.leading` is the window's
    /// leading edge, not the screen's, so it is the *right* of the row in a right-to-left
    /// window; `side` mirrors too, and the two mirrors cancel, which is the point: the half
    /// that lights is always the half the pointer is in.
    ///
    /// Not called by the row — the row hands SwiftUI a `.leading`/`.trailing` alignment and
    /// SwiftUI does this. It is here so the round trip from a pointer to a lit half can be
    /// proved offline, and so a sign error in `side` cannot pass unnoticed in a layout
    /// nobody on the team reads in.
    nonisolated static func drawsLeft(_ side: Side, rtl: Bool) -> Bool { (side == .leading) != rtl }

    /// Where the dragged row ends up if the pointer is at `band` of the row at `row`, while
    /// the dragged row itself sits at `source` in the same section — or nil when nothing
    /// should move. Three things are not a move: the middle of a row (that is a split), the
    /// dragged row's own slot, and the two edges either side of that slot, which are where
    /// it already is. `source` nil is a row from the *other* section, which has no slot here
    /// and so no place that is not a move.
    ///
    /// The source stays fixed throughout the drag; adjacent gaps suppress redundant feedback.
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
        func at(_ y: CGFloat) -> Band { band(y: y, height: 40, splitting: true) }
        return [
            ("the top quarter of a row drops before it", at(0) == .before && at(9) == .before),
            ("the bottom quarter drops after it", at(30) == .after && at(39) == .after),
            ("the middle half splits with it",
             at(10) == .onto && at(20) == .onto && at(29) == .onto),
            ("the bands meet exactly at the quarters, with no pixel between them",
             at(9.9) == .before && at(10) == .onto && at(29.9) == .onto && at(30) == .after),
            ("ordinary dragging uses the full row for the nearest gap",
             band(y: 19.9, height: 40) == .before && band(y: 20, height: 40) == .after),
            ("a row of no height is all middle, not all edge", band(y: 0, height: 0, splitting: true) == .onto),

            // Which side of the target the split opens on. A 200pt row.
            ("the left half of the row makes the dragged tab the leading pane",
             side(x: 0, width: 200) == .leading && side(x: 99, width: 200) == .leading),
            ("the right half makes it the trailing one",
             side(x: 100, width: 200) == .trailing && side(x: 200, width: 200) == .trailing),
            ("the halves meet at the middle, with no pixel between them",
             side(x: 99.9, width: 200) == .leading && side(x: 100, width: 200) == .trailing),
            ("a right-to-left window draws leading on the right, so the halves mirror",
             side(x: 40, width: 200, rtl: true) == .trailing
                && side(x: 160, width: 200, rtl: true) == .leading),
            ("a row of no width is all leading, not a divide by zero",
             side(x: 0, width: 0) == .leading && side(x: 50, width: 0) == .leading),
            ("the half that lights is the half the pointer is in, whichever way it reads",
             [false, true].allSatisfy { rtl in
                 [CGFloat(0), 40, 99, 100, 160, 200].allSatisfy { x in
                     drawsLeft(side(x: x, width: 200, rtl: rtl), rtl: rtl) == (x < 100)
                 }
             }),
            ("a left-to-right window draws the leading pane on the left, and the other on "
             + "the right",
             drawsLeft(.leading, rtl: false) && !drawsLeft(.trailing, rtl: false)),
            ("a right-to-left window draws them the other way round",
             !drawsLeft(.leading, rtl: true) && drawsLeft(.trailing, rtl: true)),

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
