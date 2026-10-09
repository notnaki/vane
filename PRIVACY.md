# Vane Privacy Policy

Effective and last updated: **9 October 2026**

This policy covers the Vane macOS browser and its [project website](https://notnaki.github.io/vane/), maintained by [notnaki](https://github.com/notnaki). It describes the current implementation in this repository. Older releases and third-party builds may behave differently.

Vane stores your browser library on your Mac. It has no Vane account, hosted browsing-history service, or built-in sync between Macs. Vane does not include app analytics or automatic crash-report uploads. Browsing and the features below still make network requests; local storage does not mean that nothing leaves your device.

## Data stored on your Mac

Vane keeps history (including URLs, titles, and visit times), bookmarks, tabs, Spaces, settings, download records, saved articles and images, Easels, and recovery copies locally. WebKit manages cookies, website storage, caches, and website sign-ins. Regular profiles separate history, bookmarks, saved passwords, extensions, and website stores; download and media records are shared across regular profiles.

Saved passwords, AI API keys, and GitHub connection credentials use the local macOS Keychain. Vane does not enable Keychain synchronization for these items. Passwords are used to fill matching HTTPS sign-in forms; submitting a form sends its contents to that website. Vane does not upload your password library to a Vane service.

Browser imports read the local data you select and, where required, use Keychain access to import supported credentials. Library files and recovery copies are not encrypted by Vane. Folder locks limit access within the app; they do not encrypt browser data. Password CSV exports are plaintext, and `.vanebackup` exports are unencrypted. Protect these files and any device or system backups containing them.

## Browsing, searches, and website requests

Opening a page contacts that website and the services it loads. They can receive your IP address, request headers, URLs, cookies, submitted forms, and other information according to your actions and their own practices. An ordinary submitted search goes to the search engine you choose; Instant Links uses DuckDuckGo as described below. Installed extensions and enabled Boost scripts can access or transmit data according to their permissions and code.

- **Search suggestions:** off by default. If enabled, eligible partial searches typed in the address bar are sent to the selected supported suggestion provider: DuckDuckGo, Google, Bing, Brave, or Ecosia. Vane tries to exclude URL-like, email-like, and file-path input, but this filtering cannot identify every sensitive query. Suggestions are disabled in private windows.
- **Instant Links:** enabled by default and invoked with **Shift+Return** in the address or new-tab bar. Eligible searches are sent to DuckDuckGo’s HTML search endpoint to find the first organic result, regardless of your selected search engine. Each comma-separated query is sent separately. Resolution uses a separate ephemeral session with no cookies or disk cache; DuckDuckGo still receives the query and connection information such as your IP address. If resolution fails, times out, or encounters a challenge, Vane opens DuckDuckGo’s results page in the browsing tab, using the window’s website store and applicable cookies. Explicit addresses, bangs, and active site searches keep their ordinary destinations. Instant Links does not send queries while you type and does not resolve in private windows or when disabled; those cases use ordinary navigation with your selected engine. Turn it off in **Settings → Max → Instant Links**. Older builds may use the selected engine for first-result navigation; source changes do not update installed apps.
- **Website icons:** Vane fetches page-declared icons and site favicons, including for some restored or parked tabs. Icon URLs can belong to third parties. Requests can also occur in private windows; private icons are not saved to Vane's disk icon cache.
- **Link previews:** on by default. Hovering an eligible link can load its destination and resources without clicking, using the window's website store and applicable cookies. This also works in private windows, using their temporary store. Turn it off in **Settings → General → Previews**.
- **Saved content:** saving an offline article can fetch its images. Enabling a live web preview in an Easel loads the source website using that profile's website store. These features are unavailable in private windows.

Network recipients may keep their own logs. Vane cannot delete information already received by a website or other service.

## AI features

**Apple's on-device model is the default provider.** Page summaries use that on-device model. Cloud naming and grouping are optional and require choosing Groq, OpenAI, OpenRouter, or a custom HTTPS API, then supplying your own key. Requests go directly to the chosen provider, without a Vane server in between.

Cloud requests include your API key, configured model, task instructions, and the metadata needed for the task:

- Pinned tab naming sends the page title and hostname. Tidy Titles is on by default and can request cloud naming automatically after you configure a cloud provider.
- Tab grouping sends tab titles and hostnames when you use Tidy Tabs.
- Download naming sends the suggested filename, page title, and source hostname and path. Tidy Downloads is off by default; enabling it can trigger requests as downloads complete. These naming requests do not upload downloaded file contents.

Source URL query strings and fragments are omitted from this metadata, but titles, filenames, and paths may still contain personal or confidential information. **Test Connection** also sends a request to the configured provider. Private windows do not use these cloud API features. Choose the Apple provider or remove your saved key to stop cloud API use; this cannot retract earlier requests.

**Assistant websites are separate.** An explicit Ask action or assistant-prefixed search can open ChatGPT, Claude, Perplexity, or Grok with your question in the URL. This sends your question to that service, including when invoked in a private window. Normal website sign-in and cookie behavior applies to the window's website store. Provider policies govern their processing, retention, and any use for model training; review those policies before sending sensitive information.

## Updates and optional connections

- **App updates:** automatic update checks are on by default. Vane contacts GitHub's release API at launch and periodically, and downloads release files from GitHub or its delivery infrastructure when you install an update. These requests include ordinary connection metadata and cache-validation headers, not your browsing history or saved passwords. Disable automatic checks in Settings if you prefer manual checks. Private browsing does not disable app update checks.
- **Filter subscriptions:** no remote subscriptions are configured by default. Adding an HTTPS list contacts its host; enabled subscriptions are fetched again when due. The host receives ordinary request metadata and cache-validation headers. Subscriptions are app-wide and may update while private windows are open. Remove a subscription to stop future fetches for it.
- **GitHub Live Folders:** connecting an account sends authentication requests to GitHub, followed by account and pull-request queries, including any repository filter you choose. OAuth uses the `repo` scope. Active folders refresh periodically. Disconnect in Vane to stop their authenticated requests, and revoke the authorization or token in GitHub to invalidate it there.

These services receive requests directly and apply their own privacy policies and retention rules. Any network request exposes connection information such as your IP address to its recipient.

## Private browsing

Private windows use temporary browsing identities and nonpersistent website stores. Vane does not restore their history, tabs, or download records after quitting, or use your saved profile passwords and extensions there. They disable search suggestions, Instant Links, and cloud AI naming/grouping.

Private browsing does not hide your IP address or activity from websites, services you contact, or your network. Assistant websites, website icons, link previews, and app-wide updates or filter fetches can still make requests as described above. Downloaded files and captures you explicitly save remain on disk.

## Retention and your controls

Regular browsing data stays locally until you delete it or a feature replaces it; Vane does not apply one universal automatic expiry period. Local recovery points can retain earlier library contents after you clear current records. The backup system normally keeps the latest ten completed recovery points, with protection for the last healthy point during recovery. Preserved crash originals and manually exported files can remain separately.

Use **Clear Browsing Data** for history, cookies/site data, and caches, or **Website Data** for selected sites. Manage saved passwords in Settings, and delete saved articles, Easels, and other library items using their controls. **Erase Everything** attempts to remove Vane's local library, recovery points, preferences, website data, saved passwords, and GitHub connection credentials. Inaccessible files or older data folders may remain if deletion fails.

AI API keys must be removed separately. **Before erasing**, select each provider and saved custom endpoint in **Settings → Max** and use **Remove Key** for each. That control only deletes the selected key. Erasure clears endpoint preferences but leaves these Keychain items; afterward, you may need the old endpoint details or macOS Keychain Access to find remaining keys. Erasing Vane does not remove downloaded files, exports, system backups, or copies held by other services. Deletion is not a guarantee of forensic erasure. See the [data guide](https://github.com/notnaki/vane/blob/main/docs/DATA-AND-PRIVACY.md) for exports, backup exclusions, and recovery behavior.

## Website, diagnostics, and public support

The project website uses same-site assets and has no added analytics, advertising trackers, or tracking cookies. It is hosted on GitHub Pages. GitHub receives visitor requests and handles hosting and GitHub account information under its [privacy statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement). Following external links contacts the destination service.

Vane keeps local recovery information and can write diagnostic messages to macOS logs. macOS may separately collect or share system diagnostics according to your Apple settings. Diagnostics or screenshots you choose to share can contain sensitive information; review them first.

## Security, changes, and contact

**Vane has not published an independent third-party security audit.** Open source, code review, automated tests, and release signing/notarization do not establish that an audit has taken place or guarantee that the app has no vulnerabilities.

Policy changes will be published here with an updated date; repository history records revisions. For privacy questions or to request help managing your data, contact the maintainer through the [GitHub issue tracker](https://github.com/notnaki/vane/issues). Issues are public: do not include passwords, API keys, tokens, or private browsing details. If a question requires sensitive information, ask for a private contact method before sharing it.
