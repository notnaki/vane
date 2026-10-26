// SPI-assisted framework reduction. No Vane or WKWebExtensionController.
#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#import <objc/message.h>

static NSString *const Scheme = @"vane-worker-control";
static NSString *const Safari = @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6.2 Safari/605.1.15";
static NSString *const Custom = @"Vane Prior Worker Identity/1.0 (no Safari token)";
static void Emit(NSDictionary *record) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];
    if (!data) exit(2);
    printf("PAGE WORKER %s\n", [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] UTF8String]); fflush(stdout);
}

@interface Reduction : NSObject <NSApplicationDelegate, WKURLSchemeHandler>
@property(strong) WKWebView *web;
@property(strong) WKProcessPool *pool;
@property(strong) WKWebsiteDataStore *store;
@property(strong) NSUUID *storeID;
@property(copy) NSString *nonce;
@property(copy) NSString *selected;
@property(copy) NSString *scriptUA;
@property(copy) NSString *reportUA;
@property(strong) NSDictionary *report;
@property NSUInteger stage;
@property NSUInteger scriptRequests;
@property NSUInteger reportRequests;
@property BOOL loaded;
@property BOOL finishing;
@property NSTimeInterval admissionDeadline;
@end

@implementation Reduction
- (void)unavailable:(NSString *)reason {
    Emit(@{@"event":@"unavailable", @"reason":reason, @"stage":@(self.stage)}); exit(2);
}
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    self.admissionDeadline = NSProcessInfo.processInfo.systemUptime + 10;
    dispatch_async(dispatch_get_main_queue(), ^{ [self admit]; });
}
- (void)admit {
    if (!NSApp.running || !NSRunningApplication.currentApplication.finishedLaunching) {
        if (NSProcessInfo.processInfo.systemUptime >= self.admissionDeadline) [self unavailable:@"application launch admission"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self admit]; }); return;
    }
    NSDictionary *env = NSProcessInfo.processInfo.environment;
    self.storeID = [[NSUUID alloc] initWithUUIDString:env[@"PAGE_WORKER_STORE"] ?: @""];
    if (!self.storeID || [self.storeID.UUIDString isEqual:@"00000000-0000-0000-0000-000000000000"])
        [self unavailable:@"missing generated store identifier"];
    if ([env[@"PAGE_WORKER_PHASE"] isEqual:@"cleanup"]) {
        // Same initialization required by the existing public probe's retirement helper.
        @autoreleasepool { (void)[WKWebsiteDataStore nonPersistentDataStore]; }
        [WKWebsiteDataStore removeDataStoreForIdentifier:self.storeID completionHandler:^(NSError *error) {
            Emit(@{@"event":@"cleanup", @"store":self.storeID.UUIDString.lowercaseString, @"retired":error ? @NO : @YES, @"error":error.localizedDescription ?: @""});
            exit(error ? 2 : 0);
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15*NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self unavailable:@"cleanup deadline"]; }); return;
    }
    if (![env[@"PAGE_WORKER_PHASE"] isEqual:@"primary"]) [self unavailable:@"unknown phase"];
    self.store = [WKWebsiteDataStore dataStoreForIdentifier:self.storeID];
    self.pool = [WKProcessPool new];
    SEL secure = NSSelectorFromString(@"_registerURLSchemeAsSecure:");
    if (![self.pool respondsToSelector:secure]) [self unavailable:@"test scheme registration selector"];
    ((void (*)(id,SEL,id))objc_msgSend)(self.pool, secure, Scheme);
    Emit(@{@"event":@"launch", @"scenario":@"page-backed-three-stage", @"store":self.storeID.UUIDString.lowercaseString,
           @"appRunning":@(NSApp.running), @"finishedLaunching":@(NSRunningApplication.currentApplication.finishedLaunching)});
    [self beginStage];
}
- (void)beginStage {
    self.nonce = NSUUID.UUID.UUIDString.lowercaseString;
    self.selected = self.stage == 1 ? Custom : Safari;
    self.report = nil; self.loaded = NO; self.scriptUA = nil; self.reportUA = nil;
    self.scriptRequests = 0; self.reportRequests = 0;
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.websiteDataStore = self.store; configuration.processPool = self.pool;
    configuration.applicationNameForUserAgent = @"Version/26.6.2 Safari/605.1.15";
    [configuration setURLSchemeHandler:self forURLScheme:Scheme];
    self.web = [[WKWebView alloc] initWithFrame:NSMakeRect(0,0,100,100) configuration:configuration];
    if (self.stage == 1) self.web.customUserAgent = Custom;
    if (self.web.configuration.processPool != self.pool || !self.web.configuration.websiteDataStore.persistent
        || ![self.web.configuration.websiteDataStore.identifier isEqual:self.storeID]) [self unavailable:@"view pool/store binding"];
    SEL load = NSSelectorFromString(@"_loadServiceWorker:usingModules:completionHandler:");
    if (![self.web respondsToSelector:load]) [self unavailable:@"page-backed loader selector"];
    NSString *nonce = self.nonce;
    __weak WKWebView *weakWeb = self.web;
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@://%@/worker.js", Scheme, nonce]];
    Emit(@{@"event":@"stage", @"stage":@(self.stage), @"nonce":nonce, @"expected":self.selected});
    ((void (*)(id,SEL,id,BOOL,id))objc_msgSend)(self.web, load, url, NO, ^(BOOL success) {
        if (![nonce isEqual:self.nonce] || weakWeb != self.web) [self unavailable:@"loader callback binding"];
        if (!success) [self unavailable:@"page-backed worker did not start"];
        self.loaded = YES; [self finishIfReady];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!self.finishing && [nonce isEqual:self.nonce]) [self unavailable:@"stage deadline"];
    });
}
- (void)webView:(WKWebView *)web startURLSchemeTask:(id<WKURLSchemeTask>)task {
    NSURL *url = task.request.URL;
    if (web != self.web || ![url.scheme isEqual:Scheme] || ![url.host isEqual:self.nonce]
        || ![@[@"/worker.js",@"/report"] containsObject:url.path]) [self unavailable:@"scheme request binding"];
    BOOL reporting = [url.path isEqual:@"/report"];
    NSString *header = [task.request valueForHTTPHeaderField:@"User-Agent"] ?: @"missing";
    if (reporting) {
        if (++self.reportRequests != 1) [self unavailable:@"duplicate worker report"];
        self.reportUA = header;
        NSMutableDictionary *values = [NSMutableDictionary new];
        for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].queryItems) {
            if (![@[@"startup",@"current",@"nonce",@"href"] containsObject:item.name] || values[item.name] || !item.value || item.value.length > 8192)
                [self unavailable:@"malformed worker report"];
            values[item.name] = item.value;
        }
        if (values.count != 4) [self unavailable:@"incomplete worker report"];
        self.report = values;
    } else {
        if (++self.scriptRequests != 1 || url.query.length) [self unavailable:@"duplicate or malformed script request"];
        self.scriptUA = header;
    }
    Emit(@{@"event":@"request", @"stage":@(self.stage), @"nonce":self.nonce, @"kind":reporting ? @"report" : @"script", @"UA":header});
    // Both navigator values are captured before transport. The import's request
    // header is auxiliary evidence, not a read of SWServer's origin-UA map.
    NSString *origin = [NSString stringWithFormat:@"%@://%@/", Scheme, self.nonce];
    NSString *script = reporting ? @"void 0;" : [NSString stringWithFormat:
        @"const startup=navigator.userAgent; const current=navigator.userAgent; importScripts('%@report?startup='+encodeURIComponent(startup)+'&current='+encodeURIComponent(current)+'&nonce='+encodeURIComponent(location.host)+'&href='+encodeURIComponent(location.href));", origin];
    NSData *data = [script dataUsingEncoding:NSUTF8StringEncoding];
    [task didReceiveResponse:[[NSURLResponse alloc] initWithURL:url MIMEType:@"text/javascript" expectedContentLength:data.length textEncodingName:@"utf-8"]];
    [task didReceiveData:data]; [task didFinish];
    if (reporting) dispatch_async(dispatch_get_main_queue(), ^{ [self finishIfReady]; });
}
- (void)webView:(WKWebView *)web stopURLSchemeTask:(id<WKURLSchemeTask>)task { }
- (void)finishIfReady {
    if (!self.loaded || !self.report || self.finishing) return;
    NSString *href = [NSString stringWithFormat:@"%@://%@/worker.js", Scheme, self.nonce];
    if (![self.report[@"nonce"] isEqual:self.nonce] || ![self.report[@"href"] isEqual:href]
        || self.scriptRequests != 1 || self.reportRequests != 1) [self unavailable:@"worker value binding"];
    SEL getter = NSSelectorFromString(@"_userAgent");
    NSString *resolved = [self.web respondsToSelector:getter] ? ((id (*)(id,SEL))objc_msgSend)(self.web,getter) : nil;
    if (![resolved isEqual:self.selected]) [self unavailable:@"native view identity"];
    BOOL matches = [self.report[@"startup"] isEqual:self.selected] && [self.report[@"current"] isEqual:self.selected];
    Emit(@{@"event":@"comparison", @"stage":@(self.stage), @"nonce":self.nonce, @"expected":self.selected,
           @"startup":self.report[@"startup"], @"current":self.report[@"current"], @"href":href,
           @"viewUA":resolved, @"scriptRequestUA":self.scriptUA, @"reportRequestUA":self.reportUA, @"matches":@(matches)});
    if (!matches) exit(1);
    [self.web stopLoading]; self.web = nil; self.report = nil;
    if (++self.stage == 3) {
        self.finishing = YES;
        Emit(@{@"event":@"complete", @"verified":@3, @"store":self.storeID.UUIDString.lowercaseString}); exit(0);
    }
    // Advance after load/scheme callbacks release their references.
    dispatch_async(dispatch_get_main_queue(), ^{ [self beginStage]; });
}
@end

int main(void) { @autoreleasepool {
    NSApplication *app = NSApplication.sharedApplication;
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    __attribute__((objc_precise_lifetime)) Reduction *delegate = [Reduction new]; app.delegate = delegate;
    [app run]; return 2;
} }
