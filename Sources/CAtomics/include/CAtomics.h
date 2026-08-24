// CAtomics.h
// Real-time-safe atomic primitives for DisplayVolume's audio path.
//
// Swift (before the Synchronization module, which needs macOS 15) has no
// standard-library atomics, so these thin wrappers over C11 stdatomic.h are
// used to pass volume/mute/counter values between the UI thread and the
// Core Audio real-time callbacks. All operations are lock-free on arm64 and
// x86_64 (asserted below) and never allocate.

#ifndef DV_CATOMICS_H
#define DV_CATOMICS_H

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

// The structs hold plain values; the accessor functions cast the field to an
// _Atomic-qualified pointer. This keeps the structs importable into Swift
// (Swift cannot import _Atomic fields directly). This is the same technique
// the swift-atomics package uses for its C shims. The value must only be
// accessed through these functions once shared between threads.

typedef struct { float    _value; } DVAtomicF32;
typedef struct { uint32_t _value; } DVAtomicU32;
typedef struct { uint64_t _value; } DVAtomicU64;

_Static_assert(sizeof(float) == sizeof(uint32_t), "float must be 32-bit");

// --- Float32 -----------------------------------------------------------

static inline void dv_f32_store(DVAtomicF32 *_Nonnull p, float value) {
    atomic_store_explicit((volatile _Atomic float *)&p->_value, value,
                          memory_order_release);
}

static inline float dv_f32_load(const DVAtomicF32 *_Nonnull p) {
    return atomic_load_explicit((volatile _Atomic float *)&p->_value,
                                memory_order_acquire);
}

// --- UInt32 (used for flags/booleans; 0 = false) ------------------------

static inline void dv_u32_store(DVAtomicU32 *_Nonnull p, uint32_t value) {
    atomic_store_explicit((volatile _Atomic uint32_t *)&p->_value, value,
                          memory_order_release);
}

static inline uint32_t dv_u32_load(const DVAtomicU32 *_Nonnull p) {
    return atomic_load_explicit((volatile _Atomic uint32_t *)&p->_value,
                                memory_order_acquire);
}

// --- UInt64 (ring-buffer positions and diagnostic counters) -------------

static inline void dv_u64_store(DVAtomicU64 *_Nonnull p, uint64_t value) {
    atomic_store_explicit((volatile _Atomic uint64_t *)&p->_value, value,
                          memory_order_release);
}

static inline uint64_t dv_u64_load(const DVAtomicU64 *_Nonnull p) {
    return atomic_load_explicit((volatile _Atomic uint64_t *)&p->_value,
                                memory_order_acquire);
}

static inline uint64_t dv_u64_add(DVAtomicU64 *_Nonnull p, uint64_t delta) {
    return atomic_fetch_add_explicit((volatile _Atomic uint64_t *)&p->_value,
                                     delta, memory_order_acq_rel);
}

#if defined(__cplusplus)
}
#endif

#endif /* DV_CATOMICS_H */
