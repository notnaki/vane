import Foundation
import WebKit

@MainActor enum Autofill {
    /// Its own content world, like PictureInPicture's. Nothing this script defines is on the
    /// page's `window`, so a hostile page cannot replace `__vaneFill` with a function that
    /// keeps whatever it is handed, and cannot post its own messages to `vanepw`.
    static let world = WKContentWorld.world(name: "vane-passwords")

    /// Main-frame bridge; listeners also attach to accessible same-origin documents.
    /// Cross-origin and opaque sandbox frames cannot enter this registry.
    static let script = """
    (function () {
      if (window.__vaneFill) return;
      var topWindow = window, topOrigin = window.origin, contexts = new Map(), recentContext = null;
      // Follow only public open roots. Slots participate in ancestor visibility;
      // closed roots never become reachable, even through a previously cached field.
      function composedParent(el) {
        return el.assignedSlot || el.parentElement || (el.getRootNode && el.getRootNode().host) || null;
      }
      function deepActive(document) {
        var active = document.activeElement;
        while (active && active.shadowRoot && active.shadowRoot.activeElement)
          active = active.shadowRoot.activeElement;
        return active;
      }
      function accessibleWindow(candidate) {
        // WindowProxy [[GetPrototypeOf]] silently returns null when DOM access is
        // forbidden. contentDocument instead makes WebKit log a security error.
        try { return !!candidate && Object.getPrototypeOf(candidate) !== null; }
        catch (_) { return false; }
      }
      function exactOriginWindow(candidate) {
        if (!accessibleWindow(candidate)) return false;
        var origin = candidate.origin;
        return origin !== 'null' && origin === topOrigin;
      }
      function install(window) {
        var document;
        try {
          if (!accessibleWindow(window)) return;
          // document.domain can make another host or port DOM-accessible. Credentials
          // still require the exact serialized origin, including inherited srcdoc origins.
          if (window !== topWindow && !exactOriginWindow(window)) return;
          document = window.document;
        } catch (_) { return; }
        if (!document) return;
        if (contexts.has(document)) { contexts.get(document).ready(); return; }
        var documentID = Array.from(topWindow.crypto.getRandomValues(new Uint32Array(4))).join('-'), fields = new WeakMap(), fieldSerial = 0;
        var retired = false, observer = null, discoveryTimer = null, rootTimer = null;
        var shadowListeners = new Map(), credentialListeners = [];
        var listeners = [];
        function listen(target, name, fn, capture) {
          target.addEventListener(name, fn, capture);
          listeners.push([target, name, fn, capture]);
        }
        function pauseDiscovery() {
          if (observer) observer.disconnect();
          if (discoveryTimer !== null) clearTimeout(discoveryTimer);
          if (rootTimer !== null) clearInterval(rootTimer);
          rootTimer = null; discoveryTimer = null; pending = false;
          shadowListeners.forEach(function (entries, root) {
            entries.forEach(function (entry) { root.removeEventListener(entry[0], entry[1], true); });
          });
          shadowListeners.clear();
        }
        function dispose() {
          retired = true; pauseDiscovery();
          listeners.forEach(function (l) {
            // The stored WindowProxy may now target a foreign document. Its old
            // global owns those listeners; do not probe methods on the new one.
            if (l[0] === window && !accessibleWindow(window)) return;
            l[0].removeEventListener(l[1], l[2], l[3]);
          });
          listeners = []; lastPair = lastCapturePair = lastGeneration = usernameStep = submittedAttempt = null;
          selectedAccounts = new WeakMap();
        }
        function attachedDocument() {
          if (retired) return false;
          try {
            if (!accessibleWindow(window) || !accessibleWindow(topWindow)) return false;
            if (window.document !== document || window.origin !== topOrigin || topWindow.origin !== topOrigin) return false;
            var child = window;
            while (child !== topWindow) {
              if (!exactOriginWindow(child)) return false;
              var parent = child.parent;
              if (!exactOriginWindow(parent)) return false;
              var frame = child.frameElement;
              if (!frame || !frame.isConnected || frame.contentWindow !== child) return false;
              child = parent;
            }
            return true;
          } catch (_) { return false; }
        }
        function liveDocument() {
          if (!attachedDocument()) return false;
          for (var child = window; child !== topWindow; child = child.parent) {
            if (!shown(child.frameElement)) return false;
          }
          return true;
        }
        function focusedFrame() {
          if (!attachedDocument()) return false;
          try {
            for (var child = window; child !== topWindow; child = child.parent)
              if (deepActive(child.parent.document) !== child.frameElement) return false;
            return true;
          } catch (_) { return false; }
        }
        function fieldID(field) {
          if (!field) return '-';
          if (!fields.has(field)) fields.set(field, String(++fieldSerial));
          return fields.get(field);
        }
        function token(p) {
          var field = p && (p.pass || p.user);
          if (!field) return null;
          return documentID + ':' + fieldID(field) + (p.pass ? ':password:' : ':username:') + fieldID(p.user || p.linkedUser);
        }
        // React and friends install their own value setter; assigning .value directly updates
        // the DOM but not the component state, and the site then submits an empty field.
        function setValue(el, v) {
          var d = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value');
          if (d && d.set) { d.set.call(el, v); } else { el.value = v; }
          el.dispatchEvent(new window.Event('input', { bubbles: true, composed: true }));
          el.dispatchEvent(new window.Event('change', { bubbles: true, composed: true }));
        }
        function shown(el) {
          if (!attachedDocument()) return false;
          var view = el.ownerDocument.defaultView;
          if (!accessibleWindow(view)) return false;
          var r = el.getBoundingClientRect(), style = view.getComputedStyle(el);
          for (var parent = el; parent; parent = composedParent(parent)) {
            var tree = parent.getRootNode();
            if (tree.host && tree.host.shadowRoot !== tree) return false;
            var ps = parent.ownerDocument.defaultView.getComputedStyle(parent);
            if (parent.hidden || parent.inert || parent.getAttribute('aria-hidden') === 'true' ||
                ps.display === 'none' || ps.visibility !== 'visible' || Number(ps.opacity) === 0 ||
                ps.contentVisibility === 'hidden' || ps.clipPath !== 'none') return false;
            if (parent !== el && /(hidden|clip|scroll|auto)/.test(ps.overflow + ps.overflowX + ps.overflowY)) {
              var pr = parent.getBoundingClientRect();
              if (r.right <= pr.left || r.left >= pr.right || r.bottom <= pr.top || r.top >= pr.bottom) return false;
            }
          }
          if (r.right <= 0 || r.bottom <= 0 || r.left >= window.innerWidth || r.top >= window.innerHeight) return false;
          return el.isConnected && r.width > 0 && r.height > 0 && el.getClientRects().length > 0 &&
            style.visibility === 'visible' && !el.closest('[inert],[aria-hidden="true"]');
        }
        function usableInput(el) {
          return !el.disabled && !el.readOnly && el.type !== 'hidden' && !hasRole(el, 'one-time-code') && shown(el);
        }
        function hasRole(el, role) { return (el.autocomplete || '').toLowerCase().split(/\\s+/).includes(role); }
        function usernameInput(el) {
          var roles = el.autocomplete.toLowerCase().split(/\\s+/).filter(Boolean);
          return ['text', 'email', 'tel'].includes(el.type) &&
            (!roles.length || roles.every(function (r) { return r === 'on' || r === 'off' || r === 'username' || r === 'email' || r.startsWith('section-'); })) &&
            !hasRole(el, 'one-time-code') &&
            !/captcha|verification|confirm|search/i.test(el.name + ' ' + el.id) &&
            (el.type === 'email' || hasRole(el, 'username') || /user|login|email|account|identifier/i.test(el.name + ' ' + el.id));
        }
        // Bound each scan; exhausting a budget refuses discovery rather than pairing
        // controls from a partial tree. No prototype patches in the page's world.
        function deepQuery(root, selector) {
          var result = [], nodes = 0, roots = 0, exceeded = false;
          function visit(scope, depth) {
            if (++roots > 128 || depth > 32) { exceeded = true; return; }
            // Admit a bounded tree before allocating native selector results. Count
            // its light DOM up front; nested roots share the same total budget.
            var elements = [], walker = document.createTreeWalker(scope, 1), el;
            while ((el = walker.nextNode())) {
              if (++nodes > 20000) { exceeded = true; return; }
              elements.push(el);
            }
            // Match in WebKit once per tree instead of crossing into its selector
            // engine for every decorative element. '*' needs no matching.
            var matching = selector === '*' ? null : new Set(scope.querySelectorAll(selector));
            for (var el of elements) {
              if (exceeded) break;
              if (!matching || matching.has(el)) result.push(el);
              if (el.shadowRoot) visit(el.shadowRoot, depth + 1);
            }
          }
          visit(root, 0);
          if (exceeded) result = [];
          result.complete = !exceeded;
          return result;
        }
        function rootFor(el) {
          if (el.form) return el.form;
          for (var parent = composedParent(el); parent; parent = composedParent(parent))
            if (parent.matches('form,[role="form"],fieldset')) return parent;
          return el.getRootNode();
        }
        function composedOrder(a, b) {
          if (a === b) return 0;
          var left = [], right = [];
          for (var node = a; node; node = composedParent(node)) left.push(node);
          for (var node = b; node; node = composedParent(node)) right.push(node);
          while (left.length && right.length && left[left.length - 1] === right[right.length - 1]) {
            left.pop(); right.pop();
          }
          if (!left.length) return -1;
          if (!right.length) return 1;
          var order = left[left.length - 1].compareDocumentPosition(right[right.length - 1]);
          return order & 4 ? -1 : (order & 2 ? 1 : 0);
        }
        function inputsFor(root) {
          var inputs = deepQuery(root, 'input');
          if (!inputs.complete) return [];
          // Include native form= associations outside the form's physical subtree.
          if (root.tagName === 'FORM') {
            if (root.elements.length > 20000) return [];
            var included = new Set(inputs);
            Array.from(root.elements).forEach(function (el) {
              if (el.tagName === 'INPUT' && !included.has(el)) { inputs.push(el); included.add(el); }
            });
            if (inputs.length > 20000) return [];
          }
          return inputs.filter(function (el) { return rootFor(el) === root; }).sort(composedOrder);
        }
        function safeRoot(root) {
          try {
            // A form= control may live outside its native form and be slotted into
            // a different composed form. Inspect both routes, including external
            // controls, before discovery, capture, generation and each secret write.
            var forms = [], starts = [root], visited = new Set();
            if (root.tagName === 'FORM') {
              if (root.elements.length > 20000) return false;
              starts = starts.concat(Array.from(root.elements));
            }
            for (var start of starts) {
              for (var parent = start; parent; parent = composedParent(parent)) {
                if (visited.has(parent)) break;
                visited.add(parent);
                if (visited.size > 20000) return false;
                if (parent.tagName !== 'FORM') continue;
                var nested = deepQuery(parent, 'form');
                if (!nested.complete) return false;
                forms.push(parent); forms = forms.concat(nested);
              }
            }
            return Array.from(new Set(forms)).every(function (form) {
              if (form.elements.length > 20000) return false;
              var action = new URL(form.getAttribute('action') || document.baseURI, document.baseURI);
              if (action.origin !== topOrigin || action.protocol !== 'https:') return false;
              var overrides = deepQuery(form, '[formaction]');
              if (!overrides.complete) return false;
              overrides = overrides.concat(Array.from(form.elements).filter(function (el) { return el.hasAttribute('formaction'); }));
              return overrides.every(function (button) {
                var override = new URL(button.getAttribute('formaction') || document.baseURI, document.baseURI);
                return override.origin === topOrigin && override.protocol === 'https:';
              });
            });
          } catch (_) { return false; }
        }
        function passwordPurpose(el) {
          if (hasRole(el, 'current-password')) return 'current';
          if (hasRole(el, 'new-password')) return 'new';
          var name = el.name + ' ' + el.id + ' ' + (el.getAttribute('aria-label') || '');
          if (/current|old|existing/i.test(name)) return 'current';
          if (/new.?pass|confirm|repeat|create.?pass/i.test(name)) return 'new';
          return '';
        }
        // Prefer semantic autocomplete attributes, then the nearest preceding username.
        // Never use a registration/reset password as an existing sign-in password.
        function pair(root, capture) {
          if (!safeRoot(root)) return null;
          var inputs = inputsFor(root);
          if (!capture) inputs = inputs.filter(usableInput);
          var passwords = inputs.filter(function (el) {
            return el.type === 'password' && !el.disabled && !hasRole(el, 'one-time-code') && shown(el) &&
              (capture || passwordPurpose(el) !== 'new');
          });
          var explicit = passwords.filter(function (el) { return passwordPurpose(el) === (capture ? 'new' : 'current'); });
          if (!capture && !explicit.length && inputs.some(function (el) { return el.type === 'password' && passwordPurpose(el) === 'new'; })) return null;
          var pw = explicit[0];
          if (capture) {
            // A submitted password change saves the new value, never the old one.
            // Multiple new-password fields are confirmations and must agree.
            if (explicit.length && explicit.some(function (el) { return el.value !== pw.value; })) return null;
            if (!pw && passwords.length === 1) pw = passwords[0];
            if (!pw && passwords.length > 1) {
              var news = passwords.length === 3 ? passwords.slice(1) : passwords;
              if (passwords.length > 3 || news.some(function (el) { return !el.value || el.value !== news[0].value; })) return null;
              pw = news[0];
            }
          } else {
            // Several unlabelled passwords may be signup/change fields. Never guess.
            if (explicit.length > 1) return null;
            if (!pw && passwords.length === 1) pw = passwords[0];
            if (!pw && passwords.length > 1) return null;
          }
          if (!capture && !pw && inputs.some(function (el) { return hasRole(el, 'new-password'); })) return null;
          if (pw && root === document) {
            var scope = rootFor(pw);
            if (scope !== document) return pair(scope, capture);
            inputs = inputs.filter(function (el) { return rootFor(el) === document; });
          }
          var user, before = pw ? inputs.slice(0, inputs.indexOf(pw)).reverse() : inputs;
          user = before.find(function (el) { return hasRole(el, 'username') && !hasRole(el, 'one-time-code') &&
              (['text', 'email', 'tel'].includes(el.type) || (capture && el.type === 'hidden')); });
          if (!user && (!pw || root !== document)) {
            user = inputs.find(function (el) { return hasRole(el, 'username') && !hasRole(el, 'one-time-code') &&
              (['text', 'email', 'tel'].includes(el.type) || (capture && el.type === 'hidden')); });
          }
          if (!user && pw) user = before.find(function (el) { return usernameInput(el); });
          if (!pw && !user) {
            user = inputs.find(function (el) {
              return usernameInput(el) && (el.type === 'email' || /user|login|email|account/i.test(el.name + ' ' + el.id));
            });
          }
          if (!pw && !user) return null;
          var result = { user: user, pass: pw };
          if (!user) result.linkedUser = linkedStepUser(result);
          return result;
        }
        var lastPair = null, lastCapturePair = null, usernameStep = null;
        var selectedAccounts = new WeakMap();
        function rememberStep(p) {
          if (!p || !p.user) return;
          var root = p.user.form || p.user;
          if (!p.user.value) {
            if (usernameStep && (usernameStep.field === p.user || usernameStep.root === root)) usernameStep = null;
            return;
          }
          usernameStep = { field: p.user, account: p.user.value, root: root,
            parent: root.parentNode, before: root.previousSibling, after: root.nextSibling, at: Date.now() };
        }
        function linkedStepUser(p) {
          var step = usernameStep, pass = p && p.pass;
          if (!step || !pass || Date.now() - step.at > 120000) return null;
          var refs = (pass.getAttribute('aria-labelledby') || '').trim().split(/\\s+/);
          var user = step.field, tree = pass.getRootNode();
          if (refs.length !== 1 || !user.id || refs[0] !== user.id || user.getRootNode() !== tree ||
              !user.isConnected || user.value !== step.account || !hasRole(user, 'username') ||
              (!user.readOnly && shown(user)) || !safeRoot(rootFor(user))) return null;
          var identified = tree.querySelectorAll('[id]');
          if (identified.length > 20000) return null;
          var matches = Array.from(identified).filter(function (el) { return el.id === refs[0]; });
          return matches.length === 1 && matches[0] === user ? user : null;
        }
        function carriedAccount(p) {
          var linked = linkedStepUser(p);
          if (linked) return linked.value;
          if (selectedAccounts.has(p.pass)) return selectedAccounts.get(p.pass);
          var step = usernameStep, root = p.pass.form || p.pass;
          if (!step || (step.field.isConnected && step.field !== p.pass)) return '';
          if (root === step.root || (!step.root.isConnected && root.parentNode === step.parent &&
              root.previousSibling === step.before && root.nextSibling === step.after)) return step.field === p.pass ? step.account : step.field.value;
          return '';
        }
        function pairFor(el, capture) {
          if (!el || el.tagName !== 'INPUT') { return null; }
          var p = pair(rootFor(el), capture);
          return p && (el === p.user || el === p.pass) ? p : null;
        }
        var lastGeneration = null;
        function generationFor(el) {
          if (!el || el.tagName !== 'INPUT' || el.type !== 'password' || !usableInput(el)) return null;
          var root = rootFor(el);
          if (!safeRoot(root)) return null;
          var all = inputsFor(root).filter(function (f) { return f.type === 'password' && usableInput(f); });
          // Require autocomplete or an explicit new/confirmation name. Two unlabelled
          // passwords could be current + new; generation must never overwrite both.
          var news = all.filter(function (f) { return passwordPurpose(f) === 'new'; });
          if (!news.includes(el) || news.length > 2) return null;
          return { root: root, fields: news, field: el };
        }
        function generationToken(g) {
          return g && documentID + ':new:' + g.fields.map(fieldID).join(':');
        }
        function generate(password, target) {
          var g = generationFor(deepActive(document)) || (lastGeneration && generationFor(lastGeneration.field));
          if (!g || !target || generationToken(g) !== target || !liveDocument() ||
              g.fields.some(function (f) { return f.maxLength >= 0 && password.length > f.maxLength; })) return false;
          if (!focusedFrame()) return false;
          for (var i = 0; i < g.fields.length; i++) {
            var current = generationFor(g.field), field = g.fields[i];
            if (!liveDocument() || !focusedFrame() || !current || generationToken(current) !== target ||
                !usableInput(field) || !safeRoot(g.root) || rootFor(field) !== g.root || !current.fields.includes(field)) return false;
            setValue(field, password);
          }
          return true;
        }
        function visible(p) {
          var field = p && (p.pass || p.user);
          return field && liveDocument() && shown(field);
        }
        function targetPair(capture) {
          var active = deepActive(document);
          var focused = pairFor(active, capture);
          // Focusing a different input is not permission to fill a cached login.
          if (active && active.tagName === 'INPUT' && !focused) return null;
          if (visible(focused)) { return focused; }
          // A SPA can replace the username alone. Re-pair from the cached password node
          // so a connected password never carries a detached username into a fill.
          var cached = capture ? lastCapturePair : lastPair;
          var recent = cached && pairFor(cached.pass || cached.user, capture);
          if (visible(recent)) { return recent; }
          var usernameStep = null;
          var scopes = Array.from(new Set(deepQuery(document, 'input').map(rootFor)));
          if (!scopes.length) return null;
          for (var i = 0; i < scopes.length; i++) {
            if (scopes[i] === document) continue;
            var candidate = pair(scopes[i], capture);
            if (!visible(candidate)) continue;
            if (candidate.pass) return candidate;
            if (!usernameStep) usernameStep = candidate;
          }
          var ungrouped = pair(document, capture);
          if (visible(ungrouped) && ungrouped.pass) return ungrouped;
          return usernameStep || (visible(ungrouped) ? ungrouped : null);
        }
        // Where a chooser should hang: under the username field, its width, in CSS pixels
        // relative to the viewport — which is exactly what the web view is showing.
        function anchor(proposed) {
          var p = proposed || targetPair();
          if (!p) { return null; }
          var field = deepActive(document);
          if (field !== p.user && field !== p.pass) field = p.user || p.pass;
          var r = field.getBoundingClientRect();
          var x = r.left, y = r.bottom, width = r.width, child = window;
          while (child !== topWindow) {
            var frame = child.frameElement, fr = frame.getBoundingClientRect();
            var sx = fr.width / frame.offsetWidth, sy = fr.height / frame.offsetHeight;
            // A rotated/skewed frame has no safe axis-aligned field anchor.
            var transform = frame.ownerDocument.defaultView.getComputedStyle(frame).transform;
            if (transform !== 'none') {
              var matrix = new topWindow.DOMMatrixReadOnly(transform);
              if (!matrix.is2D || matrix.b !== 0 || matrix.c !== 0 || matrix.a <= 0 || matrix.d <= 0) return null;
            }
            x = fr.left + (frame.clientLeft + x) * sx;
            y = fr.top + (frame.clientTop + y) * sy;
            width *= sx;
            child = child.parent;
          }
          var identity = targetPair(true);
          return { x: x, y: y, w: width, target: token(p),
            accountHint: identity && identity.user ? identity.user.value : (p.pass ? carriedAccount(p) : '') };
        }
        var listOpen = false;
        function send(m) {
          if (!liveDocument()) return;
          // An embedded form needs explicit focus; discovery alone cannot choose a frame.
          if (m.ready && window !== topWindow && !document.hasFocus()) return;
          if (m.focus || m.ready) {
            m.target = token(targetPair());
            var p = targetPair(true);
            m.accountHint = p && p.user ? p.user.value : (p && p.pass ? carriedAccount(p) : '');
            m.mainDocument = window === topWindow;
            // Hidden/read-only account identities validate the choice; they are not
            // editable username steps and must never be overwritten.
            m.passwordOnly = !!p && !!p.pass && (!p.user || !usableInput(p.user));
          }
          if (m.focus) recentContext = context;
          if (m.focus || m.generate) listOpen = true;
          if (m.dismiss) listOpen = false;
          topWindow.webkit.messageHandlers.vanepw.postMessage(m);
        }
        function ours(el) { return !!pairFor(el) || !!generationFor(el); }
        // Chromium drops its list of saved accounts under the username field the moment you
        // focus it, and Arc inherits that. Capture phase throughout: a site that stops these
        // events from bubbling must not also stop the browser's own chrome from appearing —
        // or, worse, from going away again.
        function focused(el) {
          var captured = pairFor(el, true);
          if (captured) lastCapturePair = captured;
          var g = generationFor(el);
          if (g) {
            lastGeneration = g;
            var ga = anchor({ pass: el });
            if (ga) send({ generate: true, target: generationToken(g), x: ga.x, y: ga.y, w: ga.w });
            return;
          }
          var p = pairFor(el);
          if (!p) { return; }
          lastPair = p;
          var a = anchor();
          if (a) { send({ focus: true, x: a.x, y: a.y, w: a.w }); }
        }
        function eventField(e) {
          return e.composedPath().find(function (node) { return node.nodeType === 1; }) || e.target;
        }
        function credentialListener(name, fn) {
          var handled = new WeakSet();
          var handler = function (e) {
            if (!attachedDocument()) return;
            if (handled.has(e)) return;
            handled.add(e);
            var field = eventField(e), tree = field.getRootNode && field.getRootNode();
            // Focus/click can arrive before the paced attachShadow scan. Admit its
            // public roots now so an immediate local submit/input is not missed.
            if (rootTimer !== null && tree && tree.host && !shadowListeners.has(tree)) discoverRoots();
            fn(e);
          };
          credentialListeners.push([name, handler]);
          listen(document, name, handler, true);
          return handler;
        }
        credentialListener('focusin', function (e) { focused(eventField(e)); });
        credentialListener('click', function (e) { focused(eventField(e)); });
        // Everything that means "not interested any more". The list is anchored to a point
        // that stops being true the moment any of these happens, so each one closes it.
        credentialListener('focusout', function (e) {
          if (ours(eventField(e))) { send({ dismiss: 'blur' }); }
        });
        credentialListener('pointerdown', function (e) {
          if (!ours(eventField(e))) { send({ dismiss: 'click' }); }
        });
        // Only while the list is actually up. A scroll handler that posts on every wheel
        // event of every page, forever, is a message per frame for a list that is not there.
        listen(window, 'scroll', credentialListener('scroll', function () {
          if (listOpen) { send({ dismiss: 'scroll' }); }
        }), true);
        // A single-page app changes the form under us without a navigation.
        listen(window, 'popstate', function () { send({ dismiss: 'navigate' }); });
        var submittedAttempt = null;
        function replacesSubmitted(form) {
          var a = submittedAttempt;
          return a && form && !a.form.isConnected && a.formsAtSubmit.indexOf(form) < 0
            && form.parentNode === a.parent && form.previousSibling === a.before
            && form.nextSibling === a.after;
        }
        var attemptSerial = 0, lastOffered = null, lastOfferID = null;
        function offer(p) {
          if (!p) return;
          if (!p.pass) {
            if (p.user && usableInput(p.user) && p.user.value &&
                (hasRole(p.user, 'username') || /user|login|account/i.test(p.user.name + ' ' + p.user.id))) {
              rememberStep(p);
              send({ usernameStep: p.user.value, target: token(p), mainDocument: window === topWindow });
            }
            return;
          }
          if (!p.pass.value) return;
          var account = p.user ? p.user.value : carriedAccount(p);
          var signature = token(p) + '\\n' + account + '\\n' + p.pass.value;
          if (lastOffered === signature) return;
          lastOffered = signature;
          lastOfferID = documentID + ':' + (++attemptSerial);
          send({ account: account, password: p.pass.value, attempt: lastOfferID,
            mainDocument: window === topWindow });
        }
        credentialListener('submit', function (e) {
          var form = eventField(e);
          if (!form || form.tagName !== 'FORM' || !safeRoot(form)) return;
          submittedAttempt = {
            form: form, parent: form.parentNode,
            before: form.previousSibling, after: form.nextSibling,
            formsAtSubmit: deepQuery(document, 'form'), retry: null
          };
          offer(pair(eventField(e), true));
        });
        // A failed sign-in can leave the page in place. An edited field starts a new attempt.
        credentialListener('input', function (e) {
          var p = pairFor(eventField(e));
          if (p) {
            if (e.isTrusted) send({ dismiss: 'input' });
            if (p.pass && eventField(e) === p.user) selectedAccounts.delete(p.pass);
            rememberStep(p);
          }
          if (pairFor(eventField(e), true)) lastOffered = null;
          if (!submittedAttempt || !pairFor(eventField(e), true)) { return; }
          var form = eventField(e).form;
          if (form === submittedAttempt.form) { submittedAttempt = null; return; }
          // Only a newly created form in the submitted form's old slot is its retry.
          // Editing any other login form leaves the submitted offer in charge.
          submittedAttempt.retry = replacesSubmitted(form) ? form : null;
        });
        // Leaving a page is not a login attempt. For fetch-based forms, capture only
        // after a trusted submit-control activation or Enter in a credential field.
        var activated = null;
        credentialListener('click', function (e) {
          if (!e.isTrusted) return;
          var button = eventField(e).closest && eventField(e).closest('button,input[type="submit"]');
          if (!button || !button.form || button.type !== 'submit') return;
          activated = { form: button.form, at: Date.now() };
        });
        credentialListener('keydown', function (e) {
          if (e.isTrusted && e.key === 'Enter' && pairFor(eventField(e), true))
            activated = { form: eventField(e).form, at: Date.now() };
        });
        listen(window, 'pagehide', function () {
          if (!submittedAttempt && activated && activated.form && Date.now() - activated.at < 10000)
            offer(pair(activated.form, true));
          else if (submittedAttempt && replacesSubmitted(submittedAttempt.retry))
            offer(pair(submittedAttempt.retry, true));
          pauseDiscovery();
        });
        listen(window, 'pageshow', function () {
          if (retired || !attachedDocument()) return;
          discoverFrames(observe()); ready();
        });
        function fill(account, password, automatic, target, continuation) {
          var p = targetPair();
          if (!visible(p) || (target && token(p) !== target)) { return false; }
          if (!focusedFrame()) return false;
          // Read-only/hidden account hints are useful for validation, never for writing.
          var identity = pair(rootFor(p.pass || p.user), true);
          if (identity && identity.user && identity.user !== p.user) {
            if (identity.user.value && identity.user.value !== account) return false;
            if (!usableInput(identity.user)) p.user = null;
          }
          if (!p.pass && !p.user) return false;
          if (automatic && [p.user, p.pass, rootFor(p.pass || p.user)].some(function (el) {
              return el && hasRole(el, 'off');
          })) return false;
          var carried = p.pass && !p.user && !(identity && identity.user && identity.user.value) ? carriedAccount(p) : '';
          if (carried && carried !== account) return false;
          if (continuation && (!p.pass || p.user || carried)) return false;
          if (automatic && !p.pass && !hasRole(p.user, 'username') &&
              !/user|login|account/i.test(p.user.name + ' ' + p.user.id)) return false;
          if (automatic && ((p.user && p.user.value && p.user.value !== account) ||
                            (p.pass && p.pass.value))) return false;
          var root = rootFor(p.pass || p.user), expectedTarget = token(p);
          if (p.user && account) setValue(p.user, account);
          rememberStep(p);
          // Site input handlers can replace, hide, or reclassify fields synchronously.
          // Revalidate after the username events before handing over the secret.
          if (p.pass) {
            if (!liveDocument() || !focusedFrame() || !safeRoot(root) || !usableInput(p.pass) || passwordPurpose(p.pass) === 'new' ||
                rootFor(p.pass) !== root || token(targetPair()) !== expectedTarget ||
                (p.user && p.user.value !== account)) return false;
            var current = pairFor(p.pass), currentIdentity = pair(root, true);
            if (!current || token(current) !== expectedTarget) return false;
            var hint = currentIdentity && currentIdentity.user;
            if (hint && hint.value && hint.value !== account) return false;
            if (current.user && (!hint || usableInput(hint)) && current.user.value !== account) return false;
            if (!current.user) selectedAccounts.set(p.pass, account);
            setValue(p.pass, password);
          }
          return true;   // never auto-submit
        }
        // DOMContentLoaded precedes slow images/iframes. Newly mounted SPA forms get the
        // same notification. Mutation callbacks only schedule work: searching each added
        // subtree here competes with the framework's page construction in its microtasks.
        // One discovery pass after a burst also avoids searching nested additions twice.
        function rejectFailedAttempt() {
          if (!lastOfferID || !submittedAttempt || !submittedAttempt.form.isConnected) return;
          var form = submittedAttempt.form;
          var invalid = deepQuery(form, 'input[aria-invalid="true"],[role="alert"]').some(function (el) {
            return shown(el) && (el.tagName === 'INPUT' ? (el.type === 'password' || usernameInput(el)) : el.textContent.trim());
          });
          if (invalid) { send({ rejectedAttempt: lastOfferID }); lastOfferID = null; }
        }
        var seen = new WeakMap(), pending = false;
        function ready() {
          var p = targetPair(), field = p && (p.pass || p.user);
          if (!field || seen.get(field) === token(p)) return;
          seen.set(field, token(p));
          send({ ready: true });
          if (ours(deepActive(document))) focused(deepActive(document));
        }
        var context = { window: window, fill: fill, anchor: anchor, pair: targetPair, token: token, live: liveDocument, attached: attachedDocument, ready: ready, dispose: dispose,
          generate: generate, generation: function () { return generationToken(lastGeneration && generationFor(lastGeneration.field)); } };
        contexts.set(document, context);
        function discoverFrames(elements) {
          // Admit the actual WindowProxy before reading any protected properties,
          // including for redirects and CSP sandboxing absent from iframe attributes.
          // Root discovery already admitted these elements, including shadow frames.
          // A standalone frame-load event takes its own bounded snapshot.
          (elements || deepQuery(document, '*')).forEach(function (frame) {
            var name = frame.localName;
            if (name !== 'iframe' && name !== 'frame') return;
            try { install(frame.contentWindow); } catch (_) {}
          });
          // Remove navigated/detached documents rather than retaining their DOM and accounts.
          contexts.forEach(function (ctx, doc) { if (!ctx.attached()) { ctx.dispose(); contexts.delete(doc); if (recentContext === ctx) recentContext = null; } });
        }
        listen(document, 'load', function (e) {
          if (e.target.tagName === 'IFRAME' || e.target.tagName === 'FRAME') discoverFrames();
        }, true);
        observer = new MutationObserver(function (records) {
          if (pending || !records.some(function (r) {
            return r.type === 'attributes' || (lastOfferID && (r.type === 'characterData' || r.addedNodes.length)) || r.removedNodes.length || Array.from(r.addedNodes).some(function (n) {
              return n.nodeType === 1;
            });
          })) return;
          pending = true;
          discoveryTimer = setTimeout(function () {
            discoveryTimer = null; pending = false;
            if (!attachedDocument()) { dispose(); return; }
            discoverFrames(discoverRoots());
            rejectFailedAttempt();
            var cached = lastPair;
            if (listOpen && !(lastGeneration && generationFor(lastGeneration.field)) &&
                (!visible(cached) || token(targetPair()) !== token(cached))) send({ dismiss: 'navigate' });
            ready();
          }, 80);
        });
        var observation = { childList: true, subtree: true, attributes: true, characterData: true,
          attributeFilter: ['type', 'autocomplete', 'name', 'id', 'disabled', 'readonly', 'hidden', 'style', 'class', 'inert',
            'aria-hidden', 'aria-invalid', 'aria-labelledby', 'role', 'slot', 'form', 'action', 'formaction'] };
        function discoverRoots() {
          var elements = deepQuery(document, '*');
          var roots = new Set(elements.filter(function (el) { return el.shadowRoot; })
            .map(function (el) { return el.shadowRoot; }));
          // Disconnect first to stop observing detached trees; then re-admit only live roots.
          observer.disconnect();
          observer.observe(document.documentElement, observation);
          shadowListeners.forEach(function (entries, root) {
            if (roots.has(root)) return;
            entries.forEach(function (entry) { root.removeEventListener(entry[0], entry[1], true); });
            shadowListeners.delete(root);
          });
          roots.forEach(function (root) {
            observer.observe(root, observation);
            if (shadowListeners.has(root)) return;
            credentialListeners.forEach(function (entry) { root.addEventListener(entry[0], entry[1], true); });
            shadowListeners.set(root, credentialListeners.slice());
          });
          return elements;
        }
        function observe() {
          var elements = discoverRoots();
          // attachShadow on an already-connected host is invisible to MutationObserver
          // in an isolated world. A single paced scan covers that case without page hooks.
          if (rootTimer === null) rootTimer = setInterval(function () {
            if (!attachedDocument()) { dispose(); return; }
            discoverFrames(discoverRoots()); ready();
          }, 1000);
          return elements;
        }
        discoverFrames(observe()); ready();
      }
      function currentContext(target) {
        if (target) {
          return Array.from(contexts.values()).find(function (ctx) {
            return ctx.live() && (ctx.token(ctx.pair()) === target || ctx.generation() === target);
          });
        }
        if (!accessibleWindow(topWindow) || topWindow.origin !== topOrigin) return null;
        var doc = topWindow.document, active = deepActive(doc);
        try {
          while (active && (active.tagName === 'IFRAME' || active.tagName === 'FRAME')) {
            var child = active.contentWindow;
            if (!exactOriginWindow(child)) return null;
            doc = child.document;
            active = deepActive(doc);
          }
        } catch (_) { return null; }
        if (active && active.tagName === 'INPUT') return contexts.get(doc);
        return recentContext && recentContext.live() ? recentContext : contexts.get(doc);
      }
      topWindow.__vaneAnchor = function (target) {
        var ctx = currentContext(target);
        return JSON.stringify(ctx && ctx.live() ? ctx.anchor() : null);
      };
      topWindow.__vaneFill = function (account, password, automatic, target, continuation) {
        var ctx = currentContext(target);
        return !!ctx && ctx.fill(account, password, automatic, target, continuation);
      };
      topWindow.__vaneGenerate = function (password, target) {
        var ctx = currentContext(target);
        return !!ctx && ctx.generate(password, target);
      };
      install(topWindow);
    })();
    """

    static func anchorJS(target: String) -> String {
        let args = try! JSONSerialization.data(withJSONObject: [target])
        return "window.__vaneAnchor && window.__vaneAnchor.apply(null, \(String(decoding: args, as: UTF8.self)))"
    }

    static func generateJS(password: String, target: String) -> String {
        let args = try! JSONSerialization.data(withJSONObject: [password, target])
        return "window.__vaneGenerate && window.__vaneGenerate.apply(null, \(String(decoding: args, as: UTF8.self)))"
    }

    static func fillJS(account: String, password: String, automatic: Bool = false,
                       target: String? = nil, continuation: Bool = false) -> String {
        let args = try! JSONSerialization.data(withJSONObject: [account, password, automatic, target as Any? ?? NSNull(), continuation])
        return "window.__vaneFill && window.__vaneFill.apply(null, \(String(decoding: args, as: UTF8.self)))"
    }
}
