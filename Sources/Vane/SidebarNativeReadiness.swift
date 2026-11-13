import AppKit
import SwiftUI

/// Native readiness belongs to one supplying store and Space. Frozen preview
/// surfaces use separate IDs so their rows cannot acknowledge the live sidebar.
struct SidebarNativeReadinessScope: Hashable, Sendable {
    let storeID: ObjectIdentifier
    let spaceID: UUID?
    var surfaceID: UUID? = nil

    init(storeID: ObjectIdentifier, spaceID: UUID?, surfaceID: UUID? = nil) {
        self.storeID = storeID
        self.spaceID = spaceID
        self.surfaceID = surfaceID
    }
    @MainActor init(store: TabStore, spaceID: UUID?, surfaceID: UUID? = nil) {
        self.init(storeID: ObjectIdentifier(store), spaceID: spaceID, surfaceID: surfaceID)
    }
}

private struct SidebarNativeReadinessKey: EnvironmentKey {
    static let defaultValue: SidebarNativeReadinessScope? = nil
}
private struct SidebarNativeReadinessOwnerKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}
extension EnvironmentValues {
    /// One mounted live strip lifetime. Preview and coordinator-only fixtures may omit it.
    var sidebarNativeReadinessOwnerID: UUID? {
        get { self[SidebarNativeReadinessOwnerKey.self] }
        set { self[SidebarNativeReadinessOwnerKey.self] = newValue }
    }
    var sidebarNativeReadinessScope: SidebarNativeReadinessScope? {
        get { self[SidebarNativeReadinessKey.self] }
        set { self[SidebarNativeReadinessKey.self] = newValue }
    }
}

/// Plain main-actor state: only a blocked-to-ready transition signals observers.
/// Registration must precede deferred native population. Each registration has
/// a nonce as well as structural/geometry generations, rejecting detached owners'
/// callbacks even if a replacement happens to reuse those generation numbers.
@MainActor final class SidebarNativeReadinessCoordinator {
    static let shared = SidebarNativeReadinessCoordinator()
    struct Ticket: Hashable {
        let scope: SidebarNativeReadinessScope
        let section: ObjectIdentifier
        let generation: UInt64
        let geometryRevision: UInt64
        fileprivate let sectionKey: String?
        fileprivate let rowIDs: [String]?
        fileprivate let expectedEpoch: UInt64
        fileprivate let populationOwnerID: UUID?
        fileprivate let nonce: UUID
    }
    private struct Requirement {
        let ticket: Ticket
        var ready = false
    }
    private struct ExpectedSection {
        let rowIDs: [String]
        let ownerID: UUID?
        let epoch: UInt64
    }
    private struct Observation {
        let scope: SidebarNativeReadinessScope
        let ready: () -> Void
    }
    private var requirements: [SidebarNativeReadinessScope: [ObjectIdentifier: Requirement]] = [:]
    private var expected = Set<SidebarNativeReadinessScope>()
    private var expectationOwners: [SidebarNativeReadinessScope: Set<ObjectIdentifier>] = [:]
    private var observations: [UUID: Observation] = [:]
    private var declarations: [SidebarNativeReadinessScope: [String: ExpectedSection]] = [:]
    private var currentSections: [SidebarNativeReadinessScope: [String: Ticket]] = [:]
    private var declarationEpoch: UInt64 = 0

    /// Called while constructing the grouped live subtree, before SwiftUI can
    /// acknowledge its shell or update any section representable. Empty Spaces
    /// still configure an empty native Today section and explicitly complete it.
    func expectPopulation(_ scope: SidebarNativeReadinessScope, sections: [String: [String]]? = nil,
                          populationOwnerID: UUID? = nil) {
        expected.insert(scope)
        guard let sections else { return }
        let previous = declarations[scope] ?? [:]
        var next: [String: ExpectedSection] = [:]
        for (key, rows) in sections {
            if let existing = previous[key], existing.rowIDs == rows, existing.ownerID == populationOwnerID { next[key] = existing }
            else {
                declarationEpoch &+= 1
                next[key] = ExpectedSection(rowIDs: rows, ownerID: populationOwnerID, epoch: declarationEpoch)
            }
        }
        declarations[scope] = next
        currentSections[scope] = currentSections[scope]?.filter { key, ticket in
            guard let declaration = next[key] else { return false }
            return ticket.expectedEpoch == declaration.epoch && ticket.populationOwnerID == declaration.ownerID
        }
        requirements[scope] = requirements[scope]?.filter { _, requirement in
            guard let key = requirement.ticket.sectionKey else { return true }
            guard let declaration = next[key] else { return false }
            return requirement.ticket.expectedEpoch == declaration.epoch
                && requirement.ticket.populationOwnerID == declaration.ownerID
        }
        if requirements[scope]?.isEmpty == true { requirements.removeValue(forKey: scope) }
    }

    func retainPopulationExpectation(_ scope: SidebarNativeReadinessScope, owner: ObjectIdentifier,
                                     sections: [String: [String]]? = nil, populationOwnerID: UUID? = nil) {
        // Body declarations are authoritative. An old anchor update cannot
        // replace a newer body's owner or acquire that newer lifetime's lease.
        if let declared = declarations[scope],
           !declared.values.allSatisfy({ $0.ownerID == populationOwnerID }) { return }
        // A replacement's body may precede the previous anchor's final withdrawal.
        // Reinstall its captured declaration only after that lifecycle gap, or
        // refresh an existing declaration already belonging to this owner.
        if let sections { expectPopulation(scope, sections: sections, populationOwnerID: populationOwnerID) }
        expected.insert(scope)
        expectationOwners[scope, default: []].insert(owner)
    }
    func releasePopulationExpectation(_ scope: SidebarNativeReadinessScope, owner: ObjectIdentifier) {
        expectationOwners[scope]?.remove(owner)
        guard expectationOwners[scope]?.isEmpty == true else { return }
        expectationOwners.removeValue(forKey: scope)
        expected.remove(scope)
        declarations.removeValue(forKey: scope)
        currentSections.removeValue(forKey: scope)
        requirements.removeValue(forKey: scope)
        // Withdrawal is lifecycle cleanup, never a successful row-layout signal.
    }

    func register(scope: SidebarNativeReadinessScope?, section: ObjectIdentifier,
                  sectionKey: String? = nil, rowIDs: [String]? = nil,
                  generation: UInt64, geometryRevision: UInt64,
                  claimingCurrentSection: Bool = false, populationOwnerID: UUID? = nil) -> Ticket? {
        guard let scope else { return nil }
        // Semantic live sections belong to an active shell declaration. A parked
        // or detached owner cannot revive a scope with a late geometry callback.
        if let sectionKey {
            guard expected.contains(scope), let declaration = declarations[scope]?[sectionKey] else { return nil }
            guard populationOwnerID == declaration.ownerID else {
                if let previous = requirements[scope]?[section],
                   previous.ticket.populationOwnerID == populationOwnerID { unregister(previous.ticket) }
                return nil
            }
            guard rowIDs == declaration.rowIDs else {
                // An own-section structure update must revoke its old ready ticket,
                // while an obsolete different owner cannot modify the replacement.
                unregister(requirements[scope]?[section]?.ticket)
                return nil
            }
            if let current = currentSections[scope]?[sectionKey], current.section != section {
                guard claimingCurrentSection else {
                    unregister(requirements[scope]?[section]?.ticket)
                    return nil
                }
                // The authoritative configure supersedes the previous owner without
                // retaining an unreachable ready requirement for that native view.
                requirements[scope]?.removeValue(forKey: current.section)
            }
        }
        let epoch = sectionKey.flatMap { declarations[scope]?[$0]?.epoch } ?? 0
        if let current = requirements[scope]?[section], current.ticket.generation == generation,
           current.ticket.geometryRevision == geometryRevision, current.ticket.sectionKey == sectionKey,
           current.ticket.rowIDs == rowIDs, current.ticket.expectedEpoch == epoch,
           current.ticket.populationOwnerID == populationOwnerID,
           sectionKey.map({ currentSections[scope]?[$0] == current.ticket }) ?? true { return current.ticket }
        let ticket = Ticket(scope: scope, section: section, generation: generation,
                            geometryRevision: geometryRevision, sectionKey: sectionKey, rowIDs: rowIDs,
                            expectedEpoch: epoch, populationOwnerID: populationOwnerID, nonce: UUID())
        requirements[scope, default: [:]][section] = Requirement(ticket: ticket)
        if let sectionKey { currentSections[scope, default: [:]][sectionKey] = ticket }
        return ticket
    }

    func isReady(_ scope: SidebarNativeReadinessScope, allowingUnregistered: Bool = false) -> Bool {
        let sections = requirements[scope] ?? [:]
        if let declared = declarations[scope] {
            return declared.allSatisfy { key, expected in
                guard let ticket = currentSections[scope]?[key], ticket.expectedEpoch == expected.epoch,
                      ticket.rowIDs == expected.rowIDs, ticket.populationOwnerID == expected.ownerID,
                      let current = sections[ticket.section],
                      current.ticket == ticket else { return false }
                return current.ready
            }
        }
        if sections.isEmpty { return allowingUnregistered && !expected.contains(scope) }
        return sections.values.allSatisfy(\.ready)
    }

    func complete(_ ticket: Ticket?) {
        guard let ticket, var current = requirements[ticket.scope]?[ticket.section],
              current.ticket == ticket, !current.ready else { return }
        let wasReady = isReady(ticket.scope)
        current.ready = true
        requirements[ticket.scope]?[ticket.section] = current
        signalIfReady(ticket.scope, wasReady: wasReady)
    }

    func unregister(_ ticket: Ticket?) {
        guard let ticket, requirements[ticket.scope]?[ticket.section]?.ticket == ticket else { return }
        let wasReady = isReady(ticket.scope)
        requirements[ticket.scope]?.removeValue(forKey: ticket.section)
        if let key = ticket.sectionKey, currentSections[ticket.scope]?[key] == ticket {
            currentSections[ticket.scope]?.removeValue(forKey: key)
        }
        if requirements[ticket.scope]?.isEmpty == true { requirements.removeValue(forKey: ticket.scope) }
        signalIfReady(ticket.scope, wasReady: wasReady)
    }

    func observe(_ scope: SidebarNativeReadinessScope, ready: @escaping () -> Void) -> UUID {
        let token = UUID()
        observations[token] = Observation(scope: scope, ready: ready)
        return token
    }
    func removeObservation(_ token: UUID?) {
        if let token { observations.removeValue(forKey: token) }
    }
    private func signalIfReady(_ scope: SidebarNativeReadinessScope, wasReady: Bool) {
        guard !wasReady, isReady(scope) else { return }
        // A callback can retire its cover and unregister while this list is used.
        let callbacks = observations.values.filter { $0.scope == scope }.map(\.ready)
        for callback in callbacks { callback() }
    }
}

/// Frozen previews currently use eager/lazy SwiftUI rows rather than native
/// batches. These input-free anchors establish actual committed row layout;
/// allocating the enclosing NSHostingView does not make a preview claimable.
@MainActor private final class SidebarPreviewPopulationMarker: NSView {
    enum Kind: Equatable { case section(String, Int), row(String, Int) }
    var kind: Kind = .section("", 0)
    private var committedBounds: NSRect?
    private weak var committedWindow: NSWindow?
    override var isFlipped: Bool { true }
    var committed: Bool { window != nil && committedWindow === window && committedBounds == bounds }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func configure(_ kind: Kind) {
        guard self.kind != kind || committedBounds == nil else { return }
        self.kind = kind
        committedBounds = nil
        needsLayout = true
    }
    override func layout() {
        super.layout()
        committedBounds = bounds
        committedWindow = window
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        committedBounds = nil
        committedWindow = nil
        needsLayout = true
    }
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        let changed = frame.origin != newOrigin
        super.setFrameOrigin(newOrigin)
        if changed { committedBounds = nil; needsLayout = true }
    }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { committedBounds = nil; needsLayout = true }
    }
}

struct SidebarPreviewPopulationAnchor: NSViewRepresentable {
    let section: String
    var row: Int?
    var count = 0
    func makeNSView(context: Context) -> NSView { SidebarPreviewPopulationMarker(frame: .zero) }
    func updateNSView(_ view: NSView, context: Context) {
        (view as? SidebarPreviewPopulationMarker)?.configure(row.map { .row(section, $0) } ?? .section(section, count))
    }
}

/// LazyVStack can retain a trailing-gap estimate in its full extent and shift
/// later realized rows by that amount. Its committed row frames, rather than an
/// ideal absolute index origin, establish visible coverage. Native grouped rows
/// have exact owned geometry and retain their separate strict frame checks.
@MainActor enum SidebarPreviewPopulationCoverage {
    struct RowLayout {
        let index: Int
        let frame: CGRect
        /// Captures both current-window and current-bounds layout commitment.
        let committed: Bool
    }

    static func covers(visible: CGRect, sectionBounds: CGRect, rowCount: Int, rows: [RowLayout]) -> Bool {
        if rowCount == 0 || visible.isEmpty { return true }
        let pitch = Look.rowHeight + Look.rowGap
        let tolerance: CGFloat = 0.5
        let extentEstimate = sectionBounds.height - (CGFloat(rowCount) * pitch - Look.rowGap)
        let nearby = rows.filter {
            $0.frame.maxY >= visible.minY - Look.rowGap - tolerance
                && $0.frame.minY <= visible.maxY + Look.rowGap + tolerance
        }.sorted { $0.frame.minY < $1.frame.minY }
        guard let first = nearby.first, let last = nearby.last,
              first.frame.minY <= visible.minY + Look.rowGap + tolerance,
              last.frame.maxY >= visible.maxY - Look.rowGap - tolerance else { return false }
        var previous: RowLayout?
        for row in nearby {
            let shift = row.frame.minY - sectionBounds.minY - CGFloat(row.index) * pitch
            guard row.committed, row.index >= 0, row.index < rowCount,
                  abs(row.frame.height - Look.rowHeight) < tolerance,
                  abs(row.frame.width - sectionBounds.width) < tolerance,
                  abs(row.frame.minX - sectionBounds.minX) < tolerance,
                  shift >= min(0, extentEstimate) - tolerance,
                  shift <= max(0, extentEstimate) + tolerance else { return false }
            if let previous {
                guard row.index == previous.index + 1,
                      abs(row.frame.minY - previous.frame.maxY - Look.rowGap) < tolerance else { return false }
            }
            previous = row
        }
        if visible.minY <= sectionBounds.minY + tolerance {
            guard first.index == 0, abs(first.frame.minY - sectionBounds.minY) < tolerance else { return false }
        }
        if visible.maxY >= sectionBounds.maxY - tolerance, last.index != rowCount - 1 { return false }
        return true
    }
}

@MainActor enum SidebarPreviewPopulation {
    static func diagnostics(in root: NSView) -> String {
        guard let scroll = SidebarSectionsViewport.scrollView(in: root) else { return "missing viewport" }
        var markers: [SidebarPreviewPopulationMarker] = []
        func visit(_ view: NSView) {
            if let marker = view as? SidebarPreviewPopulationMarker { markers.append(marker) }
            view.subviews.forEach(visit)
        }
        visit(root)
        let pitch = Look.rowHeight + Look.rowGap
        var result = ["hidden=\(root.isHiddenOrHasHiddenAncestor)", "clip=\(scroll.contentView.bounds)"]
        for section in markers {
            guard case .section(let name, let count) = section.kind else { continue }
            let visible = section.convert(scroll.contentView.bounds, from: scroll.contentView).intersection(section.bounds)
            let rowMarkers = markers.compactMap { marker -> (Int, SidebarPreviewPopulationMarker)? in
                guard case .row(let rowSection, let index) = marker.kind, rowSection == name else { return nil }
                return (index, marker)
            }
            let actual = Dictionary(rowMarkers, uniquingKeysWith: { first, _ in first })
            let first = max(0, Int(floor(visible.minY.isFinite ? visible.minY / pitch : 0)))
            let end = min(count, Int(ceil(visible.maxY.isFinite ? visible.maxY / pitch : 0)))
            let details = (first..<max(first, end)).map { index -> String in
                guard let row = actual[index] else { return "\(index):missing" }
                return "\(index):committed=\(row.committed),y=\(row.convert(row.bounds,to:section).minY),size=\(row.bounds.size)"
            }
            result.append("section=\(name),count=\(count),committed=\(section.committed),bounds=\(section.bounds),visible=\(visible),anchors=\(actual.keys.sorted()),required=[\(details.joined(separator: ";"))]")
        }
        return result.joined(separator: " ")
    }

    static func isReady(in root: NSView) -> Bool {
        guard let window = root.window, let scroll = SidebarSectionsViewport.scrollView(in: root),
              scroll.contentView.bounds.height > 0 else { return false }
        var sections: [String: SidebarPreviewPopulationMarker] = [:]
        var rows: [String: [Int: SidebarPreviewPopulationMarker]] = [:]
        var duplicate = false
        func visit(_ view: NSView) {
            if let marker = view as? SidebarPreviewPopulationMarker {
                switch marker.kind {
                case .section(let section, _):
                    if sections.updateValue(marker, forKey: section) != nil { duplicate = true }
                case .row(let section, let index):
                    if rows[section, default: [:]].updateValue(marker, forKey: index) != nil { duplicate = true }
                }
            }
            for child in view.subviews { visit(child) }
        }
        visit(root)
        guard !duplicate, sections["today"] != nil else { return false }
        for (name, section) in sections {
            guard section.window === window, section.committed,
                  case .section(_, let count) = section.kind else { return false }
            if count == 0 { continue }
            guard section.bounds.width > 0 else { return false }
            let visible = section.convert(scroll.contentView.bounds, from: scroll.contentView)
                .intersection(section.bounds)
            if visible.isEmpty { continue }
            let layouts = (rows[name] ?? [:]).map { index, row in
                SidebarPreviewPopulationCoverage.RowLayout(index: index,
                    frame: row.convert(row.bounds, to: section), committed: row.window === window && row.committed)
            }
            guard SidebarPreviewPopulationCoverage.covers(visible: visible, sectionBounds: section.bounds,
                rowCount: count, rows: layouts) else { return false }
        }
        return true
    }
}
