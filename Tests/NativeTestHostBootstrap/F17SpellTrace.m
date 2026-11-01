#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "NativeTestHostBootstrap.h"
#include <mach/mach_time.h>
#include <os/lock.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Diagnostic only. No Objective-C message is sent while installing the factory
// observer. In particular, setup must not fetch/create the spell-checker singleton.
// This file has no constructor and does nothing unless this exact flag is enabled.
typedef void (^CandidateReply)(NSInteger, NSArray<NSTextCheckingResult *> *);
typedef id (*SharedIMP)(id, SEL);
typedef NSInteger (*CandidateIMP)(id, SEL, NSRange, NSString *, NSTextCheckingTypes,
                                 NSDictionary<NSTextCheckingOptionKey, id> *, NSInteger, CandidateReply);

enum { Capacity = 512 };
enum { PhaseEvent = 1, SharedStart, SharedReturn, CandidateStart, CandidateReturn,
       WaitStart, WaitFunctionExit, WaitSuccess, WaitFailure };
enum { MissingMethod = 1, BadABI = 2, ForeignIMP = 4, ReceiverChanged = 8,
       RepeatedBegin = 16, InFlightAtClose = 32, SDKException = 64, AmbiguousMethod = 128,
       ThreadIDUnavailable = 256 };
typedef struct {
    _Atomic(bool) published;
    uint64_t tick, call;
    uintptr_t receiver, dynamicClass;
    NSInteger tag, sequence;
    NSRange range;
    NSTextCheckingTypes checkingTypes;
    uint64_t threadID;
    bool mainThread;
    uint32_t kind, phase;
} Event;
typedef struct {
    Method method;
    Class owner;
    IMP wrapper;
    _Atomic(IMP) original;
    bool installed, restored;
} Hook;

// Intentionally process-lifetime: restoring a Method and observing zero in-flight
// calls cannot exclude a thread which fetched the old IMP but has not entered yet.
// Static function text and this forwarding state remain valid even after End/Emit.
static Event events[Capacity];
static Hook factoryHook, candidateHook;
static Class spellClass;
static os_unfair_lock hookLock = OS_UNFAIR_LOCK_INIT;
static _Atomic(bool) requested, recording;
static _Atomic(uint32_t) phase, problems, inFlight;
static _Atomic(uint64_t) eventCount, calls, nonmatching;
static _Atomic(uintptr_t) receiverIdentity, receiverClass;
static uint32_t closeInFlight;
static uint64_t bindingTicks;
static IMP capturedFactory, capturedCandidate;

static void recordRequest(uint32_t kind, uint64_t call, id receiver, NSInteger tag, NSInteger sequence,
                          NSRange range, NSTextCheckingTypes checkingTypes)
{
    if (!atomic_load(&recording)) return;
    uint64_t slot = atomic_fetch_add(&eventCount, 1);
    if (slot >= Capacity) return;
    Event *event = &events[slot];
    event->tick = mach_continuous_time();
    event->call = call;
    event->receiver = (uintptr_t)(__bridge void *)receiver;
    event->dynamicClass = (uintptr_t)(__bridge void *)object_getClass(receiver);
    event->tag = tag;
    event->sequence = sequence;
    event->range = range;
    event->checkingTypes = checkingTypes;
    if (pthread_threadid_np(NULL, &event->threadID) != 0)
        atomic_fetch_or(&problems, ThreadIDUnavailable);
    event->mainThread = pthread_main_np() != 0;
    event->kind = kind;
    event->phase = atomic_load(&phase);
    atomic_store_explicit(&event->published, true, memory_order_release);
}

static void record(uint32_t kind, uint64_t call, id receiver, NSInteger tag, NSInteger sequence)
{
    recordRequest(kind, call, receiver, tag, sequence, NSMakeRange(0, 0), 0);
}

// Unlike resolver-based lookup, enumeration does not ask a class to implement a
// missing selector. Runtime metadata realization still has observation overhead.
static Method declaredMethod(Class cls, SEL selector)
{
    unsigned count = 0;
    Method *list = class_copyMethodList(cls, &count);
    Method found = NULL;
    unsigned matches = 0;
    for (unsigned i = 0; i < count; ++i) {
        if (sel_isEqual(method_getName(list[i]), selector)) { found = list[i]; ++matches; }
    }
    free(list);
    if (matches > 1) { atomic_fetch_or(&problems, AmbiguousMethod); return NULL; }
    return found;
}

static bool sameType(char *actual, const char *expected)
{
    bool same = actual && strcmp(actual, expected) == 0;
    free(actual);
    return same;
}

static bool validABI(Method method, bool factory)
{
    const char *arguments[] = { @encode(id), @encode(SEL), @encode(NSRange), @encode(NSString *),
        @encode(NSTextCheckingTypes), @encode(NSDictionary *), @encode(NSInteger), @encode(CandidateReply) };
    unsigned count = factory ? 2 : 8;
    if (method_getNumberOfArguments(method) != count ||
        !sameType(method_copyReturnType(method), factory ? @encode(id) : @encode(NSInteger))) return false;
    for (unsigned i = 0; i < count; ++i)
        if (!sameType(method_copyArgumentType(method, i), arguments[i])) return false;
    return true;
}

// Installation/restoration require exclusive ownership of these two selectors
// within this test host. Public runtime APIs have no compare-and-swap for Method.
// A competing mutator makes the sample invalid; never hide that conflict.
static bool install(Hook *hook, Method method, Class owner, IMP wrapper, bool factory)
{
    if (!method) { atomic_fetch_or(&problems, MissingMethod); return false; }
    if (!validABI(method, factory)) { atomic_fetch_or(&problems, BadABI); return false; }
    IMP original = method_getImplementation(method);
    hook->method = method;
    hook->owner = owner;
    hook->wrapper = wrapper;
    atomic_store(&hook->original, original);
    IMP previous = method_setImplementation(method, wrapper);
    hook->installed = true;
    if (previous != original) {
        atomic_fetch_or(&problems, ForeignIMP);
        // Preserve the actual displaced implementation, not our stale snapshot.
        atomic_store(&hook->original, previous);
        if (method_getImplementation(method) == wrapper) {
            method_setImplementation(method, previous);
            hook->restored = true;
        }
        return false;
    }
    return true;
}

static NSInteger candidate(id self, SEL selector, NSRange range, NSString *string,
                           NSTextCheckingTypes types, NSDictionary<NSTextCheckingOptionKey, id> *options,
                           NSInteger tag, CandidateReply completion)
{
    atomic_fetch_add(&inFlight, 1);
    CandidateIMP original = (CandidateIMP)atomic_load(&candidateHook.original);
    bool bound = (uintptr_t)(__bridge void *)self == atomic_load(&receiverIdentity);
    bool sameClass = (uintptr_t)(__bridge void *)object_getClass(self) == atomic_load(&receiverClass);
    bool matches = bound && sameClass;
    if (bound && !sameClass) atomic_fetch_or(&problems, ReceiverChanged);
    uint64_t call = atomic_fetch_add(&calls, 1) + 1;
    if (matches) recordRequest(CandidateStart, call, self, tag, 0, range, types);
    else atomic_fetch_add(&nonmatching, 1);
    bool returned = false;
    @try {
        NSInteger sequence = original(self, selector, range, string, types, options, tag, completion);
        returned = true;
        if (matches) recordRequest(CandidateReturn, call, self, tag, sequence, range, types);
        return sequence;
    } @finally {
        if (!returned) atomic_fetch_or(&problems, SDKException);
        atomic_fetch_sub(&inFlight, 1);
    }
}

static void bindNaturalReceiver(id receiver)
{
    os_unfair_lock_lock(&hookLock);
    if (!atomic_load(&recording)) { os_unfair_lock_unlock(&hookLock); return; }
    uintptr_t identity = (uintptr_t)(__bridge void *)receiver;
    Class cls = object_getClass(receiver);
    uintptr_t bound = atomic_load(&receiverIdentity);
    if (bound) {
        if (bound != identity || atomic_load(&receiverClass) != (uintptr_t)(__bridge void *)cls)
            atomic_fetch_or(&problems, ReceiverChanged);
        if (candidateHook.installed && method_getImplementation(candidateHook.method) != candidateHook.wrapper)
            atomic_fetch_or(&problems, ForeignIMP);
        os_unfair_lock_unlock(&hookLock);
        return;
    }
    uint64_t started = mach_continuous_time();
    bool belongs = false;
    for (Class ancestor = cls; ancestor; ancestor = class_getSuperclass(ancestor))
        if (ancestor == spellClass) { belongs = true; break; }
    if (!receiver || !belongs) atomic_fetch_or(&problems, ReceiverChanged);
    else {
        SEL selector = @selector(requestCandidatesForSelectedRange:inString:types:options:inSpellDocumentWithTag:completionHandler:);
        Class owner = cls;
        Method method = NULL;
        for (; owner && !method; owner = class_getSuperclass(owner)) {
            method = declaredMethod(owner, selector);
            if (atomic_load(&problems) & AmbiguousMethod) { method = NULL; break; }
            if (method) break;
        }
        atomic_store(&receiverIdentity, identity);
        atomic_store(&receiverClass, (uintptr_t)(__bridge void *)cls);
        install(&candidateHook, method, owner, (IMP)candidate, false);
    }
    bindingTicks += mach_continuous_time() - started;
    os_unfair_lock_unlock(&hookLock);
}

static id shared(id self, SEL selector)
{
    atomic_fetch_add(&inFlight, 1);
    SharedIMP original = (SharedIMP)atomic_load(&factoryHook.original);
    bool matches = self == spellClass;
    uint64_t call = atomic_fetch_add(&calls, 1) + 1;
    if (matches) record(SharedStart, call, self, 0, 0);
    else atomic_fetch_add(&nonmatching, 1);
    bool returned = false;
    @try {
        id result = original(self, selector);
        returned = true;
        if (matches) {
            record(SharedReturn, call, result, 0, 0);
            bindNaturalReceiver(result);
        }
        return result;
    } @finally {
        if (!returned) atomic_fetch_or(&problems, SDKException);
        atomic_fetch_sub(&inFlight, 1);
    }
}

bool VaneF17SpellTraceBegin(void)
{
    const char *flag = getenv("VANE_F17_CANDIDATE_LATENCY_TRACE_V1");
    if (!flag || strcmp(flag, "1") != 0) return false;
    if (atomic_exchange(&requested, true)) { atomic_fetch_or(&problems, RepeatedBegin); return true; }
    os_unfair_lock_lock(&hookLock);
    spellClass = objc_lookUpClass("NSSpellChecker");
    Class meta = object_getClass(spellClass);
    Method method = declaredMethod(meta, @selector(sharedSpellChecker));
    atomic_store(&recording, true);
    install(&factoryHook, method, meta, (IMP)shared, true);
    os_unfair_lock_unlock(&hookLock);
    return true;
}

void VaneF17SpellTracePhase(uint32_t value)
{
    if (!atomic_load(&recording)) return;
    atomic_store(&phase, value);
    record(PhaseEvent, 0, nil, 0, 0);
}

void VaneF17SpellTraceWaitBoundary(bool entering)
{
    record(entering ? WaitStart : WaitFunctionExit, 0, nil, 0, 0);
}

void VaneF17SpellTraceWaitOutcome(bool success)
{
    record(success ? WaitSuccess : WaitFailure, 0, nil, 0, 0);
}

static void restore(Hook *hook)
{
    if (!hook->installed || hook->restored) return;
    if (declaredMethod(hook->owner, method_getName(hook->method)) != hook->method ||
        method_getImplementation(hook->method) != hook->wrapper) {
        atomic_fetch_or(&problems, ForeignIMP);
        return;
    }
    IMP previous = method_setImplementation(hook->method, atomic_load(&hook->original));
    hook->restored = previous == hook->wrapper;
    if (!hook->restored) {
        atomic_fetch_or(&problems, ForeignIMP);
        // Best-effort rollback of the displaced foreign IMP. No public runtime
        // API offers a CAS here: concurrent selector mutation is unsupported and
        // permanently invalidates this sample, even if rollback appears to work.
        if (method_getImplementation(hook->method) == atomic_load(&hook->original))
            method_setImplementation(hook->method, previous);
    }
}

void VaneF17SpellTraceEnd(void)
{
    if (!atomic_load(&requested)) return;
    atomic_store(&recording, false);
    os_unfair_lock_lock(&hookLock);
    restore(&factoryHook);
    restore(&candidateHook);
    uint32_t active = atomic_load(&inFlight);
    if (active > closeInFlight) closeInFlight = active;
    if (active) atomic_fetch_or(&problems, InFlightAtClose);
    os_unfair_lock_unlock(&hookLock);
}

VaneF17SpellTraceStatus VaneF17SpellTraceReadStatus(void)
{
    VaneF17SpellTraceStatus status = {0};
    os_unfair_lock_lock(&hookLock);
    status.requested = atomic_load(&requested);
    status.recording = atomic_load(&recording);
    status.factoryInstalled = factoryHook.installed;
    status.factoryRestored = factoryHook.restored;
    status.factoryOriginalNow = factoryHook.restored &&
        method_getImplementation(factoryHook.method) == atomic_load(&factoryHook.original);
    status.candidateInstalled = candidateHook.installed;
    status.candidateRestored = candidateHook.restored;
    status.candidateOriginalNow = candidateHook.restored &&
        method_getImplementation(candidateHook.method) == atomic_load(&candidateHook.original);
    status.closeInFlight = closeInFlight;
    status.problems = atomic_load(&problems);
    status.inFlight = atomic_load(&inFlight);
    status.receiver = atomic_load(&receiverIdentity);
    os_unfair_lock_unlock(&hookLock);
    status.eventCount = atomic_load(&eventCount);
    status.dropped = status.eventCount > Capacity ? status.eventCount - Capacity : 0;
    for (uint64_t i = 0; i < status.eventCount && i < Capacity; ++i) {
        Event *event = &events[i];
        if (!atomic_load_explicit(&event->published, memory_order_acquire)) { ++status.unpublished; continue; }
        switch (event->kind) {
            case SharedStart: ++status.sharedStarts; break;
            case SharedReturn: ++status.sharedReturns; break;
            case CandidateStart: ++status.candidateStarts; break;
            case CandidateReturn: ++status.candidateReturns; break;
            case WaitSuccess: ++status.waitSuccesses; break;
            case WaitFailure: ++status.waitFailures; break;
            case WaitFunctionExit: ++status.waitExits; break;
        }
    }
    return status;
}

uintptr_t VaneF17SpellTraceFactoryCurrentIMP(void)
{
    Class meta = object_getClass(objc_lookUpClass("NSSpellChecker"));
    Method method = declaredMethod(meta, @selector(sharedSpellChecker));
    return method ? (uintptr_t)method_getImplementation(method) : 0;
}

bool VaneF17SpellTraceCaptureOwnedIMPs(void)
{
    os_unfair_lock_lock(&hookLock);
    bool owned = atomic_load(&recording) && factoryHook.installed && candidateHook.installed &&
        method_getImplementation(factoryHook.method) == factoryHook.wrapper &&
        method_getImplementation(candidateHook.method) == candidateHook.wrapper;
    if (owned) {
        capturedFactory = factoryHook.wrapper;
        capturedCandidate = candidateHook.wrapper;
    }
    os_unfair_lock_unlock(&hookLock);
    return owned;
}

NSSpellChecker *VaneF17SpellTraceCallCapturedFactory(void)
{
    // Control-only precondition, not a synthetic SDK response on invalid setup.
    if (!capturedFactory) abort();
    return ((SharedIMP)capturedFactory)(spellClass, @selector(sharedSpellChecker));
}

NSInteger VaneF17SpellTraceCallCapturedCandidate(NSSpellChecker *receiver, NSRange range, NSString *string,
    NSTextCheckingTypes types, NSDictionary<NSTextCheckingOptionKey, id> *options, NSInteger tag,
    void (^completion)(NSInteger, NSArray<NSTextCheckingResult *> *))
{
    if (!capturedCandidate || !VaneF17SpellTraceIsBoundReceiver(receiver)) abort();
    return ((CandidateIMP)capturedCandidate)(receiver,
        @selector(requestCandidatesForSelectedRange:inString:types:options:inSpellDocumentWithTag:completionHandler:),
        range, string, types, options, tag, completion);
}

bool VaneF17SpellTraceIsBoundReceiver(NSSpellChecker *receiver)
{
    return (uintptr_t)(__bridge void *)receiver == atomic_load(&receiverIdentity) &&
        (uintptr_t)(__bridge void *)object_getClass(receiver) == atomic_load(&receiverClass);
}

bool VaneF17SpellTraceHasCandidateResult(NSRange range, NSTextCheckingTypes types, NSInteger tag, NSInteger sequence)
{
    uint64_t count = atomic_load(&eventCount);
    for (uint64_t i = 0; i < count && i < Capacity; ++i) {
        Event *returned = &events[i];
        if (!atomic_load_explicit(&returned->published, memory_order_acquire) || returned->kind != CandidateReturn ||
            returned->tag != tag || returned->sequence != sequence || returned->checkingTypes != types ||
            returned->range.location != range.location || returned->range.length != range.length) continue;
        for (uint64_t j = 0; j < i; ++j) {
            Event *start = &events[j];
            if (atomic_load_explicit(&start->published, memory_order_acquire) && start->kind == CandidateStart &&
                start->call == returned->call && start->tag == tag && start->checkingTypes == types &&
                start->range.location == range.location && start->range.length == range.length) return true;
        }
    }
    return false;
}

void VaneF17SpellTraceEmit(void)
{
    if (!atomic_load(&requested)) return;
    // Caller must finish fixture assertions, window teardown and actual loop join
    // before End/Emit. Never log synchronously from an observed SDK entrypoint.
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    os_unfair_lock_lock(&hookLock);
    bool factoryOriginalNow = factoryHook.restored &&
        method_getImplementation(factoryHook.method) == atomic_load(&factoryHook.original);
    bool candidateOriginalNow = candidateHook.restored &&
        method_getImplementation(candidateHook.method) == atomic_load(&candidateHook.original);
    if ((factoryHook.restored && !factoryOriginalNow) || (candidateHook.restored && !candidateOriginalNow))
        atomic_fetch_or(&problems, ForeignIMP);
    os_unfair_lock_unlock(&hookLock);
    uint64_t count = atomic_load(&eventCount);
    uint64_t unpublished = 0;
    for (uint64_t i = 0; i < count && i < Capacity; ++i) {
        Event *event = &events[i];
        if (!atomic_load_explicit(&event->published, memory_order_acquire)) { ++unpublished; continue; }
        fprintf(stderr, "F17_SPELL event=%llu kind=%u phase=%u tick=%llu call=%llu receiver=%llx class=%llx tag=%ld sequence=%ld range=%llu,%llu checkingTypes=%llu thread=%llu mainThread=%d\n",
                (unsigned long long)i, event->kind, event->phase, (unsigned long long)event->tick,
                (unsigned long long)event->call, (unsigned long long)event->receiver,
                (unsigned long long)event->dynamicClass, (long)event->tag, (long)event->sequence,
                (unsigned long long)event->range.location, (unsigned long long)event->range.length,
                (unsigned long long)event->checkingTypes, (unsigned long long)event->threadID, event->mainThread);
    }
    fprintf(stderr, "F17_SPELL footer problems=%u recorded=%llu dropped=%llu unpublished=%llu closeInFlight=%u currentInFlight=%u factoryInstalled=%d factoryRestored=%d factoryOriginalNow=%d candidateInstalled=%d candidateRestored=%d candidateOriginalNow=%d bindingTicks=%llu nonmatching=%llu clock=mach_continuous_time timebase=%u/%u tagAttribution=page-not-field preFactoryInitialization=UNOBSERVED preBindingCalls=UNKNOWN indefiniteHangBuffer=NOT-PERSISTENT waitEntry=after-original-5s-deadline-construction functionExit=may-follow-diagnostics longSpanBlockingCause=UNKNOWN\n",
            atomic_load(&problems), (unsigned long long)(count < Capacity ? count : Capacity),
            (unsigned long long)(count > Capacity ? count - Capacity : 0), (unsigned long long)unpublished,
            closeInFlight, atomic_load(&inFlight), factoryHook.installed, factoryHook.restored, factoryOriginalNow,
            candidateHook.installed, candidateHook.restored, candidateOriginalNow,
            (unsigned long long)bindingTicks, (unsigned long long)atomic_load(&nonmatching),
            timebase.numer, timebase.denom);
}
