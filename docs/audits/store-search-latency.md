# Store and search latency investigation

## Method

Measured release XCTest fixtures on a MacBookPro18,4 (10 logical CPUs, 32 GB),
macOS 27.0.1. All data lives in temporary `VANE_DATA_DIR` profiles; no browsing
data is copied from a real profile. A shared filesystem lock excludes competing
builds and profiling runs during accepted measurements. An earlier overlapping
run was discarded. The user's normal applications remain running.

Build the exact revision with `-Xswiftc -enable-testing`, then run:

```sh
VANE_STORE_PERFORMANCE=1 VANE_UI_PERFORMANCE=1 /usr/bin/time -lp \
  swift test --skip-build -c release \
  --filter 'StoreLatencyBenchmarks|HistoryResponsivenessTests'
```

The same fixture measures 10,000 and 240,000 visits (ten visits per URL), 1,000
and 24,000 stored bookmarks, 1,000 and 10,000 displayed bookmarks, the 2,000-entry
Library archive, and 1,000-tab recovery snapshots with 800 bytes of opaque state
per tab. Queries have three repetitions. Presentation measures synchronous open
and the largest overshoot of a 2 ms main-actor heartbeat over one second. Filtering
uses the native search field editor. These diagnostic measurements add no timing
limits to routine CI. The existing opt-in History benchmark retains its 100 ms
budget unchanged.

## Demonstrated causes and changes

The bookmark manager eagerly built every row inside a settings card. At 10,000
bookmarks, SQL returned rows in about 15 ms while opening blocked the input actor
for 22.4 seconds and filtering for 5.8 seconds. A lazy stack now materializes
visible rows, keeping the scroll view and search field mounted even with no results.
Arrow-key selection scrolls into view using the existing motion policy, including
Reduce Motion and Battery Saver.

Bookmark queries previously ran synchronously on the input actor. A dedicated
read-only SQLite actor now serves the manager, with the existing 75 ms search
debounce, SQLite progress-handler cancellation, and a request identity check before
publishing results. The shared SQL implementation preserves literal LIKE escaping,
folder rules, unrestricted result counts, and descending date order. Each profile
has its own reader. In-memory private bookmarks retain their original connection.

One hundred repeated notifications of an unchanged page title caused 100 SQLite
row updates and 100 History refresh notifications. The newest visit is now updated
only when its title differs. A trigger-based regression checks zero redundant
updates/notifications and one real change, without elapsed-time assertions.

## Baseline and scope

Accepted baseline at `f24aa5fcd4de64fa9deac6efc2a81a7eaabc232f`:

| Fixture | Baseline |
| --- | ---: |
| 1,000 bookmarks, open / largest input delay | 40.0 / 1,943.3 ms |
| 1,000 bookmarks, filter input delay | 345.8 ms |
| 10,000 bookmarks, open / largest input delay | 22,425.5 / 22,425.5 ms |
| 10,000 bookmarks, filter input delay | 5,786.8 ms |
| 10,000 History, warm open / heartbeat overshoot | 25.5 / 21.1 ms |
| Whole benchmark peak RSS | 6,064,898,048 bytes |

History browse queries returned in 0.35–0.52 ms. Broad matching took 39.6–39.8 ms
at 10,000 visits and 978–989 ms at 240,000; address suggestions took 56.6–57.3 ms
and 1,489–1,655 ms respectively. These existing scans run off the input actor.
After cancellation was requested 10 ms into a broad History scan, draining took
0.085–0.115 ms and returned no rows. No ranking or candidate cap is changed.

Four Library archive filter/group operations took 73.3–75.6 ms total. One hundred
changing 1,000-tab recovery snapshots, including encoding and validity checking,
took 3,926.5 ms total; identical snapshot writes took 3,437.1 ms. These are primitive
write measurements, not a claim that Vane schedules 100 writes per typing burst.
The existing 30-second recovery throttle, 150 ms History title debounce, atomic writes and
durability rules remain unchanged.

## Validation

Focused release validation covers bookmark SQL parity, folders, literal wildcard
characters, limits, live edits, cancellation, saved-profile isolation, populated
private-session stores, History persistence/search and address search ranking/typing.
The redundant-title regression failed on the baseline with 100 updates and 100
notifications, then passed with the conditional update.

## Remaining coverage

Broad stress searches still scan and rank many candidates. Large in-memory private
bookmark queries still use their original main-actor connection. Desktop rendering
measurements depend on macOS, hardware and current regular applications; they are
comparisons on this machine, not universal latency guarantees. Accessibility and
field-focus smoke checks complement existing keyboard checks; a complete VoiceOver
session is outside these automated fixtures.
