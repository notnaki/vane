import Foundation
import XCTest
@testable import vane

@MainActor final class IssueReportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testLogIsBoundedAndExcludesPrivateEvents() {
        let log = DiagnosticLog(capacity: 3)
        log.record(.navigationStarted, at: now.addingTimeInterval(-301))
        log.record(.navigationCommitted, at: now.addingTimeInterval(-300))
        log.record(.navigationFinished, at: now.addingTimeInterval(-60))
        log.record(.navigationFailed, code: -1009, isPrivate: true, at: now)
        XCTAssertEqual(log.snapshot(at: now).events.map(\.kind), [.navigationCommitted, .navigationFinished])
        log.record(.navigationFailed, code: -1001, at: now)
        log.record(.webContentTerminated, at: now)
        let snapshot = log.snapshot(at: now)
        XCTAssertEqual(snapshot.events.count, 3)
        XCTAssertEqual(snapshot.events.map(\.kind), [.navigationFinished, .navigationFailed, .webContentTerminated])
        XCTAssertEqual(snapshot.events[1].code, -1001)
    }

    func testSnapshotFreezesTheWindowAndExcludesFutureEvents() {
        let log = DiagnosticLog()
        log.record(.navigationStarted, at: now.addingTimeInterval(-61))
        log.record(.navigationCommitted, at: now.addingTimeInterval(-60))
        log.record(.navigationFailed, code: -1009, at: now)
        log.record(.navigationFinished, at: now.addingTimeInterval(1))
        let frozen = log.snapshot(at: now)
        log.record(.webContentTerminated, at: now.addingTimeInterval(10))
        XCTAssertEqual(frozen.events(in: .minute).map(\.kind), [.navigationCommitted, .navigationFailed])
        XCTAssertEqual(frozen.events(in: .thirtySeconds).map(\.kind), [.navigationFailed])
        XCTAssertEqual(frozen.events(in: .fiveMinutes).count, 3)
    }

    func testNewDraftOmitsLogsAndOptInUsesOnlySelectedWindow() {
        let log = DiagnosticLog()
        log.record(.navigationStarted, at: now.addingTimeInterval(-100))
        log.record(.navigationFailed, code: -1009, at: now)
        var draft = IssueReportDraft(snapshot: log.snapshot(at: now), environment: "Vane 1.2 (34)\nmacOS 26.0")
        draft.title = "A page failed"
        draft.details = "Steps: open a page.\nExpected: it loads."
        XCTAssertFalse(draft.includeLogs)
        XCTAssertTrue(draft.markdown.contains(draft.details))
        XCTAssertTrue(draft.markdown.contains("Vane 1.2 (34)"))
        XCTAssertFalse(draft.markdown.contains("navigation.failed"))
        draft.includeLogs = true
        XCTAssertTrue(draft.markdown.contains("navigation.failed code=-1009"))
        XCTAssertFalse(draft.markdown.contains("navigation.started"))
        draft.period = .fiveMinutes
        XCTAssertTrue(draft.markdown.contains("navigation.started"))
        draft.includeLogs = false
        XCTAssertFalse(draft.markdown.contains("navigation.started"))
    }

    func testEmptyWindowExplainsMissingEventsWithoutPretendingTheyWereCaptured() {
        var draft = IssueReportDraft(snapshot: DiagnosticLog().snapshot(at: now), environment: "fixture")
        draft.includeLogs = true
        XCTAssertTrue(draft.markdown.contains("No diagnostic events in this window."))
        XCTAssertTrue(draft.markdown.contains("at most 2,000 events"))
    }

    func testGitHubHandoffPreservesUnicodeAndQueryCharacters() throws {
        let title = "Fails & hangs? #1 🪶"
        let body = "A + B & C\n````\n秘密 # ? % =\n````"
        let handoff = IssueReportHandoff(title: title, markdown: body)
        XCTAssertFalse(handoff.requiresPaste)
        let parts = try XCTUnwrap(URLComponents(url: handoff.url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.host, "github.com")
        XCTAssertEqual(parts.path, "/notnaki/vane/issues/new")
        XCTAssertEqual(parts.queryItems?.first { $0.name == "title" }?.value, title)
        XCTAssertEqual(parts.queryItems?.first { $0.name == "body" }?.value, body)
        // A literal plus must survive form-style query decoding, not become a space.
        XCTAssertTrue(handoff.url.absoluteString.contains("%2B"))
        XCTAssertEqual(handoff.clipboardText, body)
    }

    func testOversizeReportUsesExplicitPasteHandoffWithoutDroppingText() {
        let body = String(repeating: "🪶 log & detail\n", count: 2_000)
        let handoff = IssueReportHandoff(title: String(repeating: "🪶", count: 4_000), markdown: body)
        XCTAssertTrue(handoff.requiresPaste)
        XCTAssertLessThanOrEqual(handoff.url.absoluteString.utf8.count, IssueReportHandoff.maximumURLBytes)
        XCTAssertEqual(handoff.clipboardText, body)
        XCTAssertEqual(handoff.url.host, "github.com")
        XCTAssertEqual(handoff.url.scheme, "https")
    }

    func testFallbackStaysBoundedEvenWhenOneGraphemeHasThousandsOfCombiningMarks() {
        let title = "e" + String(repeating: "\u{301}", count: 10_000)
        let handoff = IssueReportHandoff(title: title, markdown: "Full report")
        XCTAssertTrue(handoff.requiresPaste)
        XCTAssertLessThanOrEqual(handoff.url.absoluteString.utf8.count, IssueReportHandoff.maximumURLBytes)
    }

    func testShareRequiresBothSummaryAndDescription() {
        var draft = IssueReportDraft(snapshot: DiagnosticLog().snapshot(), environment: "fixture")
        XCTAssertFalse(draft.canShare)
        draft.title = "Title"
        draft.details = " \n "
        XCTAssertFalse(draft.canShare)
        draft.details = "Reproduction"
        XCTAssertTrue(draft.canShare)
    }

    func testOversizedDraftPreservesEntireSummaryInReviewedAndCopiedReport() {
        for summary in [String(repeating: "A long summary ", count: 40),
                        "e" + String(repeating: "\u{301}", count: 2_000)] {
            var draft = IssueReportDraft(snapshot: DiagnosticLog().snapshot(), environment: "fixture")
            draft.title = summary
            draft.details = String(repeating: "Full reproduction steps\n", count: 2_000)
            let handoff = draft.handoff
            XCTAssertTrue(handoff.requiresPaste)
            XCTAssertNotNil(draft.markdown.range(of: summary, options: .literal), "The preview must retain the complete summary")
            XCTAssertNotNil(handoff.clipboardText.range(of: summary, options: .literal), "The copied report must retain the complete summary")
            XCTAssertNotNil(handoff.clipboardText.range(of: draft.details, options: .literal))
        }
    }
}
