#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#import <string.h>
#import <mach-o/dyld.h>
#import <Security/Security.h>

// Standalone reduction using only the public suffix API.
// The existing Vane failure additionally uses SPI; see REPORT.md for that limit.
static NSString * const SafariSuffix = @"Version/26.6.2 Safari/605.1.15";
static void Emit(NSDictionary *record) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];
    if (data) { [NSFileHandle.fileHandleWithStandardOutput writeData:data]; [NSFileHandle.fileHandleWithStandardOutput writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]]; }
}

static void ReportEngineImages(void) {
    NSMutableArray *images = [NSMutableArray array];
    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        const struct mach_header *header = _dyld_get_image_header(index);
        const char *name = _dyld_get_image_name(index);
        if (!header || !name || header->magic != MH_MAGIC_64) continue;
        NSString *path = [NSString stringWithUTF8String:name];
        if (![path hasPrefix:@"/System/"] ||
            (![@[@"WebKit", @"WebCore", @"JavaScriptCore"] containsObject:path.lastPathComponent] &&
             ![path containsString:@"/StagedFrameworks/Safari/"])) continue;
        NSMutableDictionary *record = [@{ @"path": path } mutableCopy];
        const uint8_t *raw = (const uint8_t *)header;
        size_t offset = sizeof(struct mach_header_64), end = offset + header->sizeofcmds;
        for (uint32_t commandIndex = 0; commandIndex < header->ncmds; commandIndex++) {
            if (offset + sizeof(struct load_command) > end) break;
            const struct load_command *command = (const struct load_command *)(raw + offset);
            if (command->cmdsize < sizeof(struct load_command) || offset + command->cmdsize > end) break;
            if (command->cmd == LC_UUID && command->cmdsize >= sizeof(struct uuid_command))
                record[@"uuid"] = [[NSUUID alloc] initWithUUIDBytes:((const struct uuid_command *)command)->uuid].UUIDString;
            else if (command->cmd == LC_ID_DYLIB && command->cmdsize >= sizeof(struct dylib_command)) {
                uint32_t version = ((const struct dylib_command *)command)->dylib.current_version;
                record[@"version"] = [NSString stringWithFormat:@"%u.%u.%u", version >> 16, (version >> 8) & 255, version & 255];
            }
            offset += command->cmdsize;
        }
        [images addObject:record];
    }
    SecCodeRef code = NULL;
    SecStaticCodeRef staticCode = NULL;
    CFDictionaryRef signingInfo = NULL;
    BOOL hardened = NO;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &code) == errSecSuccess &&
        SecCodeCopyStaticCode(code, kSecCSDefaultFlags, &staticCode) == errSecSuccess &&
        SecCodeCopySigningInformation(staticCode, kSecCSSigningInformation, &signingInfo) == errSecSuccess)
        hardened = ([((__bridge NSDictionary *)signingInfo)[(__bridge id)kSecCodeInfoFlags] unsignedIntValue] & kSecCodeSignatureRuntime) != 0;
    if (signingInfo) CFRelease(signingInfo);
    if (code) CFRelease(code);
    if (staticCode) CFRelease(staticCode);
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{ @"hardenedRuntime": @(hardened), @"images": images } options:NSJSONWritingSortedKeys error:nil];
    if (data) printf("UA ENGINE IMAGES %s\n", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
}

@interface Probe : NSObject <NSApplicationDelegate, WKWebExtensionControllerDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) NSView *anchor;
@property (nonatomic, strong) WKProcessPool *pool;
@property (nonatomic, strong) NSUUID *storeID;
@property (nonatomic, strong) WKWebsiteDataStore *store;
@property (nonatomic, strong) WKWebExtensionController *controller;
@property (nonatomic, strong) WKWebExtensionContext *context;
@property (nonatomic, strong) WKWebExtensionAction *action;
@property (nonatomic, strong) WKWebView *popup;
@property (nonatomic, strong) NSURL *folder;
@property (nonatomic, strong) NSArray<NSDictionary *> *stages;
@property (nonatomic) NSUInteger stage;
@property (nonatomic) NSUInteger epoch;
@property (nonatomic, strong) NSString *nonce;
@property (nonatomic) NSTimeInterval deadline;
@property (nonatomic) BOOL finishing;
@property (nonatomic) BOOL mismatch;
@property (nonatomic) BOOL freshMV3;
@end

@implementation Probe
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.deadline = NSProcessInfo.processInfo.systemUptime + 10;
    dispatch_async(dispatch_get_main_queue(), ^{ [self admitLaunch]; });
}
- (void)admitLaunch {
    if (NSApp.running && NSRunningApplication.currentApplication.finishedLaunching) { [self startProbe]; return; }
    if (NSProcessInfo.processInfo.systemUptime >= self.deadline) {
        Emit(@{ @"event": @"launch-admission-failure" }); exit(2);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self admitLaunch]; });
}
- (void)startProbe {
    ReportEngineImages();
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 520, 320)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"WKWebExtension worker UA probe";
    self.window.releasedWhenClosed = NO;
    self.anchor = [[NSView alloc] initWithFrame:NSMakeRect(440, 250, 28, 28)];
    [self.window.contentView addSubview:self.anchor];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    // Keep one pool/controller/store alive across the ordered stages.
    self.pool = [WKProcessPool new];
    self.storeID = [NSUUID UUID];
    self.store = [WKWebsiteDataStore dataStoreForIdentifier:self.storeID];
    self.stages = @[
        @{ @"version": @2, @"label": @"Safari MV2", @"suffix": SafariSuffix },
        @{ @"version": @3, @"label": @"Safari MV3 after MV2", @"suffix": SafariSuffix },
        @{ @"version": @3, @"label": @"second Safari MV3", @"suffix": SafariSuffix },
        @{ @"version": @3, @"label": @"third Safari MV3", @"suffix": SafariSuffix }
    ];
    if (self.freshMV3)
        self.stages = @[ @{ @"version": @3, @"label": @"fresh Safari MV3", @"suffix": SafariSuffix } ];
    WKWebExtensionControllerConfiguration *configuration = [WKWebExtensionControllerConfiguration nonPersistentConfiguration];
    configuration.defaultWebsiteDataStore = self.store;
    WKWebViewConfiguration *seed = configuration.webViewConfiguration;
    seed.websiteDataStore = self.store;
    seed.processPool = self.pool;
    seed.applicationNameForUserAgent = SafariSuffix;
    configuration.webViewConfiguration = seed; // Configuration is copied at controller initialization.
    self.controller = [[WKWebExtensionController alloc] initWithConfiguration:configuration];
    self.controller.delegate = self;
    Emit(@{ @"event": @"launch", @"finishedLaunching": @(NSRunningApplication.currentApplication.finishedLaunching),
        @"appRunning": @(NSApp.running), @"OS": NSProcessInfo.processInfo.operatingSystemVersionString,
        @"WebKit": [[NSBundle bundleForClass:WKWebView.class] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown",
        @"ownedDataStoreID": self.storeID.UUIDString, @"arm": @"public-suffix-only",
        @"scenario": self.freshMV3 ? @"fresh-mv3" : @"ordered" });
    // Schedule after applicationDidFinishLaunching returns to NSApplication.run.
    dispatch_async(dispatch_get_main_queue(), ^{ [self beginStage]; });
}
- (void)fail:(NSString *)reason {
    Emit(@{ @"event": @"failure", @"stage": @(self.stage), @"reason": reason });
    self.mismatch = YES;
    [self finish];
}
- (void)beginStage {
    if (self.finishing) return;
    if (self.stage == self.stages.count) { [self finish]; return; }
    NSDictionary *stage = self.stages[self.stage];
    self.nonce = NSUUID.UUID.UUIDString.lowercaseString;
    self.epoch++;
    NSUInteger epoch = self.epoch;
    self.deadline = NSProcessInfo.processInfo.systemUptime + 15;
    self.folder = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:[@"WKWorkerUA-" stringByAppendingString:self.nonce] isDirectory:YES];
    NSURL *source = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:([stage[@"version"] intValue] == 2 ? @"Extensions/mv2" : @"Extensions/mv3")];
    NSError *error;
    if (![NSFileManager.defaultManager copyItemAtURL:source toURL:self.folder error:&error]) { [self fail:@"Could not copy bundled synthetic extension resources"]; return; }
    NSData *nonceJSON = [NSJSONSerialization dataWithJSONObject:@[self.nonce] options:0 error:nil];
    NSString *nonceArray = [[NSString alloc] initWithData:nonceJSON encoding:NSUTF8StringEncoding];
    NSString *script = [NSString stringWithFormat:@"globalThis.fixtureNonce = %@[0];\n", nonceArray];
    if (![script writeToURL:[self.folder URLByAppendingPathComponent:@"identity.js"] atomically:YES encoding:NSUTF8StringEncoding error:&error]) { [self fail:@"Could not write generated fixture nonce"]; return; }
    // The public-only arm keeps a fixed suffix. Exact full-UA custom→Safari ordering
    // from Vane requires SPI and is intentionally not claimed by this candidate.
    [WKWebExtension extensionWithResourceBaseURL:self.folder completionHandler:^(WKWebExtension *extension, NSError *error) {
        if (self.finishing || self.epoch != epoch) return;
        if (!extension || error || extension.errors.count) {
            NSString *detail = [NSString stringWithFormat:@"Synthetic extension could not be parsed: %@; %@",
                error.localizedDescription ?: @"no callback error", extension.errors ?: @[]];
            [self fail:[detail substringToIndex:MIN(detail.length, 2048)]]; return;
        }
        self.context = [[WKWebExtensionContext alloc] initForExtension:extension];
        self.context.uniqueIdentifier = self.nonce;
        self.context.baseURL = [NSURL URLWithString:[NSString stringWithFormat:@"webkit-extension://%@/", self.nonce]];
        NSError *loadError;
        if (![self.controller loadExtensionContext:self.context error:&loadError]) { [self fail:@"Controller could not load synthetic context"]; return; }
        [self.context loadBackgroundContentWithCompletionHandler:^(NSError *error) {
            if (self.finishing || self.epoch != epoch) return;
            if (error) { [self fail:@"Background load callback failed"]; return; }
            self.action = [self.context actionForTab:nil];
            self.popup = self.action.popupWebView;
            if (!self.popup) { [self fail:@"No actual action popup web view"]; return; }
            [self.action.popupPopover showRelativeToRect:self.anchor.bounds ofView:self.anchor preferredEdge:NSRectEdgeMinY];
            [self poll:epoch];
        }];
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!self.finishing && self.epoch == epoch) [self fail:@"Stage deadline exceeded; this is unavailable evidence, not a UA result"];
    });
}
- (void)poll:(NSUInteger)epoch {
    if (self.finishing || self.epoch != epoch) return;
    if (NSProcessInfo.processInfo.systemUptime >= self.deadline) { [self fail:@"Popup/background reply deadline exceeded"]; return; }
    [self.popup evaluateJavaScript:@"window.fixtureResult || null" completionHandler:^(id result, NSError *error) {
        if (self.finishing || self.epoch != epoch) return;
        if (![result isKindOfClass:NSDictionary.class]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self poll:epoch]; });
            return;
        }
        @autoreleasepool { [self inspect:result]; }
    }];
}
- (void)inspect:(NSDictionary *)result {
    NSDictionary *worker = result[@"worker"];
    NSDictionary *stage = self.stages[self.stage];
    if (![worker isKindOfClass:NSDictionary.class]) { [self fail:@"Missing worker identity"]; return; }
    NSString *expectedVersion = [stage[@"version"] stringValue];
    BOOL bound = [worker[@"nonce"] isEqual:self.nonce] && [result[@"nonce"] isEqual:self.nonce]
        && [worker[@"runtime"] isEqual:self.context.uniqueIdentifier] && [result[@"runtime"] isEqual:self.context.uniqueIdentifier]
        && [worker[@"host"] isEqual:self.context.baseURL.host] && [result[@"host"] isEqual:self.context.baseURL.host]
        && [worker[@"scheme"] isEqual:@"webkit-extension:"] && [worker[@"version"] isEqual:expectedVersion];
    WKWebViewConfiguration *actual = self.popup.configuration;
    BOOL owned = actual.processPool == self.pool && [actual.websiteDataStore.identifier isEqual:self.storeID]
        && actual.websiteDataStore.persistent && self.context.loaded && self.context.webExtensionController == self.controller;
    NSString *popupStartup = result[@"startup"];
    BOOL validUA = [popupStartup isKindOfClass:NSString.class] && [popupStartup containsString:SafariSuffix];
    BOOL equal = validUA && [result[@"current"] isEqual:popupStartup]
        && [worker[@"startup"] isEqual:popupStartup] && [worker[@"current"] isEqual:popupStartup];
    Emit(@{ @"event": @"observation", @"stage": stage[@"label"], @"arm": @"public-suffix-only",
        @"boundToCurrentContext": @(bound), @"popupPoolStoreAndControllerMatch": @(owned),
        @"startupAndCurrentMatch": @(equal), @"identity": result });
    if (!bound || !owned) { [self fail:@"Context identity or ownership guard failed before UA acceptance"]; return; }
    if (!equal) { [self fail:@"Worker/popup startup or current identity mismatch"]; return; }
    [self.action closePopup]; self.action = nil; self.popup = nil;
    NSError *error;
    if (![self.controller unloadExtensionContext:self.context error:&error]) { [self fail:@"Could not unload owned context"]; return; }
    self.context = nil;
    // Remove only the exact folder created by this launch.
    if (![NSFileManager.defaultManager removeItemAtURL:self.folder error:&error]) { [self fail:@"Could not remove owned synthetic resources"]; return; }
    self.folder = nil;
    self.stage++;
    self.epoch++;
    dispatch_async(dispatch_get_main_queue(), ^{ [self beginStage]; });
}
- (void)finish {
    if (self.finishing) return;
    self.finishing = YES; self.epoch++;
    [self.popup stopLoading]; [self.action closePopup]; self.popup = nil; self.action = nil;
    if (self.context.loaded) {
        NSError *error;
        if (![self.controller unloadExtensionContext:self.context error:&error]) self.mismatch = YES;
    }
    self.context = nil; self.controller.delegate = nil; self.controller = nil; self.store = nil; self.pool = nil;
    if (self.folder && ![NSFileManager.defaultManager removeItemAtURL:self.folder error:nil]) self.mismatch = YES;
    [self.window close]; self.window = nil;
    // WebKit can retain its named store until this application exits. The owned
    // runner verifies exit, then removes this exact UUID from a fresh process.
    Emit(@{ @"event": @"summary", @"completedStages": @(self.stage), @"mismatchOrHarnessFailure": @(self.mismatch),
        @"ownedStoreRemovalCallbackSucceeded": @NO, @"storeRemovalDeferredToPostExit": @YES,
        @"backendRetirementVerified": @NO });
    exit(self.mismatch ? 1 : 0);
}
@end

@interface Retirement : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSUUID *storeID;
@end

@implementation Retirement
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // Initialize WebKit's run loop before a cold registry class-method call,
    // without opening the named store being removed (as in WebKitStartup).
    @autoreleasepool { (void)[WKWebsiteDataStore nonPersistentDataStore]; }
    [WKWebsiteDataStore removeDataStoreForIdentifier:self.storeID completionHandler:^(NSError *error) {
        NSString *detail = error.localizedDescription ?: @"";
        Emit(@{ @"event": @"retirement", @"ownedDataStoreID": self.storeID.UUIDString,
            @"ownedStoreRemovalCallbackSucceeded": error == nil ? @YES : @NO,
            @"backendRetirementVerified": @NO,
            @"storeRemovalError": [detail substringToIndex:MIN(detail.length, 2048)] });
        exit(error ? 1 : 0);
    }];
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        if (argc == 3 && strcmp(argv[1], "--retire-store") == 0) {
            NSUUID *storeID = [[NSUUID alloc] initWithUUIDString:[NSString stringWithUTF8String:argv[2]]];
            if (!storeID) return 2;
            [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
            __attribute__((objc_precise_lifetime)) Retirement *retirement = [Retirement new];
            retirement.storeID = storeID; app.delegate = retirement;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                Emit(@{ @"event": @"cleanup-timeout", @"backendRetirementVerified": @NO }); exit(2);
            });
            [app run];
            return 2;
        }
        BOOL freshMV3 = argc == 2 && strcmp(argv[1], "--fresh-mv3") == 0;
        if (argc != 1 && !freshMV3) return 2;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        __attribute__((objc_precise_lifetime)) Probe *probe = [Probe new];
        probe.freshMV3 = freshMV3; app.delegate = probe;
        [app run]; // A normal application loop, not XCTest/run-loop pumping.
        return 2;
    }
}
