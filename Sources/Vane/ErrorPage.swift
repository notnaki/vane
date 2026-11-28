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
        let offline = e.domain == NSURLErrorDomain && e.code == NSURLErrorNotConnectedToInternet
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
            --accent: #0a6cff; --accent-fg: #ffffff; --food: #ff6a3d;
          }
          @media (prefers-color-scheme: dark) {
            :root {
              --bg: #16171a; --fg: #ececf0; --dim: #9a9aa2;
              --line: #2c2d32; --card: #1e1f23;
              --accent: #3b86ff; --accent-fg: #08131f; --food: #ff7d55;
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
          \(offline ? snakeStyle : "")
          .code { margin-top: 1.75rem; font-size: 11px; color: var(--dim);
                  font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
        </style>
        </head><body><main>
          <h1>\(escape(title))</h1>
          <p>\(escape(detail))</p>
          \(shown.isEmpty ? "" : "<code class=\"url\">\(escape(shown))</code>")
          <button onclick="location.reload()">Try Again</button>
          \(offline ? snakeGame : "")
          <div class="code">\(escape(code))</div>
        </main></body></html>
        """
    }

    /// Snake, for the offline page only: something to do while the Wi-Fi comes back, the way
    /// Chrome has its dinosaur. Space starts, arrows or WASD steer, walls and your own tail end
    /// it. When the connection comes back the page reloads itself, or after the game in progress
    /// ends.
    ///
    /// ponytail: inline canvas, setInterval tick, no assets. Best score is in memory only: the
    /// page runs at the failed site's origin, so localStorage would write into that site.
    /// No backslashes below: this is a Swift literal.
    private static let snakeStyle = """
          .board { position: relative; margin-top: 2rem; }
          #snake { display: block; width: 100%; height: auto; background: var(--card);
                   border: 1px solid var(--line); border-radius: 10px; cursor: pointer; }
          .msg { position: absolute; inset: 0; display: flex; align-items: center;
                 justify-content: center; color: var(--dim); font-size: 13px; pointer-events: none; }
          .hud { display: flex; justify-content: space-between; margin-top: .5rem; font-size: 11px;
                 color: var(--dim); font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
    """

    private static let snakeGame = """
          <div class="board">
            <canvas id="snake" aria-label="Snake game"></canvas>
            <div class="msg" id="msg">Press Space to play Snake</div>
          </div>
          <div class="hud"><span id="score">Score 0</span><span id="best"></span></div>
          <script>
          (() => {
            const c = document.getElementById('snake'), g = c.getContext('2d');
            const msg = document.getElementById('msg'), scoreEl = document.getElementById('score'),
                  bestEl = document.getElementById('best');
            const S = 16, W = 30, H = 12, r = devicePixelRatio || 1;
            c.width = W * S * r; c.height = H * S * r; g.scale(r, r);
            const css = n => getComputedStyle(document.documentElement).getPropertyValue(n).trim();
            const h1 = document.querySelector('h1'), title = h1.textContent;
            let best = 0, back = false;
            let snake, dir, next, food, score = 0, timer, state = 'idle';
            const hud = () => { scoreEl.textContent = 'Score ' + score;
                                bestEl.textContent = best ? 'Best ' + best : ''; };
            const hit = (p, list) => list.some(q => q.x === p.x && q.y === p.y);
            const place = () => { if (snake.length >= W * H) { food = { x: -1, y: -1 }; return; }
                                  do food = { x: Math.random() * W | 0, y: Math.random() * H | 0 };
                                  while (hit(food, snake)); };
            const say = t => { msg.textContent = t; msg.style.display = t ? '' : 'none'; };
            const run = () => { clearInterval(timer); state = 'play'; say(''); timer = setInterval(step, 110); };
            const reset = () => {
              snake = [{ x: 6, y: 6 }, { x: 5, y: 6 }, { x: 4, y: 6 }];
              dir = next = { x: 1, y: 0 }; score = 0; place();
            };
            const start = () => { reset(); hud(); run(); draw(); };
            const step = () => {
              dir = next;
              const h = { x: snake[0].x + dir.x, y: snake[0].y + dir.y };
              const eat = h.x === food.x && h.y === food.y;
              if (h.x < 0 || h.y < 0 || h.x >= W || h.y >= H || hit(h, eat ? snake : snake.slice(0, -1))) {
                clearInterval(timer); state = 'over';
                best = Math.max(best, score);
                hud(); say('Game over · Space to play again');
                if (back) setTimeout(() => { if (back && state === 'over') location.reload(); }, 1500);
                return;
              }
              snake.unshift(h);
              if (eat) { score++; hud(); place(); } else snake.pop();
              draw();
            };
            const cell = (p, inset, rad) => { g.beginPath();
              g.roundRect(p.x * S + inset, p.y * S + inset, S - 2 * inset, S - 2 * inset, rad); g.fill(); };
            const draw = () => {
              g.clearRect(0, 0, W * S, H * S);
              g.fillStyle = css('--food'); cell(food, 3, 5);
              g.fillStyle = css('--accent');
              snake.forEach((p, i) => { g.globalAlpha = i ? 0.85 : 1; cell(p, 1, 4); });
              g.globalAlpha = 1;
            };
            const keys = { ArrowUp: [0, -1], ArrowDown: [0, 1], ArrowLeft: [-1, 0], ArrowRight: [1, 0],
                           w: [0, -1], s: [0, 1], a: [-1, 0], d: [1, 0] };
            addEventListener('keydown', e => {
              if (e.metaKey || e.ctrlKey || e.altKey) return;
              if (e.key === ' ' && e.target instanceof HTMLButtonElement) return; // Space presses the button
              if (e.key === ' ') { e.preventDefault();
                if (state === 'paused') run(); else if (state !== 'play') start(); return; }
              const k = keys[e.key.length === 1 ? e.key.toLowerCase() : e.key];
              if (!k || state !== 'play') return;
              e.preventDefault();
              if (k[0] !== -dir.x || k[1] !== -dir.y) next = { x: k[0], y: k[1] };
            });
            c.addEventListener('click', () => { if (state === 'paused') run(); else if (state !== 'play') start(); });
            const pause = () => { if (state === 'play') {
              clearInterval(timer); state = 'paused'; say('Paused · Space to continue'); } };
            addEventListener('blur', pause);
            document.addEventListener('visibilitychange', () => { if (document.hidden) pause(); });
            addEventListener('online', () => {
              if (state !== 'play' && state !== 'paused') return location.reload();
              back = true; h1.textContent = 'You’re back online';
            });
            addEventListener('offline', () => { back = false; h1.textContent = title; });
            reset(); food = { x: 24, y: 6 }; hud(); draw(); // idle frame: keep the food clear of the message
          })();
          </script>
    """

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
            ("the offline page has snake",
             html(for: err(NSURLErrorNotConnectedToInternet), url: nil).contains("id=\"snake\"")),
            ("other failures don’t", !page.contains("id=\"snake\"")),
        ]
    }
}
