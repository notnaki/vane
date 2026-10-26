#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>

// Standalone reduction using only the public suffix API.
// The existing Vane failure additionally uses SPI; see REPORT.md for that limit.
static NSString * const SafariSuffix = @"Version/26.6.2 Safari/605.1.15";
static void Emit(NSDictionary *record) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];
    if (data) { [NSFileHandle.fileHandleWithStandardOutput writeData:data]; [NSFileHandle.fileHandleWithStandardOutput writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]]; }
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
        @"ownedDataStoreID": self.storeID.UUIDString, @"arm": @"public-suffix-only" });
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
        [self inspect:result];
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
    [WKWebsiteDataStore removeDataStoreForIdentifier:self.storeID completionHandler:^(NSError *error) {
        Emit(@{ @"event": @"summary", @"completedStages": @(self.stage), @"mismatchOrHarnessFailure": @(self.mismatch),
            @"ownedStoreRemovalCallbackSucceeded": error == nil ? @YES : @NO, @"backendRetirementVerified": @NO });
        exit(self.mismatch || error ? 1 : 0);
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        Emit(@{ @"event": @"cleanup-timeout", @"backendRetirementVerified": @NO }); exit(2);
    });
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        __attribute__((objc_precise_lifetime)) Probe *probe = [Probe new]; app.delegate = probe;
        [app run]; // A normal application loop, not XCTest/run-loop pumping.
        return 2;
    }
}
