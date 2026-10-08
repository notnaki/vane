# Offline Reading Queue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Save readable articles into a profile-scoped queue that supports offline Reader, saved-text search, explicit read state, removal, usage visibility, and complete backup/restore.

**Architecture:** Persist validated article trees and bounded raster resources in immutable published article directories. Serialize publication, read-state replacement, deletion, and backup capture on the main actor; perform image work and search against immutable values. Generate saved Reader HTML with current Reader preferences in a dedicated nonpersistent web view.

**Tech Stack:** Swift 6, Foundation, Combine, SwiftUI, AppKit, WebKit, ImageIO, CryptoKit, XCTest; no new dependency.

**Spec:** `docs/superpowers/specs/2026-10-08-offline-reading-queue-design.md`

## Global Constraints

- Validate on macOS 27 while retaining the project's macOS 26 deployment target.
- Use supported public Foundation, AppKit, SwiftUI, ImageIO, and WebKit APIs. Add no dependency or private WebKit API.
- Private windows cannot save articles, access queue repositories, stage content, or see regular-profile snapshots.
- New saves are unread. Opening a snapshot does not silently mark it read.
- Initial limits are 5 MiB per image, 20 unique images per article, 40 megapixels per decoded image, 2 MiB of UTF-8 article text, 4 MiB for article.json, 20 MiB for a completed snapshot, and 1,000 snapshots per profile.
- Bound trees to 50,000 nodes and 64 levels, and individual URL/attribute strings to 16 KiB before recursive rendering.
- Allow at most five redirects, 15 seconds per resource, and 60 seconds total for image collection.
- No remote image fallback, automatic navigation, scripts, frames, forms, or arbitrary local resource reads in saved Reader.
- Published paths are ReadingQueue/<profile UUID lowercase>/<article UUID lowercase>/article.json and images/<generated resource UUID lowercase>.png or .jpg. Staging/trash are never backup entries.
- Backups retain their 512 MiB total limit and fail without trimming.
- Use Vane's short list/status transitions; System Reduce Motion and Battery Saver make these state changes immediate.
- Work only on codex/offline-reading-queue and preserve unrelated changes. Follow independent PR review, fixes, CI, squash-merge, and tracked test-app cleanup from AGENTS.md.

## Review Focus

1. Same-URL reloads during capture: document identity changes must cancel publication even when the URL is unchanged (Task 3).
2. Slow/oversized image streams without trustworthy headers: preserve article text, bound memory/time, and disclose missing images (Task 3).
3. Damaged published records beside healthy ones: preserve originals, expose removal/retry, and never overwrite the queue as empty (Task 2).
4. Removing an article while its saved window is open: release/clear the view and prevent stale read-state writes (Tasks 4 and 5).
5. Restoring a pre-queue backup: remove current published snapshots and recover their exact originals after interruption (Task 6).

## File map and execution order

Create `ReadingArticle.swift` for the value schema/codec, `ReadingQueueFiles.swift`
for validated path and inventory operations, `ReadingQueueStore.swift` for repository
mutations/observability, `ReadingQueueImages.swift` for bounded ephemeral raster
fetching, `ReadingQueueCapture.swift` for browser capture commands, and
`SavedReaderWindow.swift` for isolated saved reading. Create
`ReadingQueuePane.swift` for Library rows/search/usage. Keep these units focused;
do not restructure unrelated browser code.

Modify Reader.swift only for retained extraction lifecycle, safe image mapping in
rendering, and shared preference application. Modify Engine.swift at tab document
lifecycle boundaries; modify Profiles.swift at profile deletion. Wire LibraryWindow,
UI, Menu, and Keybindings at their existing entry points. After backup PR #330
merges, modify BackupArchive, BackupLibrary, BackupRestore, and BackupSettings for
the queue's exact allowlist and preview counts. Update README with feature behavior
and practical limits in the task that finishes the feature.

All tasks depend on Task 1's schema. Tasks 2 and 3 define the storage/capture boundary;
Tasks 4 and 5 use it; Task 6 integrates the published inventory. Recommend native
execution in this session because the lifecycle, shared Reader renderer, and backup
ownership rules require close sequential coordination.

---

### Task 1: Validated article schema and codec

**Files:** Create Sources/Vane/ReadingArticle.swift; create Tests/VaneTests/ReadingQueueFixture.swift and ReadingQueueCodecTests.swift.

**Interfaces:** Produce ReadingArticle: Codable, Sendable, Identifiable, Equatable,
with version = 1, id, profileID, title, sourceURL, capturedAt, isRead, byline, nodes,
resources, and missingImages. Nested Node has x: String?, e: String?,
a: [String: String]?, c: [Node]? and defaulted initializer like Reader.Node.
Resource has name: String, byteCount: Int, digest: String, pixelWidth: Int,
pixelHeight: Int. ReadingQueueCandidate is Sendable with article: ReadingArticle
and images: [String: Data]. ReadingArticleCodec exposes
encode(_ article: ReadingArticle) throws -> Data,
decode(_ data: Data, profileID: UUID, articleID: UUID) throws -> ReadingArticle,
validate(_ candidate: ReadingQueueCandidate) throws,
plainText(_ article: ReadingArticle) -> String,
and matches(_ article: ReadingArticle, query: String) -> Bool.
ReadingQueueFailure: LocalizedError defines privateBrowsing, unsupported,
staleCapture, missing, invalid(String), futureVersion, tooLarge, storage(String).

- [ ] Write fixture article constructors and regression tests before implementation:

```swift
func makeReadingArticle(profileID: UUID = ProfileManager.defaultID,
                        text: String = "Saved body contains Café and nebula.") -> ReadingArticle {
    ReadingArticle(profileID: profileID, title: "Fixture article",
        sourceURL: "https://example.test/article",
        nodes: [.init(e: "p", c: [.init(x: text)])])
}
func testBodySearchAndOwnership() throws {
    let article = makeReadingArticle()
    XCTAssertTrue(ReadingArticleCodec.matches(article, query: "CAFE"))
    XCTAssertTrue(ReadingArticleCodec.matches(article, query: "nebula"))
    let bytes = try ReadingArticleCodec.encode(article)
    XCTAssertEqual(try ReadingArticleCodec.decode(bytes, profileID: article.profileID,
        articleID: article.id), article)
    XCTAssertThrowsError(try ReadingArticleCodec.decode(bytes, profileID: UUID(),
        articleID: article.id))
}
```

- [ ] Run `swift test --filter ReadingQueueCodecTests`; confirm missing production types cause the expected failure.
- [ ] Implement the schema and bounded codec. Check data size before JSON decoding; validate tree iteratively before recursive operations. Require exactly one text/element representation per node, permitted tags/attributes only, valid HTTP/HTTPS source URL with host, finite date, nonincognito profile, and path/record identity. Require absolute HTTP/HTTPS/mailto links; image src must map to a declared generated local resource name. Escape output later through Reader, never trust persisted markup.

```swift
enum ReadingArticleCodec {
    static let recordLimit = 4 * 1024 * 1024
    static func decode(_ data: Data, profileID: UUID, articleID: UUID) throws -> ReadingArticle {
        guard data.count <= recordLimit else { throw ReadingQueueFailure.tooLarge }
        let article = try JSONDecoder().decode(ReadingArticle.self, from: data)
        guard article.profileID == profileID, article.id == articleID else {
            throw ReadingQueueFailure.invalid("The saved article belongs to another profile or entry.")
        }
        try validateRecord(article)
        return article
    }
}
```

Define validateRecord(_ article: ReadingArticle) throws in this same file. Validate
resource byte count/digest and dimensions against actual image data in
validate(_ candidate:); missing/extra resources and wrong digests fail.
- [ ] Add assertions for unknown versions, invalid dates/URLs/attributes, 65-level trees, too many nodes, oversized records/text, invalid resource names, and search ignoring accents while finding URL/byline text. Run `swift test --filter ReadingQueueCodecTests`; require passing.
- [ ] Commit schema/tests with `git commit -m 'feat: define validated offline article snapshots'` after a staged diff check.

### Task 2: Atomic profile repository and safe inventory

**Files:** Create Sources/Vane/ReadingQueueFiles.swift and ReadingQueueStore.swift; create Tests/VaneTests/ReadingQueueStoreTests.swift and ReadingQueuePathTests.swift; modify Sources/Vane/Profiles.swift.

**Interfaces:** ReadingQueueFiles exposes root(in directory: URL) -> URL,
articleURL(profileID: UUID, articleID: UUID, in directory: URL) -> URL,
ownedNames(in directory: URL) throws -> [String], parseOwnedName(_ name: String)
-> (profileID: UUID, articleID: UUID)?, and validated parent/file checks.
ReadingQueueStore: @MainActor ObservableObject exposes init(profileID: UUID,
directory: URL) throws, shared(profileID: UUID, directory: URL) throws ->
ReadingQueueStore, publish(_ candidate: ReadingQueueCandidate) throws ->
ReadingArticle, setRead(_ read: Bool, id: UUID) throws, remove(_ id: UUID) throws,
reload(), and static forget(profileID: UUID, directory: URL) throws.
Published properties: articles: [ReadingArticle], damaged: [ReadingQueueDamage],
usage: ReadingQueueUsage, error: String?. ReadingQueueDamage: Identifiable has
id: UUID and message: String; ReadingQueueUsage has articleCount: Int,
publishedBytes: Int64, pendingCleanupBytes: Int64. Expose a test-injected mutation
checkpoint `(String) throws -> Void`, defaulting to no-op, with stage, publish,
read-state, and delete phases. All public mutations reject invalidated repositories.

- [ ] Write atomicity/isolation tests with temporary roots and an injected failing checkpoint:

```swift
func testPrivateRepositoryNeverCreatesFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertThrowsError(try ReadingQueueStore(profileID: Profile.incognito.id, directory: root))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
}
func testFailedPublicationLeavesInventoryEmpty() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try ReadingQueueStore(profileID: ProfileManager.defaultID, directory: root,
        checkpoint: { phase in if phase == "publish" { throw CocoaError(.fileWriteNoPermission) } })
    XCTAssertThrowsError(try repository.publish(.init(article: makeReadingArticle(), images: [:])))
    XCTAssertTrue(repository.articles.isEmpty)
    XCTAssertTrue(try ReadingQueueFiles.ownedNames(in: root).isEmpty)
}
```

- [ ] Run `swift test --filter 'ReadingQueueStoreTests|ReadingQueuePathTests'`; confirm expected missing-interface failures.
- [ ] Implement canonical lowercase UUID inventory paths and exact filenames; inspect each path component for symlinks. Build candidates in .staging; validate resources and bytes; rename completed directories into inventory on the main actor; publish UI state after success. Check duplicates, profile count, and candidate ownership before mutation. Use an atomic article.json replacement for read changes. Move removals to nonpublished trash before updating rows, then clean it. Provide cleanup retry and accurate pending bytes.

```swift
let record = try ReadingArticleCodec.encode(candidate.article)
try record.write(to: staging.appendingPathComponent("article.json"), options: .atomic)
try checkpoint("publish")
try FileManager.default.moveItem(at: staging, to: destination)
Motion.list { articles.append(candidate.article) }
```

In publish, staging and destination are validated URLs from ReadingQueueFiles;
write candidate images and validate the completed directory before the shown move.
Use defer to remove failed staging. No actor suspension occurs between final
destination/count/profile validation and publication.
- [ ] Test persistent read changes and failed replacements keeping prior state; removal and failed cleanup accounting; exact duplicate sources; two profiles; poisoned parents/files; extra resources; healthy and damaged siblings; abandonment cleanup; invalidated store refusing delayed saves. Test safe damaged-entry removal by directory ID even when record decoding fails.
- [ ] Add profile deletion invalidation/queue removal alongside EaselStore.forget. Preserve/report cleanup failures using existing save-failure/toast patterns rather than falsely claiming removal. Run focused queue tests and ProfilePersistenceTests.
- [ ] Commit with `git commit -m 'feat: persist profile reading queues atomically'`.

### Task 3: Reader capture, bounded images, and lifecycle cancellation

**Files:** Create Sources/Vane/ReadingQueueImages.swift and ReadingQueueCapture.swift; modify Reader.swift and Engine.swift; create Tests/VaneTests/ReadingQueueCaptureTests.swift and ReadingQueueImageTests.swift; extend fixture helpers for local article/image HTTP.

**Interfaces:** Tab gains readingDocumentGeneration: UUID, renewed at real document
navigation/replacement/tearDown. Reader exposes savedExtraction(for tab: Tab) ->
Extraction? and forget(tab: Tab); retained values include source URL and generation.
ReadingQueueImages exposes collect(urls: [URL]) async -> ReadingQueueImageResult,
where ReadingQueueImageResult: Sendable has resources: [ReadingArticle.Resource], images: [String: Data],
mapping: [String: String], missingCount: Int. Provide a URLSession-backed loader
and injectable protocol `ReadingQueueImageLoading: Sendable` with that collect
signature. ReadingQueueCapture: @MainActor ObservableObject exposes
save(tab: Tab, in store: TabStore) async, capturing: Set<UUID>, messages:
[UUID: String], and canSave(tab: Tab?, in store: TabStore?) -> Bool. Its testable
capture(tab: Tab, in store: TabStore, repository: ReadingQueueStore,
images: any ReadingQueueImageLoading) async throws -> ReadingArticle performs
extraction, normalized-node conversion, stale guards, image collection, publication.

- [ ] Add tests for unsupported short content, private capture with a loader that records zero calls, and navigation while an injected loader is suspended. Include a same-URL reload that changes generation and a deleted profile/repository.

```swift
let capturedGeneration = tab.readingDocumentGeneration
tab.readingDocumentGeneration = UUID() // models a same-URL new document
XCTAssertNotEqual(tab.readingDocumentGeneration, capturedGeneration)
// Resume the test loader and assert capture throws staleCapture and inventory is empty.
```

Implement the suspended test loader as an actor with a checked continuation and
explicit resume(); await a started signal before mutating tab generation. Drive
the actual capture call so the assertion covers publication rather than just UUIDs.
- [ ] Run `swift test --filter 'ReadingQueueCaptureTests|ReadingQueueImageTests'`; confirm failures before implementation.
- [ ] Implement retained extraction on successful Reader entry, clear it on Engine
navigation/tearDown, and share a monotonic identity check with capture. Normalization
must use Reader's current allowed tags/escaping/link resolution, preserving text,
tables/captions if supported by merged Reader work; map images only to collected
resources. Preserve practical lead image handling without duplicate body images.

```swift
guard !store.isPrivate, tab.profileID == store.profileID,
      repository.profileID == store.profileID else { throw ReadingQueueFailure.privateBrowsing }
let generation = tab.readingDocumentGeneration
let source = try validatedHTTPSource(tab.existingWeb?.url)
// validatedHTTPSource(_ url: URL?) throws -> URL is defined in ReadingQueueCapture.
```

After every async extraction/image boundary, verify generation, web identity,
source URL, tab liveness, store profile, and repository validity. Publication stays
synchronous on the main actor. Gate queue access before any image/storage work.
- [ ] Implement ephemeral URLSession streaming with disabled cookie handling,
credential storage, and URL cache. Enforce redirects/time budgets/byte bounds;
check HTTP status and ImageIO dimensions before full raster decode/re-encode.
Test headerless oversized streams, redirects to disallowed schemes, timeout,
broken/nonimage/SVG bodies, huge dimensions, duplicate URLs, and image budget.
Save text with missing count when image collection fails; never persist remote src.
- [ ] Test saving retained Reader content, byline/title/date/source fidelity,
coalesced duplicate requests, unrelated tabs remaining usable, and no DOM mutation.
Run focused capture/image/Reader and lifecycle tests, plus pure selfchecks.
- [ ] Commit with `git commit -m 'feat: capture articles and bounded images for offline reading'`.

### Task 4: Isolated saved Reader with current preferences

**Files:** Create Sources/Vane/SavedReaderWindow.swift; modify Sources/Vane/Reader.swift; create Tests/VaneTests/SavedReaderTests.swift.

**Interfaces:** Reader adds a shared safe renderer path that consumes a validated
ReadingArticle and local resource mapping; expose SavedReaderDocument.html(article:
ReadingArticle) -> String and image-URL mapping without relaxing the live renderer's
HTTP URL whitelist. SavedReaderWindow exposes show(articleID: UUID, repository:
ReadingQueueStore, origin: TabStore), forget(profileID: UUID), and
close(articleID: UUID, profileID: UUID). SavedReaderNavigation.allowed(url: URL,
articleDirectory: URL, userInitiated: Bool) -> Bool is pure and testable. Shared
Reader preference application must target a WKWebView directly as well as a Tab.

- [ ] Write hostile-content/rendering and navigation tests:

```swift
let article = makeReadingArticle(text: "<script>window.bad = true</script>")
let html = SavedReaderDocument.html(article: article)
XCTAssertTrue(html.contains("&lt;script&gt;"))
XCTAssertTrue(html.contains("Saved copy"))
XCTAssertTrue(html.contains("Content-Security-Policy"))
XCTAssertFalse(SavedReaderNavigation.allowed(url: URL(string: "https://tracker.test/pixel")!,
    articleDirectory: directory, userInitiated: false))
```

Define directory as a temporary selected article URL; test sibling paths, traversal,
forms, and nonuser external navigation. Run `swift test --filter SavedReaderTests`
before implementing; require failure.
- [ ] Implement a dedicated NSWindow hosting native saved metadata/actions and
WKWebView. Use `.nonPersistent()` website data, no user scripts/extensions, disabled
page JavaScript, default-deny CSP with local raster images and inline Reader CSS,
and narrow file access. Load generated HTML from a task-owned temporary presentation
directory containing only the selected article's validated images; the read-access
boundary is that presentation directory, never Store.directory. This presentation
cache is disposable, excluded from backups, and removed when its view closes.

```swift
let configuration = WKWebViewConfiguration()
configuration.websiteDataStore = .nonPersistent()
configuration.defaultWebpagePreferences.allowsContentJavaScript = false
let web = WKWebView(frame: .zero, configuration: configuration)
web.loadFileURL(documentURL, allowingReadAccessTo: presentationDirectory)
```

Use separate explicit native source/link actions that open ordinary tabs through
origin only when it remains a regular store for the same profile. Cancel web
navigation to external targets; permit deliberate user links via delegate handoff,
requiring a user navigation type and approved HTTP/HTTPS/mailto URL. Never use JS
bridge messages to trigger automatic browser actions.
- [ ] Reuse merged Reader preference controls and CSS generator for font, typeface,
line spacing, and width. Reflect changes in open saved views; use immediate style
changes under Motion.reduced. Do not save generated styles into article.json.
- [ ] Test no remote image fallback, local image rendering with the server stopped,
preferences changing without article-byte changes, source escaping, read-state
remaining unread after open, profile deletion/removal closing the view, and webview
lifetime release. Run focused SavedReaderTests and ReaderTests.
- [ ] Commit with `git commit -m 'feat: read saved articles in isolated Reader windows'`.

### Task 5: Library queue, explicit actions, search, and usage

**Files:** Create Sources/Vane/ReadingQueuePane.swift and Tests/VaneTests/ReadingQueueLibraryTests.swift; modify LibraryWindow.swift, UI.swift, Menu.swift, Keybindings.swift, Profiles.swift, README.md, and relevant Library inline checks.

**Interfaces:** Add LibrarySection.readingQueue with title Reading Queue,
icon text.book.closed, normal search support, and private availability false.
ReadingQueueFilter: String, CaseIterable has all, unread, read.
ReadingQueueSearch.results(articles: [ReadingArticle], query: String,
filter: ReadingQueueFilter) -> [ReadingArticle] is nonisolated; results sort by
capture date descending then ID string. ReadingQueuePane consumes repository:
ReadingQueueStore and origin: TabStore. Add Action.saveForOffline and
Action.readingQueue, with no default shortcut collision.

- [ ] Write pure search/private-availability and mutation-feedback tests:

```swift
var first = makeReadingArticle(text: "A buried nebula appears here")
first.isRead = true
let second = makeReadingArticle(text: "An unrelated article")
XCTAssertEqual(ReadingQueueSearch.results(articles: [first, second], query: "nebula",
    filter: .read).map(\.id), [first.id])
XCTAssertTrue(ReadingQueueSearch.results(articles: [first], query: "nebula",
    filter: .unread).isEmpty)
XCTAssertFalse(LibrarySection.readingQueue.available(private: true))
```

- [ ] Run `swift test --filter ReadingQueueLibraryTests`; confirm failures.
- [ ] Wire the new Library section using store.profileID and private guards;
update exhaustive case lists and inline tests. Add Library-native row/actions,
All/Unread/Read filter, damaged-state Retry/remove, total disk usage, pending-cleanup
usage, empty state, and per-article size. Use shared Library query/focus conventions.
Search detached immutable inputs and cancel/discard outdated query/profile tokens.

```swift
Button(article.isRead ? "Mark Unread" : "Mark Read") {
    do { try repository.setRead(!article.isRead, id: article.id) }
    catch { message = error.localizedDescription }
}
```

Define pane @State message: String?; show errors inline and accessible. Observe
repository changes so removal closes its saved window and stale buttons fail safely.
- [ ] Add Save for Offline and Reading Queue to native menu/page actions. Show
Saving…, Already Saved/Open Saved Copy, unsupported/retry feedback, and private
disabled explanation. Use the current originating store for all operations, not
ProfileManager.activeProfileID. Keep visible keyboard focus and VoiceOver labels.
- [ ] Wrap observable list/status mutations in Motion.list. Validate selection/filter
changes and button feedback in normal, Reduce Motion, and Battery Saver policies.
Document anonymous best-effort images, unsupported-page limits, explicit read state,
source/capture distinction, profile storage, and backup inclusion in README.
- [ ] Run queue tests, LibrarySwipeTests, DownloadLibraryTests, ProfilePersistenceTests,
and pure selfchecks; commit `feat: add the offline reading queue to Library`.

### Task 6: Complete backup/restore ownership and rollback

**Files:** Modify merged Sources/Vane/BackupArchive.swift, BackupLibrary.swift,
BackupRestore.swift, BackupSettings.swift; create Tests/VaneTests/ReadingQueueBackupTests.swift and extend BackupRestoreTests.swift.

**Interfaces:** Reuse ReadingQueueFiles.parseOwnedName/ownedNames and
ReadingArticleCodec.decode/validate. Extend BackupPreview.ProfileSummary with
readingQueue: Int and BackupPreview total; add exact queue path handling to
BackupPaths.isOwned/isOriginal. BackupLibrary capture stays synchronous on the main
actor; BackupRestore installs only validated parent paths before writing records.

- [ ] Confirm #330 merged with `gh pr view 330 --json state,mergedAt,mergeCommit`.
Fetch and rebase this clean branch on origin/main; do not cherry-pick or edit the
other worktree. If Reader work merged too, resolve against its current renderer,
preference controls, and extraction types. A pending dependency is not permission
to omit backup integration or bypass validation.
- [ ] Write backup round-trip tests with a seeded BackupFixture, published article
and raster resource, and read state. Capture and validate; restore into another
isolated root; assert record fields, ID, image digest, and usage match.

```swift
let article = makeReadingArticle()
let repository = try ReadingQueueStore(profileID: article.profileID, directory: fixture.root)
_ = try repository.publish(.init(article: article, images: [:]))
let archive = try fixture.library.capture(reason: .manual)
XCTAssertTrue(archive.files.contains { $0.name.hasPrefix("ReadingQueue/") })
XCTAssertEqual(try fixture.library.validate(archive).readingQueue, 1)
```

Define fixture using BackupFixture(), seed it before publishing, and clean it in
teardown. Use Task 1's normalized image candidate fixture for image round trips.
- [ ] Run `swift test --filter ReadingQueueBackupTests`; confirm the allowlist/count
failures before integration.
- [ ] Extend explicit ownership grammar and bounded inventory enumeration. Include
damaged but safely named published originals for rollback while validated export
fails with an actionable error. Reject unexpected files/resources/profiles and
staging entries in incoming archives. In restore installation, validate/create
each allowed parent directory and reject symlinks before BackupIO.write.
Delete empty inventory directories after absent-file removal without traversing
or deleting unrelated app data. Queue initialization cleans nonpublished remnants.
- [ ] Test a pending background staged save while capture runs: backup includes only
the old published inventory, and later publication cannot mutate immutable backup
bytes. Test staged symlinks/traversal, orphan profile, missing/extra/damaged images,
oversized queue contributions, and incoming snapshots with future versions.
- [ ] Test pre-queue restore removing current articles and every checkpoint interruption
restoring exact raw queue originals, including damaged current records. Reuse
BackupRestore's injected checkpoint mechanism; confirm rollback doesn't lose image
bytes or pending metadata. Test missing queues and two profiles in previews.
- [ ] Update export/restore disclosure and counts. Run focused queue/backup tests,
ProfilePersistenceTests, debug build, pure selfchecks, and WebKit startup check.
Commit `feat: include saved articles in backups and transactional restores`.

### Task 7: Live verification, independent PR review, fixes, and merge

**Files:** README.md only if live checks expose a documentation correction; task-scoped production/tests for review fixes.

- [ ] Build the debug app using documented make-app flags in the current README.
Launch only with isolated VANE_DATA_DIR and temporary preference suite. Record the
bundle's absolute path, PID, executable, and process start time immediately.
- [ ] Exercise article save, unsupported page, failed save, missing image, and
private controls against deterministic local fixtures. Stop the fixture server;
open the saved copy and verify text/images, Saved copy/date/source, preference
changes, explicit read/unread, body search, removal, and disk usage. Exercise the
same flow in a second profile and verify no cross-profile results. Confirm a live
page tab remains separate and a saved window has no automatic network traffic.
- [ ] Exercise backup preview and round-trip restore with queue content/images/read
state. Check pre-queue restore and staged-save exclusion. Review VoiceOver names,
focus, and motion policies. Run full local tests if failures or persistence scope
justify it; otherwise keep the relevant verified focused suite plus required CI.
- [ ] Run `git diff --check`, commit only task files, push codex/offline-reading-queue,
and create PR with a clear behavior/limitations/validation description using a
temporary --body-file. Attach it through mcp__codex_app__attach_artifact.
- [ ] Use the review subagent authorized by AGENTS.md to inspect the PR's current
diff independently, especially privacy, same-URL races, image bounds, arbitrary
path rejection, stale window actions, atomic failures, and restore rollback.
Resolve actionable findings, rerun affected tests, push fixes, and obtain review
of the latest head. Do not count an earlier-head review as final approval.
- [ ] Confirm required checks, required approvals, mergeability, and reviewed head
with gh PR status/view. Squash-merge without another confirmation, as authorized
by AGENTS.md. Verify merged state and squash commit. A pending/failed/unavailable
required check or review is a blocker to report, never a pass.
- [ ] Quit each tracked Vane test instance. If quit confirmation blocks exit, target
only its revalidated PID/executable/start time with TERM, then KILL only if needed;
verify exit. Preserve the user's regular app and other tasks' instances. Sync local
main only if existing local work is safe. Report PR, squash commit, actual validation,
and remaining extraction/image/backup-size limitations.

## Plan self-review

- Schema/codec covers metadata, source preservation, read state, text search,
  sanitization, resource integrity, and limits (Task 1).
- Repository covers atomicity, damage retention, private/profile isolation,
  invalidation, cleanup, and disk usage (Task 2).
- Capture covers Reader reuse, navigation identity, image practicality and bounded
  networking, errors, duplicate saves, and private zero-write enforcement (Task 3).
- Saved Reader covers source distinction, public APIs, network isolation,
  preference reuse, and lifecycle (Task 4).
- Library covers explicit save/read/remove workflows, focus/accessibility,
  asynchronous saved-text search, status/filter/list motion, and docs (Task 5).
- Backup task covers owned names, immutable capture, preview, install/removal,
  staging exclusion, raw rollback, and old backups (Task 6).
- Delivery covers live fixtures, focused validation, current-head independent
  review, CI, squash-merge, and tracked instance cleanup (Task 7).
