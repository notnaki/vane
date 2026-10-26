#import <AppKit/AppKit.h>
#import "NativeTestHostBootstrap.h"
#include <stdio.h>

static bool bootstrapRan;
static bool bootstrapWasEarly;
static bool bootstrapConfigured;

// XCTest does not enter through NSApplicationMain. Concurrent AppKit event
// processing can leave window occlusion stale in that host. Match WebKit's
// test-only workaround, before any fixture initializes NSApplication:
// https://github.com/WebKit/WebKit/commit/f9f5867e78042bbbd61a427b93a4a1291486ca26
// Remove when the underlying AppKit issue (rdar://159372811) is fixed.
__attribute__((constructor))
static void VaneConfigureNativeTestHost(void)
{
    @autoreleasepool {
        bootstrapRan = true;
        // Reading NSApp does not create it. Refuse to disguise late setup.
        bootstrapWasEarly = NSApp == nil;
        if (bootstrapWasEarly) {
            NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
            NSMutableDictionary *arguments = [[defaults volatileDomainForName:NSArgumentDomain] mutableCopy];
            if (!arguments)
                arguments = [NSMutableDictionary dictionary];
            arguments[@"NSEventConcurrentProcessingEnabled"] = @NO;
            [defaults setVolatileDomain:arguments forName:NSArgumentDomain];
            bootstrapConfigured = ![defaults boolForKey:@"NSEventConcurrentProcessingEnabled"];
        }
        fprintf(stderr, "Native test host bootstrap: beforeAppKit=%s, configured=%s\n",
                bootstrapWasEarly ? "true" : "false", bootstrapConfigured ? "true" : "false");
    }
}

// Referenced from the Swift test bundle so the constructor's object is linked
// even when XCTest selects a different test or a fresh cleanup child.
bool VaneNativeTestHostBootstrapRan(void) { return bootstrapRan; }
bool VaneNativeTestHostBootstrapWasEarly(void) { return bootstrapWasEarly; }
bool VaneNativeTestHostBootstrapConfigured(void) { return bootstrapConfigured; }
