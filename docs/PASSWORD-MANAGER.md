# Password manager

Vane stores passwords locally in the macOS login Keychain. Existing creator codes,
profile security domains and default HTTPS credential identities are unchanged. Edits
update the owned Keychain item in place; macOS can refresh its opaque reference when a
website or username changes. No vault, backend, synchronization or cloud analysis is added.

## Fill a saved account

Focus a username or current-password field to show the native account chooser. Rows name
the account and matching HTTPS website, including a nondefault port. “No username” means
the saved item has an empty username; it does not mean the item is broken. Use Up/Down
and Return to choose, Escape to dismiss, or click a row. A single matching account may
fill automatically into an empty recognized login. Multiple accounts wait for a choice.
Existing user-entered values and `autocomplete=off` are respected during automatic fill.
An explicit account choice can fill an `off` form. Filling never submits.

Detection prefers `autocomplete=username`, `current-password`, and `new-password`, then
conservative field names and email fields. New fields and visibility/type changes are
rediscovered after a short coalesced delay. Username-first flows retain an account only
within the same form replacement or one same-origin navigation, for up to two minutes.
The account remains attached to that password step for capture after submission.

Saved credentials never fill new-password fields. Multiple unlabelled passwords are
ambiguous and are not guessed at. Hidden, offscreen, clipped, disabled, read-only and
one-time-code fields are excluded from writing. A hidden/read-only username can be an
identity hint, but is never written. Form actions and submit-button overrides must stay
on the same HTTPS origin. Scheme, host and port must match; HTTP downgrades and certificate
exceptions do not grant password access. Same-origin embedded forms require explicit
frame focus. Cross-origin, opaque sandbox and detached/hidden frames are refused.

Every fill targets document and field identities in an isolated WebKit content world.
The app rechecks the web view, document generation and origin around asynchronous work;
the script checks the live fields again between username/password input events.

## Generate a new password

Focus a field marked as a new password, or clearly named as new/confirmation, to show
Generate password. Set 12–64 characters and choose lowercase, uppercase, numbers and
symbols. Use generated password fills the new field and its recognized confirmation,
without changing the current password or submitting. Site maximum lengths are respected:
if a field rejects the length or changes during filling, refocus it and try again.
Unlabelled pairs may require manual entry. Add/edit/review forms have the same generator.
Generated values use the platform secure random source and are stored only after consent.

## Review a submitted password

A form submission can produce an unverified save/update offer. Click Review to correct
the HTTPS website, username and password, then explicitly Save or Update. Return while
typing in the page does not accept an offer. Submission is not proof that authentication
succeeded; the offer says so. Visible `aria-invalid` credentials or an alert inside the
submitted form retract that attempt. Repeated unchanged submissions produce one offer.
A fetch-based form is captured on page exit only after a recent trusted submit-control
activation or Enter in a credential field. Simply leaving a filled form does not save it.

New accounts never silently replace existing accounts. Correcting a draft onto an existing
account, or finding a changed Keychain revision, requires another explicit update review.
Keychain errors retain the draft and offer recovery guidance. Unanswered offers expire
after five minutes and disappear when navigating to another origin or releasing the page.
Never suppresses future offers for the originating hostname in that profile. Reverse it
with Allow saving under Never Saved in Settings → Passwords.

## Manage and protect credentials

Settings → Passwords searches website/account names and sorts by website, username or
recent use. Open a website for each account’s full origin and actions to edit, reveal,
copy or delete. Repeated usernames for different origins are explained. Refresh passwords
retries failed reads; locked, denied and missing Keychain items are distinguished.
Renaming or changing a website cannot overwrite an existing account. Imported HTTP items
remain manageable at their original origin but cannot be autofilled.

Reveal, password copy, edit and the existing export flow use macOS device-owner
authentication, including its login-password fallback when Touch ID is unavailable.
Custom data directories no longer bypass authentication. Reveals hide after 60 seconds;
closing Settings or leaving the manager clears temporary secrets and invalidates pending
authentication. Draft/save-offer reveals also hide automatically. Copy password buttons mark clipboard items concealed for cooperating clipboard managers and expire after 60 seconds only if
the clipboard has not changed, even if later copied text is identical. This cannot control
clipboard utilities that ignore the concealed marker.

Profiles and disposable data-directory namespaces remain separate. Private windows do
not read, fill, generate through the saved-password bridge, or persist password offers.
Existing import/export remains available; this change adds no export format or new
plaintext-export action. No strength or reused-password analysis is added.

Passkeys remain outside this implementation. Settings explains the pending Apple browser
capability approval and provisioning; Vane does not simulate passkey support.

## Validation boundaries

`swift test --filter Password` covers real WebKit fixtures for dynamic forms, username-first
flows, signup/change fields, account choice, rejected attempts, form abandonment,
navigation/field races, frame/origin/action boundaries, profiles/private mode, generator
options, Keychain errors/collisions, manager sorting, clipboard ownership, popup rendering,
and keyboard scrolling. Set `VANE_TEST_KEYCHAIN=1` for the isolated import/export round trip.
Keychain-dependent tests skip explicitly if the host cannot store disposable items.
`VANE_PASSWORD_SNAPSHOTS=/tmp/vane-password-ui` writes native fixture PNGs.

`python3 scripts/check-browser-smoke.py --binary .build/debug/vane` assembles an ad-hoc
signed sandbox fixture. It also writes disposable credentials, exits, reads them from a
fresh process of the same signed app, verifies profile/port isolation, and deletes them.
The runner tracks bundle paths, PIDs and start times and verifies process exits.

These are controlled fixtures, not verified provider sign-ins. Unusual SPA login-completion
signals, shadow-DOM fields, cross-origin identity-provider frames and nonstandard fetch
buttons can require manual entry or adding a login in Settings. Visible rejection markers
are heuristics and cannot establish authentication success. Touch ID/VoiceOver behavior,
Developer ID upgrades, notarized clean-Mac persistence, and broad real-site compatibility
need separate device/user validation. The existing import/export and isolated signed
persistence checks do not establish those claims.
