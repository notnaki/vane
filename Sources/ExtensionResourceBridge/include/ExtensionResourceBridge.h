#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN
// These are guarded adapters to the system framework, not a replacement runtime.
BOOL VaneExtensionUsesServiceWorker(WKWebExtension *extension);
WKWebExtension * _Nullable VaneCreateResourceExtension(NSDictionary<NSString *, NSData *> *resources,
                                                      NSError * _Nullable * _Nullable error);
WKProcessPool *VaneCreateExtensionResourceProcessPool(void);
BOOL VaneProcessPoolRevalidatesExtensionResources(WKProcessPool *pool);
NS_ASSUME_NONNULL_END
