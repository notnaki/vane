# Extensions, blocking, permissions, and AI

[Documentation index](README.md) · [Project README](../README.md)

Vane runs Chrome and Safari web extensions on Apple's WebKit, blocks ads with filter
lists, asks before sites use your camera or location, and adds optional AI features. None
of these need a Vane account.

## Extensions

Open **Extensions → Manage Extensions…**, **Settings → Advanced → Developer → Manage Extensions…**, or type
**Manage Extensions** in the command bar. The Extensions page opens as a
[settings tab](BROWSING.md#settings-pages-in-a-tab); its profile menu picks whose
extensions you see. Each profile has its own extensions. Private windows run none.

### Install an extension

| From | How |
| --- | --- |
| Chrome Web Store | On a store page, click **Add to Vane**. Or choose **Extensions → Install from Chrome Web Store…** and paste the page link or 32-letter ID. A link already on the clipboard fills in. The **+** tile in Site Controls opens the store. |
| An unpacked folder | **Extensions → Install Extension…**, then choose the folder that holds `manifest.json`, or drop it on the page. Unzip downloads in Finder first. |
| A Safari extension app | **Extensions → Install Extension…**, then choose the app. If it holds several extensions, pick one. |

Before anything runs, Vane checks the package and shows what the extension can access:
its required permissions, websites, optional extras it may ask for later, and anything it
asks for that Vane or WebKit doesn't support. When that happens, a line at the top
warns that some features may not work. Cancel leaves it uninstalled.

Store packages download straight from Google, without your cookies, and must carry valid
Chrome Web Store signatures. Safari apps must be signed by Apple-issued certificates with
a matching team. Unsigned, modified or mismatched packages are refused.

### Use and manage extensions

- **Pin** up to three extensions per profile to the address bar.
- **Right-click** an extension's icon in the address bar or in Site Controls for its
  menu: **Can Read and Change This Site**, **Options**, **Pin to Address Bar** /
  **Unpin from Address Bar**, **Remove from Vane…** and **Manage Extension…**.
- **Site Controls** shows every installed extension as a tile. Turned-off ones are dimmed;
  click one to turn it on.
- On the Extensions page, search and filter by **All**, **Enabled**, **Disabled** or
  **Needs Attention**. Select one for its details, **Open Options…**, keyboard commands
  and compatibility notes.
- **Disable** stops it and survives restart. **Remove…** deletes Vane's copy, its
  approval and its stored data; your original folder stays. Reinstalling starts fresh.
- Extension items appear in page right-click menus and in sidebar tab menus, where they
  act on the tab you clicked.
- Extension keyboard shortcuts work in that profile's windows. Vane's own shortcuts and
  text editing come first.

### Updates

Vane runs its own saved copy of each extension, so editing the source folder changes
nothing until you choose **Update from Folder…**, **Update from App…** or
**Update from Store…**. Every update is checked and reviewed before it runs, and new
access is called out. A valid update keeps the extension's settings, storage, pin and
approval. A failed or declined update keeps the version you had.

Store extensions also check for updates once a day while their profile is open. Updates
that need no new access install on their own; others wait in **Needs Attention** for
review. If an extension won't start, use **Retry**, then quit and reopen Vane.

### Access and privacy

Required access is approved at install. Optional access needs a separate request, and
temporary grants end when the extension reloads, is disabled or Vane quits.
**Revoke Additional Access…** clears extra grants; to stop all access, disable or remove
the extension. Revoking can't undo changes an extension has already made.

**Copy Diagnostics** copies the extension's state and error codes without paths,
websites, page content, credentials or extension storage. The details view itself can
show local paths, so check anything else before sharing it.

### Compatibility and validation

Vane uses WebKit's built-in extension support and fills in Chrome APIs that WebKit lacks.
These extensions were checked with unmodified packages; see
[Extension validation](EXTENSION-VALIDATION.md) for versions and results.

| Extension | Result |
| --- | --- |
| Bitwarden (Chrome Web Store and Firefox packages) | Sign-in, unlock after restart and autofill work |
| Dark Reader | Works |
| uBlock Origin Lite | Works |
| uBlock Origin (MV2) | Partly: static lists compile to WebKit rules ([details](MANIFEST-V2-COMPATIBILITY.md)) |
| AdBlock, uBlock | Block requests after the first rule compile (about a minute or two) |
| Claude in Chrome | Installs, opens its side panel, can drive the page on screen, and receives claude.ai's sign-in |
| GPTZero, Revision History | Partly: their Google Docs widgets appear |
| Copyleaks | Installs and starts |

**Chrome APIs Vane adds:**

| API | What you get |
| --- | --- |
| `chrome.sidePanel` | The extension's panel docks to the right of the page, per tab, with a header and a ✕ that always closes it. It follows its tab across Spaces and windows. |
| `chrome.debugger` | An extension that asks for it can read, click, type in and screenshot pages it has access to. A pill reads "*Extension* is controlling this tab" with **Stop**, and the tab's sidebar row shows a pointer. Only the tab on screen can be driven. |
| `chrome.tabGroups` | A group is a folder in Today. Extensions can read your folders but change only folders an extension made. Pinned tabs and Favourites can't be grouped. |
| `chrome.identity` | `launchWebAuthFlow` opens a sign-in window titled with the extension's name and the site, using the profile's cookies. |
| `chrome.notifications` | `create`, `update`, `clear`, `getAll` and `getPermissionLevel` show text notifications in Notification Center under the extension's name; `getPermissionLevel` says `denied` when macOS notifications are off for Vane. `onClicked`, `onClosed` and up to two buttons (`onButtonClicked`) reach the background worker. Needs the `notifications` permission. |
| Chromium-only names | `downloads`, `idle`, `management.getSelf`, `alarms` promises and others exist so extensions start, but `downloads` doesn't do anything. Chrome's enums and constants are filled in too. |
| Native messaging | Extensions that declare `nativeMessaging` get Chrome's "Specified native messaging host not found." error, so ones that expect a desktop app (like Bitwarden) carry on. No desktop app is contacted. Turn it off with **Disable Error-Only Mode** in Manage Extensions → Compatibility. |

These additions apply to Chrome Web Store and folder packages. Safari app extensions get
none of them, and get the native messaging error only after **Review Error-Only Mode…**.

Large rule sets take a while: WebKit compiles an extension's rules in the background, and
pages load unfiltered until it finishes. Later launches reuse the result.

### Manifest V2 request filtering

MV2 background pages, content scripts, messaging, storage and actions run. WebKit's
`webRequest` can't block, redirect or change requests, and Vane says so at install. For
**uBlock Origin**, Vane turns its selected static lists, your filters and trusted sites
into WebKit rules for that profile; the extension needs access to all websites. Dynamic
filtering isn't available. See [Manifest V2 compatibility](MANIFEST-V2-COMPATIBILITY.md).

## Content blocking and filter subscriptions

Turn blocking on or off in **Settings → Profiles → Privacy and Security → Block ads and
trackers**. The built-in list works offline. Add more under **Content Blocking**:

| Option | Behavior |
| --- | --- |
| **Import from Disk…** | Saves a copy of a list file; it never refreshes |
| **Link Local File…** | Rereads the file every 30 seconds while Vane runs, and after launch and wake |
| **Subscribe by URL** | Downloads an HTTPS list daily, without your cookies; **Update Now** checks at once |

Lists are shared by all profiles; the on/off switch and site exceptions belong to each
profile. Each list has **Use these rules**, **Refresh automatically**, **Relink…**,
**Unsupported Rules…** and **Remove**. A list that fails to update keeps its last working
rules. Reload open pages after a change. Backups keep list contents but not access to
linked files, so a restored linked list needs **Relink…**.

**On a site:** **Site Controls → Block Ads** turns blocking off for that exact host and
reloads. **Site Controls → ⋯ → Filter Lists and Diagnostics…** shows update status,
unsupported rules and your exceptions. Choices made in private windows aren't saved.

Vane supports the common EasyList syntax: anchors, wildcards, exceptions, resource and
party options, domain restrictions, CSS element hiding, `$match-case`, `$badfilter` and
simple regular expressions. Rules it can't represent are skipped and listed under
**Unsupported Rules…**, never approximated.

## Site permissions

When a site asks for your camera, microphone, location or to show notifications, choose **Allow Once**,
**Always Allow** or **Don't Allow**. Allow Once lasts until the page navigates or closes.
Saved answers belong to that site in that profile; private windows keep them in memory.
Requests from embedded frames are refused.

Change an answer from **Site Controls**: right-click a permission for Ask, Allow or Block,
or choose **⋯ → Site Settings…** for every permission. Blocking stops the camera or
microphone at once. macOS has its own permission for each device and for screen sharing;
Vane can't override a macOS denial. See [Site permissions](SITE-PERMISSIONS.md).

Sites can show notifications in Notification Center once allowed. A site can only ask
after you click or type on it. Each notification names its site; clicking one brings
back its tab. macOS asks once whether Vane may show notifications.

## AI connections and feature routing

AI features are off until you turn them on in onboarding or **Settings → Max**. Apple's
on-device model is always available and needs no account.

**Add a connection** with **Add** in **Settings → Max**: ChatGPT, Groq, OpenAI, OpenRouter, or any
OpenAI-compatible HTTPS API. Then choose a connection for each feature: **Tab titles**,
**Tab grouping**, **Download names**, **Page summaries** and **Ask on Page**. Adding a
connection doesn't change any route. Summaries and Ask on Page stay on device until you
pick a cloud connection for them.

- **API keys:** enter a model ID and your key, **Save Key**, then **Test Connection**.
  Keys stay in your Mac's Keychain. Provider pricing and limits apply.
- **ChatGPT:** **Continue with ChatGPT** signs in through your browser with OpenAI's
  sign-in, using your ChatGPT plan instead of an API key. **Refresh Models**, pick a model,
  then assign features. **Manage Usage…** opens ChatGPT's usage page. Vane never falls back
  to API billing. **Sign Out** clears local tokens and tries to revoke the session.
- **Remove Key** clears a key; **Remove Connection** removes the connection and sends its
  features back to Apple.

**What cloud features send.** Your requests go straight to the provider, never through a
Vane server.

| Feature | Sent |
| --- | --- |
| Tab titles, Tab grouping | Page titles and hostnames |
| Download names | Filename, page title, source host and path (no query or fragment) |
| Page summaries | The page title and an extract of its text |
| Ask on Page | Your question, the last two exchanges, and the page title and text extract |

Private windows never use cloud AI; Ask on Page there works only with Apple on device.
Assistant websites such as ChatGPT or Claude are separate and receive what you send them,
even from a private window. See the [privacy policy](../PRIVACY.md#ai-features).

### Ask on Page

Press <kbd>⌘F</kbd> and click the sparkles button, or type **Ask on Page** in the command
bar. Type a question and press <kbd>Return</kbd>; ask follow-ups in the same field. The
magnifying glass, <kbd>⌘F</kbd> or <kbd>⌘G</kbd> return to Find; <kbd>Esc</kbd> closes it
and clears the conversation, as does switching tabs or loading a new page.

Answers come only from the page's title and text. Instructions written into a page are
treated as page content, but answers can still be wrong or swayed by the page.

### Link summaries and titles

With **Settings → General → Previews → Preview links on hover** on, pausing over a link
shows its title, screenshot and description. With Max on, a two-sentence summary follows.
Battery Saver pauses link previews.

With **Rename favorite and pinned tab titles** on, right-click a pinned tab and choose
**Regenerate Title** for a fresh name. It replaces a manual rename too; if it fails, the
current name stays.

[Translate Page](FEATURES.md#translate-page) uses Apple's on-device translation, not
Max or a cloud service.

## GitHub Live Folders

A Live Folder is a pinned folder of GitHub pull requests. Choose **New Live Folder…** from
a Space's menu, then pick pull requests you're involved in or one repository, optionally
only recent ones. It refreshes every five minutes, when you unfold it, or with
**Refresh Now**. A row you take out stays out.

Release builds sign in to GitHub in your browser; builds from source use a personal
access token. The token lives in the Keychain for that profile, separate from website
passwords, and never fills web forms or appears in password exports. Browser sign-ins
renew themselves; sign-ins from older builds need one reconnect.

If GitHub rejects the token, refreshes keep trying and **Edit Live Folder…** offers to
reconnect. Only signing out deletes the token. Console's `[vane] GitHub` messages tell a
missing token from a rejected one, without logging tokens.

## Favourite previews

GitHub, Gmail and Google Calendar favourites show a preview card when you pause over
them: open pull requests, inbox messages, or upcoming events. Move into the card to use
it; move away or press <kbd>Esc</kbd> to close it. From the keyboard, focus the favourite
and press <kbd>⌥↓</kbd>, or choose **Show Favourite Preview** from its menu. Items open in
a new tab in the favourite's profile. Gmail's **Compose** opens the website and sends
nothing.

Previews read the normal website with your existing sign-in. They don't use the Live
Folders token, Google APIs, AI or a Vane server. Results stay in memory, per profile and
account, and are cleared when you sign out, clear site data, or change preview settings.
Vane may check up to three favourites in the front window about every five minutes,
starting 12 seconds after launch, but never in private windows, with Battery Saver on, or
while Vane is in the background.

Turn previews off, or per service, in **Settings → General → Previews**. They're
separate from link previews.

## Limits

- **Not available:** real native messaging (so desktop-app bridges such as Claude Desktop's or
  1Password's), developer-tools panels, replacement new-tab pages, omnibox keywords,
  Chrome's Google-account sign-in (`identity.getAuthToken` and `oauth2`),
  `chrome.offscreen`, and ZIP or CRX files from disk.
- **Apple's iCloud Passwords extension** can't run: macOS only starts its helper for
  Apple-approved browsers. See [Password manager](PASSWORD-MANAGER.md) and the
  [investigation](EXTENSION-VALIDATION.md#icloud-passwords-investigation--2026-11-22).
- **Claude in Chrome** hasn't been tried with a real account. It can't drive background
  tabs, read console or network events, or answer page dialogs.
- **`chrome.debugger`** supports evaluating script, screenshots, mouse, keys and
  navigation; other protocol commands fail. **`chrome.tabGroups`** colours aren't shown,
  groups stay in one window, and `tabs.onUpdated` doesn't report group changes.
  **`chrome.sidePanel`** forgets its options when the extension reloads.
- **Content blocking** covers part of EasyList; scriptlets, procedural selectors and
  complex regular expressions are skipped. There are no per-request block counts.
- **Embedded frames** can't use the camera, microphone, location or notifications.
- **Web notifications** come from open pages only: service-worker notifications and Push
  (`registration.showNotification`, `PushManager`) aren't available, so a closed site
  can't notify you. A closed tab's notifications are removed. Icons are best effort;
  notification actions, images and badges aren't shown. Like other browsers, Vane doesn't
  limit how many notifications an allowed site shows. Private windows' notifications are
  removed when Vane quits, and any left from an earlier run are removed at launch.
  Extension notifications are text only (no icons or images) and reach only the background
  worker, which keeps running while they're showing and is started for a click if it was
  stopped. A worker that's running but had nothing showing itself (the notification came
  from its popup) hears the click when it next adds a listener or shows one.
- **Favourite previews** depend on each site's page layout; when one changes, the card
  shows **Preview unavailable** instead of an empty list.
- Details and evidence: [Extension validation](EXTENSION-VALIDATION.md),
  [Worker navigator identity](EXTENSION-WORKER-IDENTITY.md),
  [Manifest V2 compatibility](MANIFEST-V2-COMPATIBILITY.md),
  [Site permissions](SITE-PERMISSIONS.md),
  [Real-site compatibility](REAL-SITE-COMPATIBILITY.md).
