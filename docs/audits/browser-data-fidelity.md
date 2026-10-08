# Browser data fidelity audit

Work starts from `dee7b89` on macOS 27.0.1 (26A434), in an isolated
`codex/browser-data-fidelity` worktree. All fixtures are synthetic.

## Execution plan

1. Inventory HTML bookmarks, browser profile databases/JSON/plists, password CSV,
   and HTML/CSV/JSON/password exports; retain Arc security regressions.
2. Reproduce HTML whitespace/multiline/entity loss, malformed CSV acceptance,
   browser history visit loss, and cross-category partial destination writes.
3. Fix parser and transaction boundaries with focused regression tests. Define
   duplicate and normalization semantics; accurately describe unsupported fields.
4. Exercise large fixtures, invalid and unreadable sources, destination write/read
   failures, profile isolation, and origin/security regressions. Coordinate builds
   and native checks with the smoothness chat.
5. Validate, push a PR, independently review its current commit, fix findings,
   wait for required CI, squash-merge, and remove task-owned temporary resources.

Review focus: malformed input following valid records; failures after writes have
started; repeated imports with existing data; multiline and Unicode fields;
credential enumeration/read failures and secret-free diagnostics.

## Supported formats and normalization

| Path | Retained fields | Normalization and limits |
| --- | --- | --- |
| Bookmark HTML import/export | URL, title, Unix `ADD_DATE`, populated folder name | UTF-8 Netscape HTML; case-insensitive tags, whitespace between DT/A, quoted/unquoted attributes, numeric/common XML entities and multiline text. Nested paths become one folder named `Parent / Child`. Export writes that single folder, not the original hierarchy. Folder edges are trimmed; names match case-insensitively. Empty folders, descriptions, icons, toolbar flags, modified/visited dates and separators are unsupported. |
| Chromium profile History | URL, current URL title, each visit's timestamp | Uses `visits` joined to `urls`; a legacy/minimal database without `visits` falls back to `urls.last_visit_time`, retaining only the latest visit there. Source epoch is microseconds since 1601. Chromium stores no per-visit title in this query. |
| Firefox places.sqlite | URL, current page title, each visit's timestamp | Uses `moz_historyvisits` joined to `moz_places`; a database without the visit table falls back to last-visit dates. Source epoch is Unix microseconds. Null titles become empty strings. |
| Safari History.db | URL, each visit's title and timestamp | Source timestamps are seconds since 2001. Every visit is retained. |
| Native Chromium JSON / Safari plist / Firefox SQLite bookmarks | URL and title | Nested leaves are found but native folder structure and creation timestamps are currently unsupported on this path. Use bookmark HTML to retain readable folder paths and dates. Native bookmark imports receive import-time dates. |
| Password CSV import/export | Web origin (scheme, host, port), username, password | UTF-8 (optional BOM), RFC 4180 quoting with CRLF/LF records. Supports URL/Website URL/login_uri/Web Site/hostname, username/User Name/login_username/login/email, password/login_password headers. Host case and default ports normalize through PasswordOrigin; URL paths/query/fragments are origin metadata and are not retained. Bare hosts use HTTPS. Usernames and nonempty passwords retain whitespace, Unicode, quotes and embedded line breaks. Userinfo URLs, non-HTTP(S), invalid ports, missing websites and empty passwords are skipped. Names, notes, OTPs, form actions, realms, CSV timestamps and password-manager attachments are unsupported. An empty saved password can be exported but is deliberately skipped on CSV reimport. |
| History CSV / JSON export | URL, title, full fractional Unix epoch, human-readable visited_at | One row per stored visit; epoch preserves subsecond precision, visited_at is whole-second ISO 8601. CSV/JSON history files are exports, not user-facing history import formats. parseHistoryCSV is a regression/check helper for Vane's four-column export, not a generic importer. |
| Easel JSON / PNG and complete .vanebackup | Separate documented formats | Existing synthetic board and backup suites cover these codecs, storage failures and restore isolation. PNG is a rendered image, not editable board data. Backups exclude credentials and cookies; see README's Backup and Restore section. |

Only HTTP(S) bookmarks/history are stored. Foundation URL serialization percent-encodes
Unicode and other URL characters where needed; query strings, fragments and path distinctions
are retained. Bookmark titles remain unchanged. Missing/invalid HTML ADD_DATE receives an
import-time date; HTML exports truncate stored dates to whole Unix seconds. Native history
transition types, redirects, visit IDs, source browser visit counters and download records
are unsupported.

## Duplicate and failure behavior

* Bookmarks are unique by the complete serialized URL within a Vane profile. The first
  occurrence in file order wins; later occurrences and existing bookmarks never replace
  the title, date or folder. Duplicate URLs in different folders cannot both be retained.
* Browser history imports identify a visit by complete URL and exact converted timestamp.
  Repeated imports and duplicate source visits add nothing; existing titles are kept. Visits
  at different times remain distinct. Ordinary browsing continues recording each navigation.
* Password identity is full web origin plus exact username, scoped to a Vane profile and
  test-instance namespace. Existing credentials are preserved. In a CSV the first successful
  save wins; a failed save permits a later duplicate to retry. Imported/skipped/failed counts
  describe those outcomes. The CLI exits nonzero if any save fails.
* CSV syntax is validated in full before saving. Truncated HTML anchors/folder blocks and
  invalid JSON/plist/database reads fail before destination changes. Invalid individual
  password rows are explicitly counted as skipped; non-web bookmark/history rows are omitted
  under the format's HTTP(S) policy. Empty bookmark files fail as having no usable entries.
* A browser import commits history and bookmarks together. A failure in either category,
  including a failed commit, rolls back the destination and leaves existing data unchanged.
  Safari no longer silently imports just one category when the other selected source fails.
* Keychain has no multi-item transaction. A valid password CSV can save new entries before
  another save fails; the UI reports saved/failed counts and the CLI exits 1. This is an
  explicitly reported partial import, and existing credentials remain unchanged. Retry is
  safe. Arc's existing independent-category reporting and credential/cookie protections remain.
* Database exports wait for complete checked SQLite snapshots. Password exports enumerate
  fresh owned persistent references and require every secret read to succeed; access errors
  do not become empty/partial files. Export text is prepared before atomic file publication,
  so a read error leaves an existing destination file untouched. Write failures are surfaced.
* Parser diagnostics contain no CSV header or field values. Credentials never enter logs.
  Password export keeps the typed EXPORT confirmation and Cancel default. Profile selection,
  Arc confirmation, credential ownership/origin rules and cookie protection remain intact.

## Validation evidence

The pre-fix fixture run reproduced multiline/attribute HTML loss, BOM rejection, malformed
CSV reaching save callbacks, truncated bookmark prefix imports, source JSON failures being
swallowed, latest-only history loss, repeated history imports, and cross-category partial
writes. After fixes, 50 focused tests passed (one opt-in real Keychain integration test was
skipped) on macOS 27.0.1. Fixtures include 2,500 HTML bookmarks and 10,000 database visits,
SQLite abort triggers, missing/invalid sources and output preservation. Additional validation
and final review evidence will be recorded after the coordinated profiling window.
