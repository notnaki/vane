import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

func payload(_ tag: String, prerelease: Bool = false, draft: Bool = false) -> [String: Any] {
    ["tag_name": tag, "prerelease": prerelease, "draft": draft,
     "assets": [["name": "Vane.zip", "url": "https://api.github.com/repos/notnaki/vane/releases/assets/123",
                 "browser_download_url": "https://github.com/notnaki/vane/releases/download/\(tag)/Vane.zip"]]]
}

func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }

expect(UpdateChannel.stored(nil) == .stable, "Fresh installs must stay on Stable")
expect(UpdateChannel.stored("unknown") == .stable, "Unknown settings must fail closed")
expect(UpdateChannel.stored("nightly") == .nightly, "Nightly opt-in must persist")
for key in ["etag", "lastModified", "tag", "asset"] {
    expect(UpdateChannel.stable.cacheKey(key) != UpdateChannel.nightly.cacheKey(key), "Channel caches must not overlap")
}
expect(UpdateChannel.stable.apiPath.hasSuffix("/latest"), "Stable uses the stable-only endpoint")
expect(UpdateChannel.nightly.apiPath == "releases?per_page=100", "Nightly must inspect prereleases")

let stable = try UpdateChannel.stable.release(from: data(payload("v1.2.3")))
expect(stable?.tag == "v1.2.3", "Stable release must be accepted")
expect(stable?.assets.first?.name == "Vane.zip", "Assets must survive decoding")
expect(stable?.assets.first?.url == "https://api.github.com/repos/notnaki/vane/releases/assets/123",
       "Downloads must use the asset API even when the browser download route is unavailable")
expect(stable?.assets.first?.browserURL == "https://github.com/notnaki/vane/releases/download/v1.2.3/Vane.zip",
       "Keep the browser route as a fallback when the API route fails")
for candidate in [payload("v1.2.4-nightly.20261031.1", prerelease: true),
                  payload("v1.2.4-nightly.20261031.1"), payload("v1.2.4", draft: true), payload("garbage")] {
    let selected = try UpdateChannel.stable.release(from: data(candidate))
    expect(selected == nil, "Stable must reject drafts, prereleases and malformed tags")
}
let mixed = [payload("v1.2.3"), payload("v1.2.4-nightly.20261031.9", prerelease: true),
             payload("v1.2.4-nightly.20261031.10", prerelease: true),
             payload("v9.0.0-rc.1", prerelease: true), payload("v9.0.0", draft: true),
             payload("garbage"), payload("v9.0.0-nightly", prerelease: true)]
let nightly = try UpdateChannel.nightly.release(from: data(mixed))
expect(nightly?.tag == "v1.2.4-nightly.20261031.10", "Choose newest valid nightly numerically, excluding RC/drafts")
expect(nightly?.assets.first?.url == "https://api.github.com/repos/notnaki/vane/releases/assets/123",
       "Nightly downloads must also use the asset API")
let promoted = try UpdateChannel.nightly.release(from: data(mixed + [payload("v1.2.4")]))
expect(promoted?.tag == "v1.2.4", "Stable must outrank its preceding nightlies")
let next = try UpdateChannel.nightly.release(from: data(mixed + [payload("v1.2.4"), payload("v1.2.5-nightly.20261101.11", prerelease: true)]))
expect(next?.tag == "v1.2.5-nightly.20261101.11", "A new nightly must upgrade the current stable")
let compact = try UpdateChannel.nightly.release(from: data([
    payload("v1.2.4-nightly.20261031.41351878095", prerelease: true),
    payload("v1.2.4-nightly.20261101.1", prerelease: true)]))
expect(compact?.tag == "v1.2.4-nightly.20261101.1", "Compact next-day nightly must upgrade legacy run-ID versions")
let empty = try UpdateChannel.nightly.release(from: data([]))
expect(empty == nil, "No nightlies is an empty successful check")
for malformed in [Data("invalid".utf8), try data(["message": "API error"])] {
    do {
        _ = try UpdateChannel.nightly.release(from: malformed)
        fatalError("Malformed replies must fail before conditional headers are cached")
    } catch {}
}
print("PASS: channel defaults, cache isolation, release filtering and version ordering")
