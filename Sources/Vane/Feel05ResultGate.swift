/// Retained rows stay mounted while a new request runs, but their actions must
/// belong to the exact request that produced them. Comparing the request also
/// closes the gap before an input change has updated a loading indicator.
struct Feel05ResultGate<Request: Equatable> {
    private var presented: Request?

    mutating func present(_ request: Request) { presented = request }

    func isCurrent(_ request: Request, refreshing: Bool) -> Bool {
        !refreshing && presented == request
    }

    func performIfCurrent(_ request: Request, refreshing: Bool, _ action: () -> Void) {
        guard isCurrent(request, refreshing: refreshing) else { return }
        action()
    }
}
