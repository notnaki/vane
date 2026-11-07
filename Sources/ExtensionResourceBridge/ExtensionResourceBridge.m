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
// WKProcessPool and WKWebViewConfiguration.processPool are deprecated, but
// WebKit has no public replacement for alwaysRevalidatedURLSchemes. The explicit
// contexts keep canonical MV3 module imports fresh and preserve the two app-lifetime
// IPC owners. Removing either creation or assignment changes shipped behavior.
// Keep the unavoidable compatibility exception confined to this typed adapter;
// callers and the public bridge header never reference the deprecated API.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
@interface WKProcessPool (VaneExtensionCacheConfiguration)
- (instancetype)_initWithConfiguration:(id)configuration __attribute__((objc_method_family(init)));
- (id)_configuration;
@end

static WKProcessPool *VaneCreateExtensionResourceProcessPool(BOOL *revalidates)
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
    *revalidates = enabled;
#if __has_feature(objc_arc)
    return pool;
#else
    [configuration release];
    return [pool autorelease];
#endif
}

@interface VaneWebProcessPoolOwner () {
    WKProcessPool *_pool;
    BOOL _revalidatesExtensionResources;
}
@end

@implementation VaneWebProcessPoolOwner
- (instancetype)initWithExtensionResourceRevalidation:(BOOL)revalidate
{
    self = [super init];
    if (!self) return nil;
    if (revalidate) {
        _pool = VaneCreateExtensionResourceProcessPool(&_revalidatesExtensionResources);
#if !__has_feature(objc_arc)
        [_pool retain];
#endif
    } else {
        _pool = [[WKProcessPool alloc] init];
    }
    return self;
}

- (void)configure:(WKWebViewConfiguration *)configuration { configuration.processPool = _pool; }
- (BOOL)matches:(WKWebViewConfiguration *)configuration { return configuration.processPool == _pool; }
- (BOOL)revalidatesExtensionResources { return _revalidatesExtensionResources; }
- (const void *)contextHandle
{
#if __has_feature(objc_arc)
    return (__bridge const void *)_pool;
#else
    return (const void *)_pool;
#endif
}
#if !__has_feature(objc_arc)
- (void)dealloc
{
    [_pool release];
    [super dealloc];
}
#endif
@end
#pragma clang diagnostic pop

BOOL VaneSetBooleanPreference(id target, SEL setter, BOOL enabled)
{
    if (![target respondsToSelector:setter]) return NO;
    Method method = class_getInstanceMethod(object_getClass(target), setter);
    if (!method) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (signature.numberOfArguments != 3
        || strcmp(signature.methodReturnType, @encode(void)) != 0
        || strcmp([signature getArgumentTypeAtIndex:2], @encode(BOOL)) != 0) return NO;
    void (*setBoolean)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))method_getImplementation(method);
    setBoolean(target, setter, enabled);
    return YES;
}
