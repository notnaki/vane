import Foundation

@MainActor protocol SidebarWarmOwnerRetaining: AnyObject {
    func discardInactiveOwners(in scope: SidebarNativeReadinessScope)
    func revokeInactiveOwners()
}

/// One budget across every section of a supplying store. Tickets retain no views
/// or stores; the native section owns the graphs and their actual lifetime.
@MainActor enum SidebarWarmOwnerBudget {
    private struct Ticket {
        weak var holder: (any SidebarWarmOwnerRetaining)?
        weak var store: TabStore?
        let scope: SidebarNativeReadinessScope
        let graphs: Int
        let serial: UInt64
    }
    private static var tickets: [UUID: Ticket] = [:]
    private static var serial: UInt64 = 0
    private(set) static var underPressure = false
    static let graphLimit = 16

    static func retain(_ holder: any SidebarWarmOwnerRetaining,
                       scope: SidebarNativeReadinessScope, graphs: Int, store: TabStore) -> UUID? {
        guard !underPressure, graphs > 0, graphs <= graphLimit,
              scope.storeID == ObjectIdentifier(store) else { return nil }
        tickets = tickets.filter { $0.value.holder != nil && $0.value.store != nil }
        while tickets.values.filter({ $0.scope.storeID == scope.storeID }).reduce(0, { $0 + $1.graphs }) + graphs > graphLimit {
            // A section may configure before its sibling. Protect the selected
            // Space's tickets across both until each has consumed its own archive.
            guard let oldest = tickets.filter({ $0.value.scope.storeID == scope.storeID
                && $0.value.scope.spaceID != $0.value.store?.currentSpaceID })
                .min(by: { $0.value.serial < $1.value.serial }) else { return nil }
            tickets.removeValue(forKey: oldest.key)
            oldest.value.holder?.discardInactiveOwners(in: oldest.value.scope)
        }
        serial &+= 1
        let token = UUID()
        tickets[token] = Ticket(holder: holder, store: store, scope: scope, graphs: graphs, serial: serial)
        return token
    }

    static func release(_ token: UUID) { tickets.removeValue(forKey: token) }

    static func purge() {
        let holders = tickets.values.compactMap(\.holder)
        tickets.removeAll()
        for holder in holders { holder.revokeInactiveOwners() }
    }

    static func setUnderPressure(_ value: Bool) {
        underPressure = value
        if value { purge() }
    }
}
