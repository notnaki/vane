import Foundation

/// A site's Boost belongs to a profile, even though the Library lists every profile.
@MainActor enum BoostsLibrary {
    struct Entry: Identifiable, Equatable {
        struct ID: Hashable { let profile: UUID; let origin: String }
        let profileID: UUID
        let profileName: String
        let origin: String
        let boost: SiteBoost
        var id: ID { ID(profile: profileID, origin: origin) }
    }

    static func entries(profiles: [Profile], query: String = "") -> [Entry] {
        profiles.filter { $0.id != Profile.incognito.id }.flatMap { profile in
            SiteBoosts.records(profile: profile.id).compactMap { origin, boost in
                guard Library.matches([origin, profile.name], query) else { return nil as Entry? }
                return Entry(profileID: profile.id, profileName: profile.name, origin: origin, boost: boost)
            }
        }.sorted {
            if $0.origin != $1.origin { return $0.origin < $1.origin }
            if $0.profileName != $1.profileName { return $0.profileName < $1.profileName }
            return $0.profileID.uuidString < $1.profileID.uuidString
        }
    }
}
