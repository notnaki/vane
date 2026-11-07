#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN
// These are guarded adapters to the system framework, not a replacement runtime.
BOOL VaneExtensionUsesServiceWorker(WKWebExtension *extension);
WKWebExtension * _Nullable VaneCreateResourceExtension(NSDictionary<NSString *, NSData *> *resources,
                                                      NSError * _Nullable * _Nullable error);
/// Owns the legacy WebKit process context without exporting its deprecated type.
/// The two application owners must live for the entire app lifetime; stores and
/// extension controllers continue to supply profile isolation.
@interface VaneWebProcessPoolOwner : NSObject
- (instancetype)initWithExtensionResourceRevalidation:(BOOL)revalidate NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)configure:(WKWebViewConfiguration *)configuration;
- (BOOL)matches:(WKWebViewConfiguration *)configuration;
@property (nonatomic, readonly) BOOL revalidatesExtensionResources;
/// Borrowed WebKit C context identity. Valid only while this owner is retained.
@property (nonatomic, readonly) const void *contextHandle;
@end

/// Invokes only an implemented void setter with exactly one platform BOOL argument.
/// Missing or incompatible private preferences return NO without changing the target.
BOOL VaneSetBooleanPreference(id target, SEL setter, BOOL enabled);
NS_ASSUME_NONNULL_END
