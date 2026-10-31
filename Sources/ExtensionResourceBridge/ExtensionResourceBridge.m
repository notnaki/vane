#import "ExtensionResourceBridge.h"

@interface WKWebExtension (VaneResourceInitialization)
- (instancetype)initWithResources:(NSDictionary<NSString *, id> *)resources;
- (BOOL)_hasServiceWorkerBackgroundContent;
@end

BOOL VaneExtensionUsesServiceWorker(WKWebExtension *extension)
{
    return [extension respondsToSelector:@selector(_hasServiceWorkerBackgroundContent)]
        && [extension _hasServiceWorkerBackgroundContent];
}

WKWebExtension *VaneCreateResourceExtension(NSDictionary<NSString *, NSData *> *resources, NSError **error)
{
    if ([WKWebExtension instancesRespondToSelector:@selector(initWithResources:)]) {
        WKWebExtension *extension = [[WKWebExtension alloc] initWithResources:resources];
        if (extension) {
#if __has_feature(objc_arc)
            return extension;
#else
            return [extension autorelease];
#endif
        }
    }
    if (error) *error = [NSError errorWithDomain:@"VaneExtensionIdentity" code:1
                                      userInfo:@{NSLocalizedDescriptionKey: @"This WebKit version cannot initialize the extension worker identity. The extension has not been started."}];
    return nil;
}


#import <objc/runtime.h>

@interface NSObject (VaneExtensionCacheConfiguration)
- (NSArray<NSString *> *)alwaysRevalidatedURLSchemes;
- (void)setAlwaysRevalidatedURLSchemes:(NSArray<NSString *> *)schemes;
@end
@interface WKProcessPool (VaneExtensionCacheConfiguration)
- (instancetype)_initWithConfiguration:(id)configuration __attribute__((objc_method_family(init)));
- (id)_configuration;
@end
static char VaneExtensionCachePolicyKey;

WKProcessPool *VaneCreateExtensionResourceProcessPool(void)
{
    Class configurationClass = NSClassFromString(@"_WKProcessPoolConfiguration");
    id configuration = nil;
    WKProcessPool *pool = nil;
    BOOL enabled = NO;
    if (configurationClass
        && [configurationClass instancesRespondToSelector:@selector(alwaysRevalidatedURLSchemes)]
        && [configurationClass instancesRespondToSelector:@selector(setAlwaysRevalidatedURLSchemes:)]
        && [WKProcessPool instancesRespondToSelector:@selector(_initWithConfiguration:)]
        && [WKProcessPool instancesRespondToSelector:@selector(_configuration)]) {
        configuration = [[configurationClass alloc] init];
        NSArray<NSString *> *existing = [configuration alwaysRevalidatedURLSchemes] ?: @[];
        if ([existing isKindOfClass:NSArray.class]) {
            NSArray<NSString *> *schemes = [existing containsObject:@"webkit-extension"]
                ? existing : [existing arrayByAddingObject:@"webkit-extension"];
            [configuration setAlwaysRevalidatedURLSchemes:schemes];
            pool = [[WKProcessPool alloc] _initWithConfiguration:configuration];
            NSArray<NSString *> *readback = [[pool _configuration] alwaysRevalidatedURLSchemes];
            enabled = [readback isKindOfClass:NSArray.class] && [readback containsObject:@"webkit-extension"];
        }
    }
    if (!pool) pool = [[WKProcessPool alloc] init];
    objc_setAssociatedObject(pool, &VaneExtensionCachePolicyKey, @(enabled), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
#if __has_feature(objc_arc)
    return pool;
#else
    [configuration release];
    return [pool autorelease];
#endif
}

BOOL VaneProcessPoolRevalidatesExtensionResources(WKProcessPool *pool)
{
    return [objc_getAssociatedObject(pool, &VaneExtensionCachePolicyKey) boolValue];
}
