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
