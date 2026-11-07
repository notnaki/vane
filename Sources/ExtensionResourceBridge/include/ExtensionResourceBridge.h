#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN
// These are guarded adapters to the system framework, not a replacement runtime.
BOOL VaneExtensionUsesServiceWorker(WKWebExtension *extension);
WKWebExtension * _Nullable VaneCreateResourceExtension(NSDictionary<NSString *, NSData *> *resources,
                                                      NSError * _Nullable * _Nullable error);
/// Public-API compatibility owner for native receiver retirement on macOS 26.
/// This adapter deliberately retains the deprecated public type; it uses no SPI.
@interface VaneWebProcessPoolOwner : NSObject
- (void)configure:(WKWebViewConfiguration *)configuration;
- (BOOL)matches:(WKWebViewConfiguration *)configuration;
@end

/// Invokes only an implemented void setter with exactly one platform BOOL argument.
/// Missing or incompatible private preferences return NO without changing the target.
BOOL VaneSetBooleanPreference(id target, SEL setter, BOOL enabled);
NS_ASSUME_NONNULL_END
