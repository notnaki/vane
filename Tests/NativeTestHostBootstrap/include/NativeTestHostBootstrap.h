#ifndef VANE_NATIVE_TEST_HOST_BOOTSTRAP_H
#define VANE_NATIVE_TEST_HOST_BOOTSTRAP_H

#include <stdbool.h>
#include <stdint.h>

bool VaneNativeTestHostBootstrapRan(void);
bool VaneNativeTestHostBootstrapWasEarly(void);
bool VaneNativeTestHostBootstrapConfigured(void);

// Test-only, default-off, one generation per native host. No accessor is fetched
// during Begin. End/Emit belong after owned fixture cleanup and AppKit loop join.
bool VaneF17SpellTraceBegin(void);
void VaneF17SpellTracePhase(uint32_t phase);
void VaneF17SpellTraceWaitBoundary(bool entering);
void VaneF17SpellTraceWaitOutcome(bool success);
void VaneF17SpellTraceEnd(void);
void VaneF17SpellTraceEmit(void);

// Focused source-only control support; no SDK accessor is invoked by inspection.
typedef struct {
    bool requested, recording, factoryInstalled, factoryRestored, factoryOriginalNow;
    bool candidateInstalled, candidateRestored, candidateOriginalNow;
    uint32_t problems, inFlight, closeInFlight;
    uint64_t eventCount, dropped, unpublished, sharedStarts, sharedReturns;
    uint64_t candidateStarts, candidateReturns, waitSuccesses, waitFailures, waitExits;
    uintptr_t receiver;
} VaneF17SpellTraceStatus;
VaneF17SpellTraceStatus VaneF17SpellTraceReadStatus(void);
uintptr_t VaneF17SpellTraceFactoryCurrentIMP(void);
bool VaneF17SpellTraceCaptureOwnedIMPs(void);

#ifdef __OBJC__
#import <AppKit/AppKit.h>
NSSpellChecker * _Nullable VaneF17SpellTraceCallCapturedFactory(void);
bool VaneF17SpellTraceIsBoundReceiver(NSSpellChecker * _Nonnull receiver);
NSInteger VaneF17SpellTraceCallCapturedCandidate(NSSpellChecker * _Nonnull receiver, NSRange range,
    NSString * _Nonnull string, NSTextCheckingTypes types,
    NSDictionary<NSTextCheckingOptionKey, id> * _Nullable options, NSInteger tag,
    void (^ _Nullable completion)(NSInteger, NSArray<NSTextCheckingResult *> * _Nonnull));
bool VaneF17SpellTraceHasCandidateResult(NSRange range, NSTextCheckingTypes types, NSInteger tag, NSInteger sequence);
#endif

#endif
