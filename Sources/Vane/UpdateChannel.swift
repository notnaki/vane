import Foundation

/// One app and installer, with an explicit opt-in to early builds.
enum UpdateChannel: String, CaseIterable {
    case stable, nightly

    static let preferenceKey = "updateChannel"

    static func stored(_ value: String?) -> UpdateChannel {
        value.flatMap(Self.init(rawValue:)) ?? .stable
    }

    var title: String { self == .stable ? "Stable" : "Nightly" }
    var explanation: String {
        switch self {
        case .stable: "Recommended releases. Returning from Nightly waits for a newer stable version."
        case .nightly: "Try the latest changes before release. Nightly builds may have bugs."
        }
    }
    var apiPath: String {
        self == .stable ? "releases/latest" : "releases?per_page=100"
    }
    func cacheKey(_ field: String) -> String { "update.\(rawValue).\(field)" }

    func release(from data: Data) throws -> UpdateRelease? {
        let decoder = JSONDecoder()
        let releases = try self == .stable
            ? [decoder.decode(UpdateRelease.self, from: data)]
            : decoder.decode([UpdateRelease].self, from: data)
        return releases.filter { release in
            guard !release.draft, let version = UpdateVersion(release.tag) else { return false }
            if version.pre.isEmpty { return !release.prerelease }
            // Only the automated nightly namespace opts in. Betas and release candidates
            // may exist on GitHub but are not either update channel.
            return self == .nightly && release.prerelease && version.pre.count == 3
                && version.pre[0] == "nightly"
                && version.pre.dropFirst().allSatisfy { Int($0).map { $0 > 0 } ?? false }
        }.max { UpdateVersion($0.tag)! < UpdateVersion($1.tag)! }
    }
}

struct UpdateRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let url: String
        enum CodingKeys: String, CodingKey {
            case name
            case url = "browser_download_url"
        }
    }
    let tag: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    enum CodingKeys: String, CodingKey {
        case tag = "tag_name"
        case draft, prerelease, assets
    }
}
