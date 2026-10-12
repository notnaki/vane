import Foundation

struct FavouritePreviewExtraction: Codable, Sendable {
    struct Row: Codable, Sendable {
        var title: String
        var subtitle: String
        var url: String
        var unread: Bool = false
        var status: String? = nil
        var start: String? = nil
        var meeting: String? = nil
    }
    var state: String
    var account: String
    var items: [Row]
}

/// Implementations return only display fields and website navigation URLs, never credentials.
protocol FavouritePreviewAdapter: Sendable {
    var service: FavouritePreviewService { get }
    var script: String { get }
    var identityScript: String { get }
    func parse(_ extraction: FavouritePreviewExtraction) -> FavouritePreviewResult
}

struct DOMFavouritePreviewAdapter: FavouritePreviewAdapter {
    let service: FavouritePreviewService

    func parse(_ extraction: FavouritePreviewExtraction) -> FavouritePreviewResult {
        if extraction.state == "signedOut" { return .signedOut }
        let account = extraction.account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty, account.count <= 254, extraction.items.count <= 5,
              extraction.state == "ready" || extraction.state == "empty" else { return .unavailable }
        guard extraction.state == "empty" ? extraction.items.isEmpty : !extraction.items.isEmpty else { return .unavailable }
        var items: [FavouritePreviewItem] = []
        for row in extraction.items {
            guard !row.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  row.title.count <= 500, row.subtitle.count <= 300,
                  let url = FavouritePreviewURL.item(row.url, service: service) else { return .unavailable }
            var item = FavouritePreviewItem(title: row.title, subtitle: row.subtitle, url: url, unread: row.unread)
            if service == .github { item.status = row.status.map { String($0.prefix(160)) } }
            if service == .calendar {
                guard let start = row.start, let date = ISO8601DateFormatter().date(from: start) else { return .unavailable }
                item.startsAt = date
                if let raw = row.meeting { item.meetingURL = FavouritePreviewURL.meeting(raw) }
            }
            if !items.contains(where: { $0.id == item.id }) { items.append(item) }
        }
        return .ready(FavouritePreviewSnapshot(account: account, items: items))
    }

    private var identityBody: String {
        switch service {
        case .github:
            return #"const account = document.querySelector('meta[name="user-login"]')?.content?.trim() || '';"#
        case .gmail, .calendar:
            return #"""
            // Only the account-switcher affordance. Do not search message/event content for emails.
            const accountHeader = document.querySelector('header, [role="banner"], #gb');
            const accountButton = accountHeader?.querySelector('a[href*="accounts.google.com/SignOutOptions"], button[aria-label^="Google Account:"], a[aria-label^="Google Account:"]');
            const accountLabel = accountButton?.getAttribute('aria-label') || '';
            const account = accountLabel.match(/[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i)?.[0]?.toLowerCase() || '';
            """#
        }
    }
    var identityScript: String { "(() => { \(identityBody) return account; })()" }

    var script: String {
        """
        (() => {
        const unknown = () => ({state:'unknown', account:'', items:[]});
        \(identityBody)
        if (!account) {
          if (document.querySelector('input[type="password"], form[action="/session"], input[type="email"]'))
            return {state:'signedOut',account:'',items:[]};
          return unknown();
        }
        const text = el => (el?.textContent || '').trim().replace(/\\s+/g,' ');
        const result = (state, items=[]) => ({state,account,items});
        const visible = el => el.getClientRects().length > 0 && getComputedStyle(el).visibility !== 'hidden';
        \(extractionBody)
        })()
        """
    }

    private var extractionBody: String {
        switch service {
        case .github:
            return #"""
            // /pulls with an explicit open/involves query; no private API calls or application state.
            const query = new URL(location.href).searchParams.get('q') || '';
            if (location.pathname !== '/pulls' || !query.includes('involves:@me') || !query.includes('is:open')) return unknown();
            const rows = Array.from(document.querySelectorAll('.js-issue-row')).filter(visible).slice(0,5);
            if (!rows.length) {
              const empty = Array.from(document.querySelectorAll('.blankslate, [data-testid="results-empty-state"]'))
                .some(el => /no (results|pull requests)|nothing matched/i.test(text(el)));
              return empty ? result('empty') : unknown();
            }
            const items = rows.map(row => {
              const link = row.querySelector('a.Link--primary[href*="/pull/"], a[data-hovercard-type="pull_request"][href*="/pull/"]');
              const url = link ? new URL(link.getAttribute('href'), location.href) : null;
              const labels = Array.from(row.querySelectorAll('[aria-label], [title]'))
                .map(el => el.getAttribute('aria-label') || el.getAttribute('title') || '')
                .filter(label => /review|checks? (passed|failed|pending)|\d+\/\d+ checks|approved|changes requested/i.test(label));
              return {title:text(link), subtitle:url ? url.pathname.split('/').slice(1,3).join('/') : '',
                url:url?.href || '', unread:false, status:labels.slice(0,2).join(' · ') || null};
            });
            return result('ready',items);
            """#
        case .gmail:
            return #"""
            if (!location.pathname.startsWith('/mail/') || !location.hash.startsWith('#inbox')) return unknown();
            const main = document.querySelector('[role="main"]');
            if (!main) return unknown();
            const rows = Array.from(main.querySelectorAll('tr.zA')).filter(visible).slice(0,5);
            if (!rows.length) {
              const empty = Array.from(main.querySelectorAll('td, [role="status"]'))
                .some(el => /^(Your inbox is empty\.?|No new mail!?|No conversations in Inbox\.?)$/i.test(text(el)));
              return empty ? result('empty') : unknown();
            }
            const items = rows.map(row => {
              const sender = row.querySelector('.yW [email]');
              const subject = row.querySelector('.bog');
              const actual = row.querySelector('a[href*="#inbox/"]');
              const id = (row.querySelector('[data-legacy-thread-id]') || row).getAttribute('data-legacy-thread-id');
              let url = actual ? new URL(actual.getAttribute('href'),location.href).href : '';
              if (!url && id && /^[a-f0-9]+$/i.test(id)) {
                const target = new URL(location.href); target.hash = 'inbox/' + id; url = target.href;
              }
              return {title:text(subject), subtitle:sender?.getAttribute('name') || text(sender) || sender?.getAttribute('email') || '',
                url, unread:row.classList.contains('zE')};
            });
            return result('ready',items);
            """#
        case .calendar:
            return #"""
            // Accept only explicit event links paired with machine-readable times. Unknown
            // versions of Calendar's virtualized schedule deliberately fall back.
            if (!location.pathname.includes('/r/agenda')) return unknown();
            const main = document.querySelector('[role="main"]');
            if (!main) return unknown();
            const links = Array.from(main.querySelectorAll('a[href*="eid="], a[href*="/eventedit/"]'));
            const items = [];
            for (const link of links) {
              const row = link.closest('[data-eventid], [role="row"], article');
              const time = row?.querySelector('time[datetime]');
              const start = time?.getAttribute('datetime');
              if (!start || !Number.isFinite(Date.parse(start))) return unknown();
              if (Date.parse(start) < Date.now()) continue;
              const meeting = Array.from(row.querySelectorAll('a[href]')).find(a => {
                try { const h = new URL(a.href).hostname; return h === 'meet.google.com' || h === 'teams.microsoft.com' || h.endsWith('.zoom.us') || h.endsWith('.webex.com'); } catch { return false; }
              });
              items.push({title:text(link), subtitle:'', url:new URL(link.getAttribute('href'),location.href).href,
                unread:false, start:new Date(start).toISOString().replace(/\.\d{3}Z$/,'Z'), meeting:meeting?.href || null});
            }
            items.sort((a,b) => Date.parse(a.start) - Date.parse(b.start));
            if (items.length) return result('ready',items.slice(0,5));
            // A short virtualized window is not proof that the upcoming calendar is empty.
            return unknown();
            """#
        }
    }
}
