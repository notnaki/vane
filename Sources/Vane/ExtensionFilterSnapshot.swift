import Foundation

/// Runs only in the accepted MV2 extension's own background world. Cache decoding
/// belongs to that extension: no assumptions about WebKit's on-disk databases.
enum ExtensionFilterSnapshot {
    struct Value: Decodable, Sendable {
        let digest: String
        var unchanged: Bool = false
        var texts: [String] = []
        var trustedSites: [String] = []

        enum CodingKeys: CodingKey { case digest, unchanged, texts, trustedSites }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            digest = try values.decode(String.self, forKey: .digest)
            unchanged = try values.decodeIfPresent(Bool.self, forKey: .unchanged) ?? false
            texts = try values.decodeIfPresent([String].self, forKey: .texts) ?? []
            trustedSites = try values.decodeIfPresent([String].self, forKey: .trustedSites) ?? []
            guard digest.count == 64, digest.allSatisfy(\.isHexDigit), texts.count <= 256,
                  trustedSites.count <= 10_000 else { throw ExtensionFilterRules.Failure("The extension returned an invalid filter snapshot.") }
        }
    }

    static let script = #"""
        const ub = self.µBlock;
        if (!ub || ub.readyToFilter !== true) throw new Error('uBlock is not ready to supply its filters');
        const api = self.browser ?? self.chrome;
        const storage = await api.storage.local.get(['selectedFilterLists', 'user-filters', 'netWhitelist', 'data.whitelist']);
        const localURL = path => {
            if (typeof path !== 'string' || /^[a-z][\w+.-]*:/i.test(path) || path.startsWith('//') || path.split('/').includes('..')) return null;
            const root = new URL(api.runtime.getURL('/'));
            const url = new URL(path, root);
            return url.protocol === root.protocol && url.host === root.host ? url.href : null;
        };
        const readLocal = async path => {
            const url = localURL(path);
            if (!url) throw new Error('Filter asset is not a package-local resource');
            const response = await fetch(url);
            if (!response.ok) throw new Error('A packaged filter asset is unavailable');
            const text = await response.text();
            if (text.length > 8*1024*1024) throw new Error('A filter asset exceeds the bridge limit');
            return text;
        };
        const assets = JSON.parse(await readLocal('assets/assets.json'));
        const selected = Object.hasOwn(storage, 'selectedFilterLists') ? storage.selectedFilterLists
            : Array.isArray(ub.selectedFilterLists) ? ub.selectedFilterLists
            : Object.keys(assets).filter(key => assets[key].content === 'filters' && !assets[key].off);
        if (!Array.isArray(selected) || selected.length > 256 || selected.some(key => typeof key !== 'string' || key.length > 4096))
            throw new Error('Invalid selected filter lists');
        const keys = [...new Set(selected)];
        let cache = self.vAPI?.cacheStorage;
        if (!cache || typeof cache.get !== 'function') {
            try { cache = (await import(api.runtime.getURL('js/cachestorage.js'))).default; } catch { cache = null; }
        }
        const cached = cache ? await cache.get(keys.filter(key => key !== 'user-filters').map(key => 'cache/' + key)) : {};
        const texts = [];
        let bytes = 0;
        for (const key of keys) {
            let text;
            if (key === 'user-filters') {
                text = storage['user-filters'] ?? '';
            } else if (typeof cached?.['cache/' + key] === 'string') {
                text = cached['cache/' + key];
            } else {
                const source = assets[key]?.contentURL;
                const paths = (Array.isArray(source) ? source : [source]).filter(path => localURL(path));
                for (const path of paths) {
                    try { text = await readLocal(path); break; } catch {}
                }
            }
            if (typeof text !== 'string') throw new Error('A selected filter list is not cached or packaged');
            bytes += new TextEncoder().encode(text).length;
            if (bytes > 32*1024*1024) throw new Error('Selected filter lists exceed the 32 MB bridge limit');
            texts.push(text);
        }
        let trustedSites = storage.netWhitelist ?? storage['data.whitelist'];
        if (trustedSites === undefined) {
            if (typeof ub.trustedSites?.toLines === 'function') trustedSites = ub.trustedSites.toLines();
            else if (ub.netWhitelist instanceof Map) trustedSites = [...ub.netWhitelist.values()].flat();
            else trustedSites = [];
        }
        if (typeof trustedSites === 'string') trustedSites = trustedSites.split('\n');
        if (!Array.isArray(trustedSites) || trustedSites.length > 10000 || trustedSites.some(x => typeof x !== 'string' || x.length > 4096))
            throw new Error('Invalid trusted-site directives');
        const data = JSON.stringify({texts, trustedSites});
        const digest = [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(data)))].map(x => x.toString(16).padStart(2,'0')).join('');
        return digest === lastDigest ? JSON.stringify({digest, unchanged:true}) : JSON.stringify({digest, texts, trustedSites});
        """#
}
