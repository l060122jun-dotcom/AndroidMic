// SPDX-License-Identifier: GPL-3.0-only
//
// AudioRingBuffer: a small single-producer / single-consumer (SPSC) byte ring
// used to hand PCM blocks from the Core Audio render thread to a normal
// consumer thread without allocating, locking or dispatching on the render
// thread.
//
// Design notes / honest limitations:
//   * This is SPSC only. Exactly one thread may call AMRing_write and exactly
//     one (different) thread may call AMRing_read at a time.
//   * It is lock-free *only if* the platform's _Atomic size_t operations are
//     lock-free. ATOMIC_SIZE_T is checked at init with atomic_is_lock_free();
//     AMRing_is_lock_free() reports the result. On Apple arm64/x86_64 it is
//     lock-free. If it ever were not, the ring would silently fall back to
//     whatever the C runtime uses for non-lock-free atomics; callers that
//     require a hard guarantee should check AMRing_is_lock_free() first.
//   * The ring never allocates or frees memory after AMRing_create.
//   * No claim is made that this removes end-to-end latency; it only removes
//     allocation and thread-hop cost from the capture path.
//
#ifndef AUDIO_RING_BUFFER_H
#define AUDIO_RING_BUFFER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AMRing AMRing;

// Create a ring whose storage holds exactly `capacity_bytes` user bytes.
// Capacity is rounded up internally as needed to keep index math simple.
// Returns NULL on allocation failure or if capacity_bytes == 0.
AMRing *AMRing_create(size_t capacity_bytes);

// Destroy a ring. The caller MUST guarantee that no thread is inside
// AMRing_write / AMRing_read (e.g. stop the audio engine first).
void AMRing_destroy(AMRing *ring);

// True if _Atomic size_t is lock-free on this platform (checked at create).
bool AMRing_is_lock_free(const AMRing *ring);

// Usable capacity in bytes.
size_t AMRing_capacity(const AMRing *ring);

// Bytes currently readable.
size_t AMRing_available(const AMRing *ring);

// Bytes currently writable before the ring is full.
size_t AMRing_free_space(const AMRing *ring);

// Producer: copy up to `length` bytes. Returns the number of bytes actually
// written (0 if the ring is full, or fewer than `length` if it would overfill).
// Never blocks, never allocates.
size_t AMRing_write(AMRing *ring, const void *src, size_t length);

// Consumer: copy up to `length` bytes into `dst`. Returns bytes read (0 if
// empty). Never blocks, never allocates.
size_t AMRing_read(AMRing *ring, void *dst, size_t length);

// Consumer: discard up to `length` bytes. Returns bytes discarded.
size_t AMRing_discard(AMRing *ring, size_t length);

// Reset the ring to empty. Must not be called concurrently with read/write.
void AMRing_reset(AMRing *ring);

#ifdef __cplusplus
}
#endif

#endif // AUDIO_RING_BUFFER_H
