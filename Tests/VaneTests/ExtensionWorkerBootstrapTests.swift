import Foundation
import JavaScriptCore
import XCTest
@testable import vane

@MainActor final class ExtensionWorkerBootstrapTests: XCTestCase {
    private func evaluate(_ source: String) throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(source)
        XCTAssertNil(context.exception, context.exception?.toString() ?? "")
        return context
    }

    func testImportedClassicScriptsPreserveDirectiveAndExpressionSemantics() throws {
        // Execute the generated entry against a native-script loader double.
        // The vendor's standalone Script must keep its own directive semantics.
        let cases: [(String, Bool)] = [
            ("'use strict'; result = (function(){ return this === undefined; })();", true),
            ("'other'; /* hi */ 'use strict'\nvar result = (function(){ return this === undefined; })();", true),
            ("\u{FEFF}// comment\r\n'use strict'; var result = (function(){ return this === undefined; })();", true),
            ("'use strict'\n; var result = (function(){ return this === undefined; })();", true),
            ("'use\\x20strict'; var result = (function(){ return this === undefined; })();", false),
            ("'use strict'\n[0]; var result = (function(){ return this === undefined; })();", false),
            ("'other'\n+ 'use strict'; var result = (function(){ return this === undefined; })();", false),
            ("var result = (function(){ return this === undefined; })();", false),
        ]
        for (source, strict) in cases {
            let context = try evaluate("var result;")
            let importer: @convention(block) (String) -> Void = { path in
                XCTAssertEqual(path, "/background.js")
                context.evaluateScript(source)
            }
            context.setObject(importer, forKeyedSubscript: "importScripts" as NSString)
            let entry = try ExtensionWorkerIdentity.entrySource(bootstrap: "globalThis.insertions = (globalThis.insertions || 0) + 1;",
                                                                 modulePath: nil, scripts: ["/background.js"])
            context.evaluateScript(entry)
            context.setObject(nil, forKeyedSubscript: "importScripts" as NSString)
            XCTAssertNil(context.exception, source)
            XCTAssertEqual(context.objectForKeyedSubscript("result")?.toBool(), strict, source)
            XCTAssertEqual(context.objectForKeyedSubscript("insertions")?.toInt32(), 1)
        }
    }

    func testBootstrapDoesNotOverridePageOrContentScriptNavigator() throws {
        let context = try evaluate("var navigator = {userAgent:'ordinary page', appVersion:'page'};")
        context.evaluateScript(try ExtensionWorkerIdentity.bootstrap(userAgent: "Vane Worker/1.0", token: "probe"))
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("navigator.userAgent")?.toString(), "ordinary page")
    }

    func testBootstrapOverridesOnlyIdentityAndCanRunTwice() throws {
        let context = try evaluate("""
            function WorkerNavigator() {}
            Object.defineProperty(WorkerNavigator.prototype, 'userAgent', {get:()=> 'bare WebKit', configurable:true});
            Object.defineProperty(WorkerNavigator.prototype, 'vendor', {get:()=> 'Apple Computer, Inc.', configurable:true});
            var navigator = new WorkerNavigator();
            function ServiceWorkerGlobalScope() {}
            Object.defineProperty(ServiceWorkerGlobalScope, Symbol.hasInstance, {value:()=>true});
            """)
        let source = try ExtensionWorkerIdentity.bootstrap(userAgent: "Vane Worker/1.0 \"quoted\"\nline", token: "probe")
        context.evaluateScript(source)
        context.evaluateScript(source)
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("navigator.userAgent")?.toString(), "Vane Worker/1.0 \"quoted\"\nline")
        XCTAssertEqual(context.evaluateScript("navigator.appVersion")?.toString(), "Vane Worker/1.0 \"quoted\"\nline")
        XCTAssertEqual(context.evaluateScript("navigator.vendor")?.toString(), "Apple Computer, Inc.")
        XCTAssertEqual(context.evaluateScript("typeof navigator.userAgentData")?.toString(), "undefined")
    }

    func testBootstrapFailsIfNavigatorCannotBeOverridden() throws {
        let context = try evaluate("""
            function WorkerNavigator() {}
            Object.defineProperty(WorkerNavigator.prototype, 'userAgent', {get:()=> 'bare WebKit', configurable:false});
            var navigator = new WorkerNavigator();
            function ServiceWorkerGlobalScope() {}
            Object.defineProperty(ServiceWorkerGlobalScope, Symbol.hasInstance, {value:()=>true});
            """)
        context.evaluateScript(try ExtensionWorkerIdentity.bootstrap(userAgent: "Vane Worker/1.0", token: "probe") + "\nglobalThis.vendorRan = true;")
        XCTAssertNotNil(context.exception, "A blocked override must prevent vendor startup")
        context.exception = nil
        XCTAssertFalse(context.evaluateScript("globalThis.vendorRan === true")?.toBool() ?? true)
    }
}
