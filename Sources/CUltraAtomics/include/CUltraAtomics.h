#ifndef CULTRAATOMICS_H
#define CULTRAATOMICS_H

// Minimal C11 atomics on plain Int64 storage, used by the Swift jitter buffer so the network thread and
// the real-time audio thread can share state without locks (same memory orders as the C++ reference).

#include <stdint.h>
#include <stdbool.h>
#include <stdatomic.h>

static inline int64_t ua_load (int64_t *p)
{
    return atomic_load_explicit ((_Atomic (int64_t) *) p, memory_order_acquire);
}

static inline void ua_store (int64_t *p, int64_t v)
{
    atomic_store_explicit ((_Atomic (int64_t) *) p, v, memory_order_release);
}

static inline int64_t ua_fetch_add (int64_t *p, int64_t v)
{
    return atomic_fetch_add_explicit ((_Atomic (int64_t) *) p, v, memory_order_relaxed);
}

// Raises *p to v if v is larger (returns the final value)
static inline int64_t ua_store_max (int64_t *p, int64_t v)
{
    int64_t cur = atomic_load_explicit ((_Atomic (int64_t) *) p, memory_order_relaxed);
    while (v > cur && ! atomic_compare_exchange_weak_explicit ((_Atomic (int64_t) *) p, &cur, v,
                                                               memory_order_release, memory_order_relaxed)) {}
    return v > cur ? v : cur;
}

#endif
