import AppKit

/// An open palette owns this small, query-local layout. Late suggestions fill its
/// one slot without reconstructing or ranking tabs, archives and commands again.
struct Feel03PaletteLayout<Row> {
    var leading: [Row] = []
    var trailing: [Row] = []
    var assistant: Row?
    var acceptsSuggestions = false

    func rows(suggestions: [Row]) -> [Row] {
        var out = leading
        if acceptsSuggestions { out += suggestions }
        if let assistant { out.insert(assistant, at: min(leading.count + 1, out.count)) }
        out += trailing
        return out
    }

    /// Keep an arrowed destination visible when insertions push it beyond the usual
    /// cap. A new query resets selection and returns to the normal bounded list.
    static func visible(_ rows: [Row], limit: Int, retaining selectedID: String?,
                        id: (Row) -> String) -> [Row] {
        let selectedEnd = selectedID.flatMap { selected in
            rows.firstIndex { id($0) == selected }.map { $0 + 1 }
        } ?? 0
        return Array(rows.prefix(max(limit, selectedEnd)))
    }
}

/// Progress, loading and media updates do not change a search result. Compare only
/// what the palette displays or ranks, including ownership and MRU ordering.
struct Feel03TabContent: Equatable {
    let id: UUID
    let owner: ObjectIdentifier
    let windowNumber: Int
    let title: String
    let address: String
    let favicon: ObjectIdentifier?
    let lastActive: Date
    let current: Bool

    /// Shared tabs can appear in two windows. A keyboard destination includes the
    /// owner window as well as the page, so their rows must have distinct identities.
    static func rowID(_ id: UUID, owner: AnyObject) -> String {
        "tab:\(id.uuidString):\(ObjectIdentifier(owner))"
    }

    @MainActor init(_ tab: Tab, owner: TabStore, windowNumber: Int) {
        id = tab.id
        self.owner = ObjectIdentifier(owner)
        self.windowNumber = windowNumber
        title = tab.title
        address = tab.address
        favicon = tab.favicon.map(ObjectIdentifier.init)
        lastActive = tab.lastActive
        current = owner.current == tab.id
    }
}
