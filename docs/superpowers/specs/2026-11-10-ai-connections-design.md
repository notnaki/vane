# AI connections and ChatGPT plan sign-in

## Intent

Let people connect ChatGPT using their subscription alongside API-key providers,
save more than one connection (including multiple accounts/models at one provider),
and choose a connection separately for each browser AI feature. Build on Vane's
native SwiftUI settings, Keychain storage, bounded networking, and output validation.

The user's request authorizes implementation and the repository's normal validation,
independent review, and squash-merge workflow. The implementation interpretation of
“functions” is browser features, not an agent dynamically calling other AI providers.
The user confirmed that each Max feature/function should have its own selection.

## Behavior

- Settings → Max offers a list of named connections, Add Connection, and an editor.
  Apple on-device is always available without a credential. API connection types
  remain Groq, OpenAI, OpenRouter, and custom OpenAI-compatible HTTPS endpoints.
  ChatGPT is a separate connection type with **Continue with ChatGPT**.
- Each cloud connection has a stable ID, editable label, provider, model, and custom
  base URL where relevant. Credentials are separate Keychain items keyed by that ID.
  Two connections at the same provider never overwrite each other's credentials.
- Route tab titles, tab grouping, download naming, and page summaries independently.
  Every feature can choose Apple or a saved connection. Existing individual feature
  switches and the master AI switch still apply. Availability is per route.
- Preserve the previous provider/model/base URL and credential mapping when migrating
  the former single-provider preferences. Existing naming/grouping routes select
  that migrated connection; page summaries default to Apple. Never silently move
  a summary to a cloud provider. Choosing a cloud summary route explicitly enables
  sending extracted page text and the settings explain that behavior.
- Removing a connection clears its local credential and returns its routes to Apple.
  ChatGPT additionally supports sign-out/reconnect while retaining the registration's
  issued client ID and verified identity for future reauthorization.
- Sign-in, connection tests, and model refresh show progress/results for the specific
  connection. Switching editors or removing a connection cannot save stale results
  into another connection. Failed attempts retain a previously working account.
- Respect existing Reduce Motion/Battery Saver behavior for connection list changes.

## ChatGPT contract

Use OpenAI's public open-source Sign in with ChatGPT integration, not Codex's client
ID, local Codex credentials, private ChatGPT endpoints, or an app-wide API key.
Sources checked 2026-11-10:

- https://developers.openai.com/siwc/token-sharing-open-source/sign-in
- https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions
- https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference
- https://developers.openai.com/siwc/token-sharing-open-source/token-reference
- https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery
- https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations

Start a listener bound only to 127.0.0.1 before opening the authorization URL in the
system browser. Use /auth/callback, fresh cryptographic state, nonce, and PKCE S256,
and a host ID persisted locally for this installation/data directory. Support bounded
timeout and cancellation; reject mismatched/duplicate callback parameters.

New registrations use dynamic_agent_client with agent_name_hint=Vane. Save the issued
client ID returned by the validated callback; never exchange using dynamic_agent_client.
Returning registrations use their saved client ID and account hints. Keep each
registration/identity separate, even for identical email addresses. Validate JWT
signature with OpenAI JWKS, issuer, audience, expiration, nonce, and returning subject
before replacing tokens. Derive endpoints/issuer/JWKS from trusted OpenAI OIDC discovery
with HTTPS/trusted-origin checks. Request openid profile email offline_access
resource.invoke chatgpt.tokens.use.direct and resource=https://api.openai.com/v1.

Keep token sets (including refresh/ID tokens and scopes) together in non-synchronizing,
device-only Keychain items scoped to the existing test-data namespace. Refresh near
expiry, serialize refreshes per connection, atomically save rotating tokens, preserve
them on temporary errors, and stop using terminally invalid tokens. Check granted plan
scope before inference; identity-only sign-in remains visible with plan use disabled.
Sign-out attempts revocation, clears local tokens, and reports unconfirmed revocation.

Fetch the selected account's model catalog from GET https://api.openai.com/v1/models
with its OAuth token; show visibility=list entries in server order, display_name as the
label and slug as the model. Do not guess a model or reuse another account's catalog.

Plan inference uses POST https://api.openai.com/v1/responses, store=false, stream=true,
array input, and instructions. Omit unsupported generation knobs, including
max_output_tokens. Consume bounded SSE incrementally through response.completed;
incomplete, failed, interrupted, and oversized streams are not answers. Keep requests
cancellable with explicit timeouts and output bounds. Preserve safe diagnostic error
code/status/request ID for settings; never log tokens or raw authorization URLs.
Quota errors do not automatically switch to paid API keys or another connection.

## Routing and safety

Capture route, connection configuration, and settings revision before each request;
discard a result if any changed while awaiting it. Separate rate-limit cooldowns by
connection. Preserve concurrency bounds and cancellation. API-key providers retain
their current chat-completions transport. ChatGPT gets its own Responses transport.

Block all cloud requests from private windows at the browser request boundary and
transport boundary. Apple may retain its previous private-window behavior. Pass
private context explicitly to title, file, grouping, and summary calls.

Keep existing prompt fencing/input limits and title, filename, tab-ID, and summary
grounding validation. Cloud summaries may yield only the validated final text using
the existing cumulative-summary stream contract; Apple retains native streaming.
Changing routing cancels/discards pending summary output. Summary extraction remains
Reader-based, bounded, and never uploads file contents or cookies.

## Implementation choices left to the builder

Use small native Swift types and focused files; avoid new dependencies if Apple's
Security/CryptoKit/Network APIs suffice. Use stable Codable connection/routing records
in UserDefaults, credentials in Keychain, and no credential/preferences sync changes.
Use a compact connection picker/editor and per-feature route pickers consistent with
existing SettingsCard/SettingsRow components. Keep changes within AI setup, callers,
documentation, and directly relevant test harnesses.

## Validation and delivery

Offline fixtures exercise migration, duplicate providers, independent routes, deletion,
stale-result rejection, private-mode zero requests, OAuth state/client-ID validation,
JWT signature/claim rejection, rotation/errors, model selection, Responses wire format,
SSE terminal events/cancellation/bounds, and account isolation. Never require real
tokens, external sign-in, or user Keychain access for default tests. Optional isolated
Keychain tests cover credential storage. Run focused harnesses, Swift build, and the
required CI; obtain independent review of the final diff before squash-merge. Live
subscription authorization is user-interactive and cannot be certified by offline
fixtures; report that limit honestly. Update integrations/privacy documentation to
describe explicit cloud summaries and ChatGPT credentials/plan eligibility.
