/// The one secret Vane is compiled with: the GitHub OAuth app's client secret, which the
/// sign-in needs in order to trade an authorization code for a token.
///
/// It is `nil` here and `nil` in every source checkout. `.github/workflows/release.yml`
/// substitutes the real value into this file — from the `GH_OAUTH_CLIENT_SECRET` Actions
/// secret — in the step before `make-app.sh` runs, so only a release build carries it. A
/// build with none falls back to pasting a personal access token, which is what Vane did
/// before any of this existed; see `LiveFolders.route`.
///
/// ponytail: one checked-in file with one substituted line, rather than a generated file, a
/// build plugin or an `.xcconfig`. SwiftPM cannot hand the compiler an environment variable
/// portably, and a generated-and-gitignored file is a file that is missing exactly once — on
/// the first clean checkout, in CI, with a compile error nobody can read. Rewriting one line
/// that is already valid Swift cannot produce a source tree that does not build.
///
/// The client *id* is public and lives in the code (`GitHubOAuth.clientID`); GitHub's web
/// flow requires the secret, and there is no way to keep a secret inside an app the user
/// runs. What it buys is that the redirect cannot be traded for a token by anything but a
/// real Vane build — which is why the release is the only build that carries it.
enum OAuthSecret {
    static let github: String? = nil
}
