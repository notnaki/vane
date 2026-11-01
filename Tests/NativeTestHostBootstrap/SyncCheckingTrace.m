#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>

// Temporary, opt-in diagnostic. No text or service results are changed.
static IMP originalCheckString;
static IMP originalCheckSpelling;
static NSArray *traceCheckString(id receiver, SEL selector, NSString *text,
    NSRange range, NSTextCheckingTypes types, NSDictionary *options, NSInteger tag,
    NSOrthography **orthography, NSInteger *wordCount)
{
    uint64_t start = mach_absolute_time();
    fprintf(stderr, "Vane sync checking start: selector=checkString tick=%llu main=%d tag=%ld\n", start, [NSThread isMainThread], (long)tag);
    NSArray *result = ((NSArray *(*)(id, SEL, NSString *, NSRange, NSTextCheckingTypes, NSDictionary *, NSInteger, NSOrthography **, NSInteger *))originalCheckString)(receiver, selector, text, range, types, options, tag, orthography, wordCount);
    fprintf(stderr, "Vane sync checking end: selector=checkString tick=%llu start=%llu\n", mach_absolute_time(), start);
    return result;
}
static NSRange traceCheckSpelling(id receiver, SEL selector, NSString *text,
    NSInteger offset, NSString *language, BOOL wrap, NSInteger tag, NSInteger *wordCount)
{
    uint64_t start = mach_absolute_time();
    fprintf(stderr, "Vane sync checking start: selector=checkSpelling tick=%llu main=%d tag=%ld\n", start, [NSThread isMainThread], (long)tag);
    NSRange result = ((NSRange (*)(id, SEL, NSString *, NSInteger, NSString *, BOOL, NSInteger, NSInteger *))originalCheckSpelling)(receiver, selector, text, offset, language, wrap, tag, wordCount);
    fprintf(stderr, "Vane sync checking end: selector=checkSpelling tick=%llu start=%llu\n", mach_absolute_time(), start);
    return result;
}
__attribute__((constructor)) static void installSyncCheckingTrace(void)
{
    if (!getenv("VANE_TRACE_SYNC_CHECKING")) return;
    Class checker = [NSSpellChecker class];
    Method string = class_getInstanceMethod(checker, @selector(checkString:range:types:options:inSpellDocumentWithTag:orthography:wordCount:));
    Method spelling = class_getInstanceMethod(checker, @selector(checkSpellingOfString:startingAt:language:wrap:inSpellDocumentWithTag:wordCount:));
    if (!string || !spelling) abort();
    originalCheckString = method_setImplementation(string, (IMP)traceCheckString);
    originalCheckSpelling = method_setImplementation(spelling, (IMP)traceCheckSpelling);
    fprintf(stderr, "Vane sync checking trace installed\n");
}
