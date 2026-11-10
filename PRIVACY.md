# Vane Privacy Policy

Effective and last updated: **10 November 2026**

This policy covers the Vane macOS browser and its [project website](https://notnaki.github.io/vane/), maintained by [notnaki](https://github.com/notnaki). It describes the current implementation in this repository. Older releases and third-party builds may behave differently.

Vane stores your browser library on your Mac. It has no Vane account or Vane-hosted browsing-history service. Explicitly provisioned builds offer optional iCloud sync through Apple's services; sync starts off. Ordinary local builds keep sync unavailable. Vane does not include app analytics or automatic crash-report uploads. Browsing and the features below still make network requests; local storage does not mean that nothing leaves your device.

## Data stored on your Mac

Vane keeps history (including URLs, titles, and visit times), bookmarks, tabs, Spaces, settings, download records, saved articles and images, Easels, and recovery copies locally. WebKit manages cookies, website storage, caches, and website sign-ins. Regular profiles separate history, bookmarks, saved passwords, extensions, and website stores; download and media records are shared across regular profiles.

Saved passwords, AI API keys and ChatGPT tokens, and GitHub connection credentials use the local macOS Keychain. Passwords and AI keys have separate opt-in iCloud Keychain controls in provisioned builds; both start unselected. ChatGPT tokens, registrations and GitHub connection credentials stay local. Passwords are used to fill matching HTTPS sign-in forms; submitting a form sends its contents to that website. Vane does not upload your password library to a Vane service.

Browser imports scan known local browser locations when you open import or reach the onboarding import step, show the items found, and copy the selected source only after you confirm. Known browser locations have read-only sandbox access; macOS privacy controls still apply. Where required, importing supported credentials uses separate Keychain consent. Library files and recovery copies are not encrypted by Vane. Folder locks limit access within the app; they do not encrypt browser data. Password CSV exports are plaintext, and `.vanebackup` exports offer optional password encryption. Vane cannot recover backup passwords. Exports made without a password and automatic local recovery points remain unencrypted. Protect these files and any device or system backups containing them.

## Optional iCloud sync

Settings → iCloud lets you review each category before enabling sync on that Mac. Selected browser-library records and saved content use your Apple Account's private CloudKit database. Separate switches cover profiles, Spaces, favourites, pins, folders, bookmarks, history, device-labelled tab lists, Easels, reading content, templates, Boosts, preferences, site settings, content blocking, extensions, extension sync data and download history. History, extension sync data, passwords and API keys are unselected initially; Select All explicitly includes them. Download history includes page URLs, filenames, dates, sizes and the owning Mac, never downloaded file bytes, destination paths, file grants or resume data.

Private browsing, website cookies/sign-ins/storage, unsaved forms, macOS permissions, authentication proofs, GitHub tokens and ChatGPT registrations/tokens do not enter sync. API connection definitions and their feature routes can travel with portable preferences; ChatGPT connections and routes stay local. Synced Boost scripts and extension packages require this Mac's local execution approval. The separate extension sync-data switch transfers only values an extension puts in `storage.sync`, through public WebKit APIs. Extension `storage.local`, `storage.session`, opaque databases and local grants do not transfer. An extension can put sensitive values in its sync namespace; Vane cannot reliably identify their meaning. Incoming values wait for this Mac's approved extension activation. Writes already submitted to WebKit may finish after sync is turned off.

CloudKit records use encrypted fields and assets; this does not promise unconditional end-to-end encryption. Apple's Advanced Data Protection settings affect key availability. Password and API-key payloads use Apple's synchronizable Keychain separately, not CloudKit records or Vane servers. Turning these categories off stops Vane's sync admissions; it cannot stop Apple's transport for already-synchronizable Keychain items.

Disabling sync keeps existing local and cloud copies. Removing selected iCloud data is a separate confirmed action that preserves local copies and pauses devices when they observe its reset marker. Offline devices can take time to observe changes. Apple controls account availability, service retention and propagation. An Apple Account change pauses Vane sync until you deliberately approve merging the local library with the new account.

Distributed builds require matching provisioning and a production schema. Signed one-Mac development checks cover account access, encrypted data, assets, queries and local synchronizable Keychain operations. Cross-Mac convergence and Keychain propagation remain unverified. See [provisioning and validation requirements](docs/ICLOUD-PROVISIONING.md).

## Browsing, searches, and website requests

Opening a page contacts that website and the services it loads. They can receive your IP address, request headers, URLs, cookies, submitted forms, and other information according to your actions and their own practices. An ordinary submitted search goes to the search engine you choose; Instant Links uses DuckDuckGo as described below. Installed extensions and enabled Boost scripts can access or transmit data according to their permissions and code.

Installing a Chrome Web Store extension, checking it manually, or its daily automatic update check contacts Google's extension delivery services with the requested extension ID and protocol parameters. These downloads use ephemeral networking without your browser cookies, saved credentials or a Vane account. Vane verifies package signatures and reviews installation access; updates requesting added access wait for review. A valid store link on the clipboard can prefill the install dialog when you open it; Vane does not monitor the clipboard for extension links in the background.

- **Search suggestions:** off by default. If enabled, eligible partial searches typed in the address bar are sent to the selected supported suggestion provider: DuckDuckGo, Google, Bing, Brave, or Ecosia. Vane tries to exclude URL-like, email-like, and file-path input, but this filtering cannot identify every sensitive query. Suggestions are disabled in private windows.
- **Instant Links:** enabled by default and invoked with **Shift+Return** in the address or new-tab bar. Eligible searches are sent to DuckDuckGo’s HTML search endpoint to find the first organic result, regardless of your selected search engine. Each comma-separated query is sent separately. Resolution uses a separate ephemeral session with no cookies or disk cache; DuckDuckGo still receives the query and connection information such as your IP address. If resolution fails, times out, or encounters a challenge, Vane opens DuckDuckGo’s results page in the browsing tab, using the window’s website store and applicable cookies. Explicit addresses, bangs, and active site searches keep their ordinary destinations. Instant Links does not send queries while you type and does not resolve in private windows or when disabled; those cases use ordinary navigation with your selected engine. Turn it off in **Settings → Max → Instant Links**. Older builds may use the selected engine for first-result navigation; source changes do not update installed apps.
- **Website icons:** Vane fetches page-declared icons and site favicons, including for some restored or parked tabs. Icon URLs can belong to third parties. Requests can also occur in private windows; private icons are not saved to Vane's disk icon cache.
- **Link previews:** on by default. Hovering an eligible link can load its destination and resources without clicking, using the window's website store and applicable cookies. This also works in private windows, using their temporary store. Turn it off in **Settings → General → Previews**.
- **Favourite previews:** on by default for GitHub, Gmail and Google Calendar. A deliberate hover can load the service’s normal webpage. Vane can also refresh previews automatically without hovering, for signed-in favourites in the focused, visible regular browser window. Background refreshes may begin shortly after opening a regular window and repeat about every five minutes, checking up to three favourites per batch. They pause while Vane is inactive or Battery Saver is active. Both hover and background refreshes can load the service using the favourite’s profile session and applicable cookies, so the service can receive requests even when you have not opened a preview. Vane reads a small set of rendered item fields locally without a separate OAuth grant; it does not export cookies, use Live Folders’ OAuth token, call undocumented private endpoints, or send content to AI. Results stay in a bounded memory cache isolated by profile and verified account identity and are cleared on session/site-data changes. Private favourites show website navigation actions without extracting content or participating in background refreshes. Disable all favourite previews or individual services in **Settings → Previews**, independently of link previews.
- **Saved content:** saving an offline article can fetch its images. Enabling a live web preview in an Easel loads the source website using that profile's website store. These features are unavailable in private windows.

Network recipients may keep their own logs. Vane cannot delete information already received by a website or other service.

## AI features

**AI features are off by default.** Enable them during onboarding or in Settings → Max; existing explicit choices are preserved. Apple's on-device model is the default provider. Settings → Max lets you save multiple AI connections and choose one separately for tab titles, tab grouping, download names, and page summaries. Cloud connections use your own Groq, OpenAI, OpenRouter, or custom HTTPS API key, or **Continue with ChatGPT** to authorize eligible ChatGPT plan usage. Page summaries remain on-device until you explicitly select a cloud connection for them. Requests go directly to the selected provider, without a Vane server in between.

Cloud requests include the selected connection’s API key or ChatGPT OAuth access token, configured model, task instructions, and the data needed for the task:

- Pinned tab naming sends the page title and hostname. After you enable AI features, Tidy Titles is selected by default and can request cloud naming automatically after you configure a cloud provider.
- Tab grouping sends tab titles and hostnames when you use Tidy Tabs.
- Download naming sends the suggested filename, page title, and source hostname and path. Tidy Downloads is off by default; enabling it can trigger requests as downloads complete. These naming requests do not upload downloaded file contents.
- Page summaries send a bounded extract of the page title and article text when a link preview requests a summary, only if you explicitly route summaries to a cloud connection. This text may contain private page content.

Source URL query strings and fragments are omitted from this metadata, but titles, filenames, and paths may still contain personal or confidential information. **Test Connection** also sends a request to the configured provider. Private windows do not use these cloud API features. Route each feature to Apple, disable AI features, or remove the relevant connection to stop its cloud AI use; this cannot retract earlier requests.

ChatGPT sign-in opens OpenAI’s authorization page in your system browser. Vane stores each registration separately and keeps its access, refresh, and identity tokens in local, non-synchronizing Keychain items. It renews authorized sessions and fetches the account’s available models directly from OpenAI. Sign-out attempts session revocation and clears local tokens; disconnect Vane in ChatGPT Settings if remote revocation cannot be confirmed. ChatGPT plan eligibility and usage limits apply. Vane does not automatically switch to API-key billing when plan usage fails.

**Assistant websites are separate.** An explicit Ask action or assistant-prefixed search can open ChatGPT, Claude, Perplexity, or Grok with your question in the URL. This sends your question to that service, including when invoked in a private window. Normal website sign-in and cookie behavior applies to the window's website store. Provider policies govern their processing, retention, and any use for model training; review those policies before sending sensitive information.

## Updates and optional connections

- **App updates:** automatic update checks are on by default. Vane contacts GitHub's release API at launch and periodically, and downloads release files from GitHub or its delivery infrastructure when you install an update. These requests include ordinary connection metadata and cache-validation headers, not your browsing history or saved passwords. Disable automatic checks in Settings if you prefer manual checks. Private browsing does not disable app update checks.
- **Filter subscriptions:** no remote subscriptions are configured by default. Adding an HTTPS list contacts its host; enabled subscriptions are fetched again when due. The host receives ordinary request metadata and cache-validation headers. Subscriptions are app-wide and may update while private windows are open. Remove a subscription to stop future fetches for it.
- **GitHub Live Folders:** connecting an account sends authentication requests to GitHub, followed by account and pull-request queries, including any repository filter you choose. OAuth uses the `repo` scope. Active folders refresh periodically. Disconnect in Vane to stop their authenticated requests, and revoke the authorization or token in GitHub to invalidate it there.

These services receive requests directly and apply their own privacy policies and retention rules. Any network request exposes connection information such as your IP address to its recipient.

## Private browsing

Private windows use temporary browsing identities and nonpersistent website stores. Vane does not restore their history, tabs, or download records after quitting, or use your saved profile passwords and extensions there. They disable search suggestions, Instant Links, and cloud AI naming, grouping, and summaries.

Private browsing does not hide your IP address or activity from websites, services you contact, or your network. Assistant websites, website icons, link previews, and app-wide updates or filter fetches can still make requests as described above. Downloaded files and captures you explicitly save remain on disk.

## Retention and your controls

Regular browsing data stays locally until you delete it or a feature replaces it; Vane does not apply one universal automatic expiry period. Local recovery points can retain earlier library contents after you clear current records. The backup system normally keeps the latest ten completed recovery points, with protection for the last healthy point during recovery. Preserved crash originals and manually exported files can remain separately.

Use **Clear Browsing Data** for history, cookies/site data, and caches, or **Website Data** for selected sites. Manage saved passwords in Settings, and delete saved articles, Easels, and other library items using their controls. **Erase Everything** attempts to remove Vane's local library, recovery points, preferences, website data, saved passwords, and GitHub connection credentials. Inaccessible files or older data folders may remain if deletion fails.

AI credentials must be removed separately. **Before erasing**, select each saved connection in **Settings → Max** and choose **Remove Connection**. **Remove Key** clears an API key; **Sign Out** clears ChatGPT tokens and attempts session revocation. If revocation cannot be confirmed, disconnect Vane in ChatGPT Settings. Erasure clears connection preferences but leaves separate Keychain items; afterward, macOS Keychain Access may be needed to find remaining credentials. Erasing Vane does not remove downloaded files, exports, system backups, or copies held by other services. Deletion is not a guarantee of forensic erasure. See the [data guide](https://github.com/notnaki/vane/blob/main/docs/DATA-AND-PRIVACY.md) for exports, backup exclusions, and recovery behavior.

## Website, diagnostics, and public support

The project website uses same-site assets and has no added analytics, advertising trackers, or tracking cookies. It is hosted on GitHub Pages. GitHub receives visitor requests and handles hosting and GitHub account information under its [privacy statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement). Following external links contacts the destination service.

Vane keeps local recovery information and can write diagnostic messages to macOS logs. macOS may separately collect or share system diagnostics according to your Apple settings. Diagnostics or screenshots you choose to share can contain sensitive information; review them first.

## Security, changes, and contact

**Vane has not published an independent third-party security audit.** Open source, code review, automated tests, and release signing/notarization do not establish that an audit has taken place or guarantee that the app has no vulnerabilities.

Policy changes will be published here with an updated date; repository history records revisions. For privacy questions or to request help managing your data, contact the maintainer through the [GitHub issue tracker](https://github.com/notnaki/vane/issues). Issues are public: do not include passwords, API keys, tokens, or private browsing details. If a question requires sensitive information, ask for a private contact method before sharing it.
