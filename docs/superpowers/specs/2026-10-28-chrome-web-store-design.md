# Chrome Web Store installation

Implement the installation approach documented at https://yetanotherbrowser.com/manual/extensions: keep Apple's WebKit extension runtime, expose Add to Vane on Chrome Web Store detail pages, accept store links or IDs in the manager, verify downloaded CRX3 signatures before extraction, and retain reviewed profile-scoped installations across updates.

Use the existing managed revision store and permission review/rollback. Store identities use the verified Chrome extension ID for runtime.id and a stable synthetic installation key, while retaining Vane's UUID origin/storage isolation. Never infer package identity from the manifest. Require both the ID-bound developer proof and Google's pinned production publisher proof. Use the existing bounded ZIP extractor with extension-specific limits. Downloads use ephemeral networking, HTTPS allowlisted Google delivery hosts, a byte cap, a timeout, and no browser cookies.

Store-page integration runs in an isolated content world on the main frame of the exact HTTPS Chrome Web Store origin. Only trusted clicks request installation, and native handling validates the current document and profile again. No public custom URL installer or page-supplied download URL. The manager also exposes a store-link/ID dialog; local folder and signed Safari app installation remain available.

An accepted store record saves its verified ID and package version. Check for store updates once per day while its host is active, and on explicit Update from Store. Same-version/downgrade downloads do not replace accepted code. Updates retaining access may activate automatically; added access requires review. Preserve disabled state, pins, identity, and accepted code on cancellation or failure. Forget/remove/disable invalidate pending operations. Check operations again after network and staging awaits.

This request concerns Chrome Web Store installation using Yab's architecture. Broad emulation of bookmarks/history/downloads/native messaging and other APIs is a separate compatibility project; report current limitations honestly in the existing manager. Do not enable private extensions or native host execution as a side effect of store support. macOS 26 remains the minimum.

Validate parser/signature rejection, malicious archives through the existing extractor tests, installed identity/update/rollback/private isolation, a real Google store package, and actual store-page button behavior. Follow the repository PR, independent review, CI, squash-merge and task-owned process/worktree cleanup workflow.
