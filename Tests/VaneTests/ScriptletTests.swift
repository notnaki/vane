import JavaScriptCore
import XCTest
@testable import vane

/// Windowless: parsing is pure, and the library runs in a bare JSContext with small stubs
/// for the browser globals it touches. DOM scriptlets are covered by BlockerWebKitTests.
final class ScriptletTests: XCTestCase {
    func testParsesHostsEntitiesExceptionsAndArguments() {
        XCTAssertEqual(Scriptlets.parse("Example.com,~sub.example.com##+js(set, a.b, true)"),
                       .rule(.init(include: ["example.com"], exclude: ["sub.example.com"], call: ["set-constant", "a.b", "true"], exception: false)))
        XCTAssertEqual(Scriptlets.parse("google.*##+js(aopr.js, x)"),
                       .rule(.init(include: ["google.*"], exclude: [], call: ["abort-on-property-read", "x"], exception: false)))
        XCTAssertEqual(Scriptlets.parse("##+js(nowoif)"),
                       .rule(.init(include: [], exclude: [], call: ["window.open-defuser"], exception: false)))
        XCTAssertEqual(Scriptlets.parse("example.com#@#+js()"),
                       .rule(.init(include: ["example.com"], exclude: [], call: nil, exception: true)))
        XCTAssertEqual(Scriptlets.parse("example.com#@#+js(nostif, ad)"),
                       .rule(.init(include: ["example.com"], exclude: [], call: ["no-setTimeout-if", "ad"], exception: true)))
        XCTAssertEqual(Scriptlets.arguments(#"nostif, a\,b, '1, 2', /\d+/"#), ["nostif", "a,b", "1, 2", #"/\d+/"#])
        XCTAssertEqual(Scriptlets.parse("example.com##+js(trusted-replace-fetch-response, a, b)"), .unsupported("Unsupported scriptlet"))
        XCTAssertEqual(Scriptlets.parse("example.com##+js(foo)"), .unsupported("Unsupported scriptlet"))
        XCTAssertEqual(Scriptlets.parse("/example\\.com/##+js(set, a, 1)"), .unsupported("Scriptlet with unsupported hostnames"))
        XCTAssertEqual(Scriptlets.parse("#@#+js(set, a, 1)"), .unsupported("Generic or negated scriptlet exception"))
        XCTAssertEqual(Scriptlets.parse("example.com##+js()"), .unsupported("Unsupported scriptlet"))
        XCTAssertNil(Scriptlets.parse("example.com##.ad"))
    }

    func testConversionCountsSupportedAndUnsupportedScriptlets() {
        let result = Blocker.convert("||ads.example^\nexample.com##+js(set, a, true)\nexample.com##+js(foo)\n!#if ext_ublock\nexample.com##+js(set, b, 1)\n!#endif")
        XCTAssertEqual(result.rules, 2)
        XCTAssertEqual(result.skipped, 2)
        XCTAssertEqual(result.reasonCounts["Unsupported scriptlet"], 1)
        XCTAssertEqual(result.reasonCounts["Conditional rule"], 1)
        XCTAssertTrue(result.scriptlets.contains("\nexample.com\t"))
        XCTAssertEqual(Blocker.convert("||ads.example^").scriptlets, "")
        XCTAssertNil(Scriptlets.source(table: "", siteExceptions: []))
    }

    // MARK: - Library

    private let stubs = #"""
    var window = globalThis;
    var log = [];
    function setTimeout(cb, ms) { log.push(['timeout', typeof cb === 'function' ? cb.toString() : cb, ms]); return 1; }
    function setInterval(cb, ms) { log.push(['interval', typeof cb === 'function' ? cb.toString() : cb, ms]); return 2; }
    function open(url) { return 'opened ' + url; }
    class EventTarget { addEventListener(type, fn) { log.push(['listen', type]); } }
    var target = new EventTarget();
    class Headers { constructor(h) { this.m = {}; } delete(k) {} }
    class Response {
      constructor(body, init) { this.body = body; this.status = init.status; this.statusText = init.statusText; this.headers = new Headers(); }
      clone() { return this; }
      text() { return Promise.resolve(this.body); }
      json() { return Promise.resolve(JSON.parse(this.body)); }
    }
    var served = '{"ok":1,"adPlacements":[1]}';
    function fetch(url) { return Promise.resolve(new Response(served, { status: 200, statusText: 'OK' })); }
    class HTMLScriptElement {}
    var document = { currentScript: null };
    function URL(u) { this.hostname = u.replace(/^[a-z]+:\/\//, '').split(/[\/:]/)[0]; }
    var originalToString = setTimeout.toString(), nativeToString = Function.prototype.toString.toString();
    """#

    private func context(_ filters: String, host: String = "example.com", top: String? = nil,
                         siteExceptions: [String] = []) throws -> JSContext {
        let table = Blocker.convert(filters).scriptlets
        let source = try XCTUnwrap(Scriptlets.source(table: table, siteExceptions: siteExceptions))
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, error in XCTFail("JS: \(error?.toString() ?? "")") }
        context.evaluateScript(stubs)
        let ancestors = top.map { "['https://\($0)']" } ?? "[]"
        context.evaluateScript("var location = { hostname: '\(host)', ancestorOrigins: \(ancestors) };")
        context.evaluateScript(source)
        return context
    }

    private func eval(_ context: JSContext, _ script: String) -> JSValue {
        context.exceptionHandler = nil
        return context.evaluateScript(script)
    }

    func testHostnameMatchingCoversSubdomainsEntitiesAndGenericFilters() throws {
        let filters = "example.com##+js(set, hit, true)\ngoogle.*##+js(set, entity, 1)\n##+js(set, generic, 2)"
        XCTAssertTrue(eval(try context(filters, host: "www.example.com"), "window.hit === true && window.generic === 2").toBool())
        XCTAssertTrue(eval(try context(filters, host: "notexample.com"), "window.hit").isUndefined)
        XCTAssertEqual(eval(try context(filters, host: "www.google.co.uk"), "window.entity").toInt32(), 1)
        XCTAssertTrue(eval(try context(filters, host: "google"), "window.entity").isUndefined)
        // Every bucket: the page script's hash must agree with the Swift one.
        let many = (0..<300).map { "site\($0).test##+js(set, v\($0), \($0))" }.joined(separator: "\n")
        for i in [0, 1, 77, 150, 299] {
            XCTAssertEqual(eval(try context(many, host: "www.site\(i).test"), "window.v\(i)").toInt32(), Int32(i))
        }
    }

    func testExceptionsNegationsAndSiteExceptionsDisableScriptlets() throws {
        let filters = "example.com,~skip.example.com##+js(set, a, true)\nexample.com##+js(set, b, true)\n"
            + "off.example.com#@#+js(set-constant, b, true)\nnone.example.com#@#+js()"
        XCTAssertEqual(eval(try context(filters), "[window.a, window.b]").toArray() as? [Bool], [true, true])
        XCTAssertEqual(eval(try context(filters, host: "skip.example.com"), "[window.a === undefined, window.b]").toArray() as? [Bool], [true, true])
        XCTAssertEqual(eval(try context(filters, host: "off.example.com"), "[window.a, window.b === undefined]").toArray() as? [Bool], [true, true])
        XCTAssertTrue(eval(try context(filters, host: "none.example.com"), "window.a === undefined && window.b === undefined").toBool())
        XCTAssertTrue(eval(try context(filters, siteExceptions: ["example.com"]), "window.a === undefined").toBool())
        // A frame follows the top-level page's site exception, like the content rules.
        XCTAssertTrue(eval(try context(filters, top: "allowed.test", siteExceptions: ["allowed.test"]), "window.a === undefined").toBool())
        XCTAssertTrue(eval(try context(filters, top: "other.test", siteExceptions: ["allowed.test"]), "window.a").toBool())
    }

    func testSetConstantTrapsChainsAndStepsBackForOtherTypes() throws {
        let c = try context("example.com##+js(set, ytcfg.ads.on, false)\nexample.com##+js(set, flag, true)\nexample.com##+js(set, fn, noopFunc)")
        XCTAssertFalse(eval(c, "window.ytcfg = { ads: { on: true } }; ytcfg.ads.on").toBool())
        XCTAssertTrue(eval(c, "window.flag = false; flag").toBool())
        XCTAssertEqual(eval(c, "window.flag = 'page'; flag").toString(), "page")
        XCTAssertTrue(eval(c, "typeof fn === 'function' && fn() === undefined").toBool())
    }

    func testAbortScriptletsThrowOnTheirTrigger() throws {
        let c = try context("example.com##+js(aopr, ads.read)\nexample.com##+js(aopw, written)\nexample.com##+js(acs, guarded, adblock)")
        XCTAssertTrue(eval(c, "window.ads = {}; try { ads.read; false } catch (e) { e instanceof ReferenceError }").toBool())
        XCTAssertTrue(eval(c, "try { window.written = 1; false } catch (e) { e instanceof ReferenceError }").toBool())
        XCTAssertTrue(eval(c, "window.guarded = 5; guarded === 5").toBool())
        XCTAssertTrue(eval(c, """
            const s = new HTMLScriptElement(); s.src = ''; s.text = 'detect adblock';
            document.currentScript = s;
            let thrown; try { guarded; thrown = false } catch (e) { thrown = true }
            s.text = 'harmless'; thrown && guarded === 5
            """).toBool())
    }

    func testTimerListenerAndOpenDefusersKeepNativeLookingFunctions() throws {
        let c = try context("example.com##+js(nostif, adblock)\nexample.com##+js(nosiif, , 1000)\n"
            + "example.com##+js(aeld, scroll, track)\nexample.com##+js(nowoif, /popunder/)")
        _ = eval(c, "setTimeout(function () { 'adblock' }, 5); setTimeout(function () { 'fine' }, 5); setInterval(function () { 'gone' }, 1000); setInterval(function () { 'kept' }, 50)")
        let log = eval(c, "log.map(e => e.join('|'))").toArray() as? [String] ?? []
        XCTAssertEqual(log.count, 4)
        XCTAssertFalse(log[0].contains("adblock"))
        XCTAssertTrue(log[1].contains("fine"))
        XCTAssertFalse(log[2].contains("gone"))
        XCTAssertTrue(log[3].contains("kept"))
        XCTAssertTrue(eval(c, "log = []; target.addEventListener('scroll', function () { track() }); target.addEventListener('scroll', function () {}); log.length === 1").toBool())
        XCTAssertTrue(eval(c, "open('https://x.test/popunder') === null && open('https://x.test/ok') === 'opened https://x.test/ok'").toBool())
        XCTAssertTrue(eval(c, "setTimeout.toString() === originalToString && Function.prototype.toString.toString() === nativeToString").toBool())
        XCTAssertEqual(eval(c, "setTimeout.name").toString(), "setTimeout")
    }

    func testJSONPruneAndFetchScriptlets() throws {
        let c = try context("example.com##+js(json-prune, ads x.[].ad, ok)\n"
            + "example.com##+js(json-prune-fetch-response, adPlacements, , propsToMatch, /player)\n"
            + "example.com##+js(no-fetch-if, url:/pagead/ method:GET, emptyObj)")
        XCTAssertEqual(eval(c, #"JSON.stringify(JSON.parse('{"ok":1,"ads":2,"x":[{"ad":1,"b":2}]}'))"#).toString(), #"{"ok":1,"x":[{"b":2}]}"#)
        XCTAssertEqual(eval(c, #"JSON.stringify(JSON.parse('{"ads":2}'))"#).toString(), #"{"ads":2}"#, "needle path absent")
        _ = eval(c, "fetch('https://e.test/player?id=1').then(r => r.text()).then(t => window.player = t); fetch('https://e.test/other').then(r => r.text()).then(t => window.other = t); fetch('https://e.test/pagead/x').then(r => r.text()).then(t => window.prevented = t)")
        XCTAssertEqual(eval(c, "window.player").toString(), #"{"ok":1}"#)
        XCTAssertEqual(eval(c, "window.other").toString(), #"{"ok":1,"adPlacements":[1]}"#)
        XCTAssertEqual(eval(c, "window.prevented").toString(), "{}")
    }

    func testMalformedArgumentsAreContainedPerScriptlet() throws {
        let c = try context("example.com##+js(nostif, /[/)\nexample.com##+js(set, , bogus)\nexample.com##+js(set)\n"
            + "example.com##+js(rc, a, ::bad)\nexample.com##+js(set, ok, true)")
        XCTAssertTrue(eval(c, "window.ok === true").toBool())
        XCTAssertTrue(eval(c, "setTimeout.toString() === originalToString").toBool())
    }
}
