// Atomic operations on a word for PhysicsThreads.swift's worker pool (Swift has no atomics on macOS 13 without a
// package): C11's, on a plain intptr_t the Swift side owns.
#pragma once
#include <stdatomic.h>
#include <stdint.h>
#include <stdbool.h>

static inline intptr_t cpa_load(intptr_t *p) { return atomic_load_explicit((_Atomic intptr_t *)p, memory_order_acquire); }
static inline void cpa_store(intptr_t *p, intptr_t v) { atomic_store_explicit((_Atomic intptr_t *)p, v, memory_order_release); }
static inline intptr_t cpa_add(intptr_t *p, intptr_t v) {
    return atomic_fetch_add_explicit((_Atomic intptr_t *)p, v, memory_order_acq_rel);
}
static inline bool cpa_cas(intptr_t *p, intptr_t expected, intptr_t desired) {
    return atomic_compare_exchange_weak_explicit((_Atomic intptr_t *)p, &expected, desired,
                                                 memory_order_acq_rel, memory_order_acquire);
}
/// A spinning thread's hint to the core (arm64's yield, x86's pause).
static inline void cpa_pause(void) {
#if defined(__aarch64__)
    __asm__ __volatile__("yield");
#elif defined(__x86_64__)
    __asm__ __volatile__("pause");
#endif
}
