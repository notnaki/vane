import Foundation

/// The page a tab shows when a load fails. WebKit hands us an NSError and then leaves the
/// tab on whatever was there before (usually nothing), so without this a dead link is a
/// blank white rectangle with no explanation.
///
/// ponytail: one interpolated HTML string, no template file and no localization. The
/// upgrade path is a Resources bundle the day this needs translating.
@MainActor enum ErrorPage {

    /// Whether a failure is worth interrupting the user for.
    static func shouldShow(_ error: Error) -> Bool {
        let e = error as NSError
        switch (e.domain, e.code) {
        // -999: the load was replaced by another load, or the user hit stop. Every
        // redirect-heavy site produces these; they are bookkeeping, not failures.
        case (NSURLErrorDomain, NSURLErrorCancelled): return false
        // 102 "frame load interrupted": what a navigation that turned into a download
        // looks like from here. 204: the response was handled elsewhere.
        case ("WebKitErrorDomain", 102), ("WebKitErrorDomain", 204): return false
        default: return true
        }
    }

    /// Plain language for the failure, in the words a person would use to describe it.
    /// Split out from `html` so it can be asserted without rendering anything.
    static func summary(for error: Error) -> (title: String, detail: String) {
        let e = error as NSError
        guard e.domain == NSURLErrorDomain else {
            return ("This page didn’t load", e.localizedDescription)
        }
        switch e.code {
        case NSURLErrorNotConnectedToInternet:
            return ("You’re offline", "This Mac isn’t connected to the internet. Check Wi-Fi and try again.")
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return ("Can’t find that server", "No computer answers to that name. The address may be misspelled, or the site may no longer exist.")
        case NSURLErrorCannotConnectToHost:
            return ("Connection refused", "The server is reachable but turned the connection away. It may be down, or nothing may be listening on that port.")
        case NSURLErrorTimedOut:
            return ("The server took too long", "It never answered. It may be overloaded, or something on the network may be dropping the connection.")
        case NSURLErrorNetworkConnectionLost:
            return ("The connection dropped", "The network went away mid-request.")
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired:
            return ("The secure connection failed", "Vane couldn’t verify this site’s identity, so it stopped rather than send your data to it. This is either a broken certificate or someone in the way.")
        case NSURLErrorUnsupportedURL:
            return ("Vane can’t open that address", "Nothing here knows how to handle this kind of link.")
        case NSURLErrorHTTPTooManyRedirects:
            return ("The site keeps redirecting", "It sent Vane in a loop and never arrived at a page.")
        case NSURLErrorBadServerResponse:
            return ("The server answered with nonsense", "What came back wasn’t a response Vane could read.")
        case NSURLErrorFileDoesNotExist, NSURLErrorResourceUnavailable:
            return ("That file isn’t there", "The address points at something that doesn’t exist.")
        case NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed:
            return ("The network refused the request", "This connection isn’t allowed to reach that address.")
        default:
            return ("This page didn’t load", e.localizedDescription)
        }
    }

    static func html(for error: Error, url: URL?) -> String {
        let (title, detail) = summary(for: error)
        let e = error as NSError
        let shown = url?.absoluteString ?? ""
        let code = "\(e.domain) \(e.code)"
        return """
        <!doctype html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
          :root {
            color-scheme: light dark;
            --bg: #ffffff; --fg: #1c1c1e; --dim: #6b6b70;
            --line: #e3e3e6; --card: #f7f7f8;
            --accent: #0a6cff; --accent-fg: #ffffff;
          }
          @media (prefers-color-scheme: dark) {
            :root {
              --bg: #16171a; --fg: #ececf0; --dim: #9a9aa2;
              --line: #2c2d32; --card: #1e1f23;
              --accent: #3b86ff; --accent-fg: #08131f;
            }
          }
          html, body { height: 100%; }
          body {
            margin: 0; background: var(--bg); color: var(--fg);
            font: 15px/1.55 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
            display: flex; align-items: center; justify-content: center;
            padding: 32px; box-sizing: border-box;
          }
          main { max-width: 30rem; width: 100%; }
          h1 { font-size: 1.6rem; line-height: 1.25; margin: 0 0 .6rem; letter-spacing: -.02em; }
          p { margin: 0 0 1.25rem; color: var(--dim); }
          .url {
            display: block; background: var(--card); border: 1px solid var(--line);
            border-radius: 8px; padding: .6rem .75rem; margin: 0 0 1.5rem;
            font: 12px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
            color: var(--fg); word-break: break-all;
          }
          button {
            font: inherit; font-weight: 500; color: var(--accent-fg);
            background: var(--accent); border: 0; border-radius: 8px;
            padding: .5rem 1.1rem; cursor: pointer;
          }
          button:active { opacity: .8; }
          .code { margin-top: 1.75rem; font-size: 11px; color: var(--dim);
                  font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
        </style>
        </head><body><main>
          <h1>\(escape(title))</h1>
          <p>\(escape(detail))</p>
          \(shown.isEmpty ? "" : "<code class=\"url\">\(escape(shown))</code>")
          <button onclick="location.reload()">Try Again</button>
          <div class="code">\(escape(code))</div>
        </main></body></html>
        """
    }

    /// Enough escaping for text dropped into element content. The inputs are a url and a
    /// system error string, never markup.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - check

    static func check() -> [(String, Bool)] {
        func err(_ code: Int, _ domain: String = NSURLErrorDomain) -> NSError {
            NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: "raw description"])
        }
        let offline = summary(for: err(NSURLErrorNotConnectedToInternet))
        let dns = summary(for: err(NSURLErrorCannotFindHost))
        let refused = summary(for: err(NSURLErrorCannotConnectToHost))
        let tls = summary(for: err(NSURLErrorServerCertificateUntrusted))
        let timeout = summary(for: err(NSURLErrorTimedOut))
        let page = html(for: err(NSURLErrorCannotFindHost),
                        url: URL(string: "https://no-such-host.example/a&b"))
        return [
            ("cancelled (-999) is not shown", shouldShow(err(NSURLErrorCancelled)) == false),
            ("a real failure is shown", shouldShow(err(NSURLErrorCannotFindHost))),
            ("download-shaped frame interruption is not shown",
             shouldShow(err(102, "WebKitErrorDomain")) == false),
            ("no internet says offline", offline.title == "You’re offline"),
            ("host not found says can’t find the server", dns.title == "Can’t find that server"),
            ("dns lookup failure maps to the same message as host not found",
             summary(for: err(NSURLErrorDNSLookupFailed)).title == dns.title),
            ("connection refused says refused", refused.title == "Connection refused"),
            ("every tls code lands on the secure-connection message",
             [NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
              NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
              NSURLErrorServerCertificateNotYetValid]
                .allSatisfy { summary(for: err($0)).title == tls.title }),
            ("timeout says the server took too long", timeout.title == "The server took too long"),
            ("distinct codes get distinct messages",
             Set([offline, dns, refused, tls, timeout].map(\.title)).count == 5),
            ("an unmapped code falls back to the system description",
             summary(for: err(-1234)).detail == "raw description"),
            ("a non-url-domain error still gets a page",
             summary(for: err(7, "SomeOtherDomain")).detail == "raw description"),
            ("the page names the failing url", page.contains("no-such-host.example")),
            ("the url is html-escaped", page.contains("a&amp;b") && !page.contains("a&b")),
            ("the page offers a reload", page.contains("location.reload()")),
            ("the page adapts to dark mode", page.contains("prefers-color-scheme: dark")),
        ]
    }
}
