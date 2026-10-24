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
      var topWindow = window, contexts = new Map(), recentContext = null;
      function install(window) {
        var document;
        try {
          // document.domain can make another host or port DOM-accessible. Credentials
          // still require the exact serialized origin, including inherited srcdoc origins.
          if (window !== topWindow && (window.origin === 'null' || window.origin !== topWindow.origin)) return;
          document = window.document;
        } catch (_) { return; }
        if (!document) return;
        if (contexts.has(document)) { contexts.get(document).ready(); return; }
        var documentID = Array.from(topWindow.crypto.getRandomValues(new Uint32Array(4))).join('-'), fields = new WeakMap(), fieldSerial = 0;
        var retired = false, observer = null, discoveryTimer = null;
        var listeners = [];
        function listen(target, name, fn, capture) {
          target.addEventListener(name, fn, capture);
          listeners.push([target, name, fn, capture]);
        }
        function pauseDiscovery() {
          if (observer) observer.disconnect();
          if (discoveryTimer !== null) clearTimeout(discoveryTimer);
          discoveryTimer = null; pending = false;
        }
        function dispose() {
          retired = true; pauseDiscovery();
          listeners.forEach(function (l) { l[0].removeEventListener(l[1], l[2], l[3]); });
          listeners = [];
        }
        function attachedDocument() {
          if (retired) return false;
          try {
            if (window.document !== document || window.origin !== topWindow.origin) return false;
            var child = window;
            while (child !== topWindow) {
              if (child.origin === 'null' || child.origin !== topWindow.origin) return false;
              var frame = child.frameElement;
              if (!frame || !frame.isConnected || frame.contentDocument !== child.document) return false;
              child = child.parent;
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
          try {
            for (var child = window; child !== topWindow; child = child.parent)
              if (child.parent.document.activeElement !== child.frameElement) return false;
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
          return documentID + ':' + fieldID(field) + (p.pass ? ':password:' : ':username:') + fieldID(p.user);
        }
        // React and friends install their own value setter; assigning .value directly updates
        // the DOM but not the component state, and the site then submits an empty field.
        function setValue(el, v) {
          var d = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value');
          if (d && d.set) { d.set.call(el, v); } else { el.value = v; }
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
        }
        function shown(el) {
          var r = el.getBoundingClientRect(), style = el.ownerDocument.defaultView.getComputedStyle(el);
          for (var parent = el; parent; parent = parent.parentElement) {
            var ps = parent.ownerDocument.defaultView.getComputedStyle(parent);
            if (Number(ps.opacity) === 0 || ps.contentVisibility === 'hidden' || ps.clipPath !== 'none') return false;
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
        function rootFor(el) { return el.form || el.closest('[role="form"], fieldset') || document; }
        function safeRoot(root) {
          if (root.tagName !== 'FORM') return true;
          try {
            var action = new URL(root.getAttribute('action') || document.baseURI, document.baseURI);
            if (action.origin !== topWindow.origin || action.protocol !== 'https:') return false;
            return Array.from(root.elements).filter(function (el) { return el.hasAttribute('formaction'); }).every(function (button) {
              var override = new URL(button.getAttribute('formaction') || document.baseURI, document.baseURI);
              return override.origin === topWindow.origin && override.protocol === 'https:';
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
          var inputs = Array.from(root.tagName === 'FORM' ? root.elements : root.querySelectorAll('input'))
            .filter(function (el) { return el.tagName === 'INPUT'; });
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
          if (!user && (!pw || pw.form)) {
            user = inputs.find(function (el) { return hasRole(el, 'username') && !hasRole(el, 'one-time-code') &&
              (['text', 'email', 'tel'].includes(el.type) || (capture && el.type === 'hidden')); });
          }
          if (!user && pw) user = before.find(function (el) { return usernameInput(el); });
          if (!pw && !user) {
            user = inputs.find(function (el) {
              return usernameInput(el) && (el.type === 'email' || /user|login|email|account/i.test(el.name + ' ' + el.id));
            });
          }
          return pw || user ? { user: user, pass: pw } : null;
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
            parent: root.parentNode, before: root.previousSibling, after: root.nextSibling };
        }
        function carriedAccount(p) {
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
          var all = Array.from(root.tagName === 'FORM' ? root.elements : root.querySelectorAll('input'))
            .filter(function (f) { return f.tagName === 'INPUT' && f.type === 'password' && usableInput(f); });
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
          var g = generationFor(document.activeElement) || (lastGeneration && generationFor(lastGeneration.field));
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
          var active = document.activeElement;
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
          for (var i = 0; i < document.forms.length; i++) {
            var candidate = pair(document.forms[i], capture);
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
          var field = document.activeElement;
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
        listen(document, 'focusin', function (e) { focused(e.target); }, true);
        listen(document, 'click', function (e) { focused(e.target); }, true);
        // Everything that means "not interested any more". The list is anchored to a point
        // that stops being true the moment any of these happens, so each one closes it.
        listen(document, 'focusout', function (e) {
          if (ours(e.target)) { send({ dismiss: 'blur' }); }
        }, true);
        listen(document, 'pointerdown', function (e) {
          if (!ours(e.target)) { send({ dismiss: 'click' }); }
        }, true);
        // Only while the list is actually up. A scroll handler that posts on every wheel
        // event of every page, forever, is a message per frame for a list that is not there.
        listen(window, 'scroll', function () {
          if (listOpen) { send({ dismiss: 'scroll' }); }
        }, true);
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
        listen(document, 'submit', function (e) {
          var form = e.target;
          if (!form || form.tagName !== 'FORM' || !safeRoot(form)) return;
          submittedAttempt = {
            form: form, parent: form.parentNode,
            before: form.previousSibling, after: form.nextSibling,
            formsAtSubmit: Array.prototype.slice.call(document.forms), retry: null
          };
          offer(pair(e.target, true));
        }, true);
        // A failed sign-in can leave the page in place. An edited field starts a new attempt.
        listen(document, 'input', function (e) {
          var p = pairFor(e.target);
          if (p) {
            if (e.isTrusted) send({ dismiss: 'input' });
            if (p.pass && e.target === p.user) selectedAccounts.delete(p.pass);
            rememberStep(p);
          }
          if (pairFor(e.target, true)) lastOffered = null;
          if (!submittedAttempt || !pairFor(e.target, true)) { return; }
          var form = e.target.form;
          if (form === submittedAttempt.form) { submittedAttempt = null; return; }
          // Only a newly created form in the submitted form's old slot is its retry.
          // Editing any other login form leaves the submitted offer in charge.
          submittedAttempt.retry = replacesSubmitted(form) ? form : null;
        }, true);
        // Leaving a page is not a login attempt. For fetch-based forms, capture only
        // after a trusted submit-control activation or Enter in a credential field.
        var activated = null;
        listen(document, 'click', function (e) {
          if (!e.isTrusted) return;
          var button = e.target.closest && e.target.closest('button,input[type="submit"]');
          if (!button || !button.form || button.type !== 'submit') return;
          activated = { form: button.form, at: Date.now() };
        }, true);
        listen(document, 'keydown', function (e) {
          if (e.isTrusted && e.key === 'Enter' && pairFor(e.target, true))
            activated = { form: e.target.form, at: Date.now() };
        }, true);
        listen(window, 'pagehide', function () {
          if (!submittedAttempt && activated && activated.form && Date.now() - activated.at < 10000)
            offer(pair(activated.form, true));
          else if (submittedAttempt && replacesSubmitted(submittedAttempt.retry))
            offer(pair(submittedAttempt.retry, true));
          pauseDiscovery();
        });
        listen(window, 'pageshow', function () {
          if (retired || !attachedDocument()) return;
          observe(); discoverFrames(); ready();
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
          var invalid = Array.from(form.querySelectorAll('input[aria-invalid="true"],[role="alert"]')).some(function (el) {
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
          if (ours(document.activeElement)) focused(document.activeElement);
        }
        var context = { window: window, fill: fill, anchor: anchor, pair: targetPair, token: token, live: liveDocument, attached: attachedDocument, ready: ready, dispose: dispose,
          generate: generate, generation: function () { return generationToken(lastGeneration && generationFor(lastGeneration.field)); } };
        contexts.set(document, context);
        function discoverFrames() {
          // Access itself enforces the origin boundary, including opaque sandbox origins.
          Array.from(document.getElementsByTagName('iframe')).concat(Array.from(document.getElementsByTagName('frame'))).forEach(function (frame) {
            try { if (frame.contentDocument) install(frame.contentWindow); } catch (_) {}
          });
          // Remove navigated/detached documents rather than retaining their DOM and accounts.
          contexts.forEach(function (ctx, doc) { if (!ctx.attached()) { ctx.dispose(); contexts.delete(doc); if (recentContext === ctx) recentContext = null; } });
        }
        listen(document, 'load', function (e) {
          if (e.target.tagName === 'IFRAME' || e.target.tagName === 'FRAME') discoverFrames();
        }, true);
        discoverFrames();
        ready();
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
            discoverFrames();
            rejectFailedAttempt();
            var cached = lastPair;
            if (listOpen && !(lastGeneration && generationFor(lastGeneration.field)) &&
                (!visible(cached) || token(targetPair()) !== token(cached))) send({ dismiss: 'navigate' });
            ready();
          }, 80);
        });
        function observe() {
          observer.observe(document.documentElement, { childList: true, subtree: true, attributes: true, characterData: true,
            attributeFilter: ['type', 'autocomplete', 'name', 'id', 'disabled', 'readonly', 'hidden', 'style', 'class', 'inert', 'aria-invalid', 'role'] });
        }
        observe();
      }
      function currentContext(target) {
        if (target) {
          return Array.from(contexts.values()).find(function (ctx) {
            return ctx.live() && (ctx.token(ctx.pair()) === target || ctx.generation() === target);
          });
        }
        var doc = topWindow.document, active = doc.activeElement;
        try {
          while (active && (active.tagName === 'IFRAME' || active.tagName === 'FRAME')) {
            if (!active.contentDocument) return null;
            doc = active.contentDocument;
            active = doc.activeElement;
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
