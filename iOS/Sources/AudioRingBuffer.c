// SPDX-License-Identifier: GPL-3.0-only
//
// SPSC byte ring implementation. See AudioRingBuffer.h for the contract.
//
// Memory model:
//   * `head` (write index) is written only by the producer, read by the consumer.
//   * `tail` (read index) is written only by the consumer, read by the producer.
//   * The producer publishes data with a release store to `head` after the byte
//     copy; the consumer acquires `head` before reading the bytes.
//   * The consumer publishes freed space with a release store to `tail` after
//     reading; the producer acquires `tail` before reusing that space.
//   With one writer per counter, no compare-and-swap loop or ABA handling is
//   needed; operations below are wait-free on a lock-free _Atomic size_t.
//
#include "AudioRingBuffer.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct AMRing {
    uint8_t *storage;
    size_t capacity;      // usable bytes (> 0)
    size_t mask;          // capacity - 1 (capacity is a power of two)
    _Atomic size_t head;  // monotonic total bytes written by the producer
    _Atomic size_t tail;  // monotonic total bytes read by the consumer
    bool lock_free;
};

static size_t am_next_power_of_two(size_t value) {
    size_t result = 1;
    while (result < value) {
        result <<= 1;
    }
    return result;
}

AMRing *AMRing_create(size_t capacity_bytes) {
    if (capacity_bytes == 0) {
        return NULL;
    }
    size_t capacity = am_next_power_of_two(capacity_bytes);
    AMRing *ring = (AMRing *)calloc(1, sizeof(AMRing));
    if (ring == NULL) {
        return NULL;
    }
    ring->storage = (uint8_t *)malloc(capacity);
    if (ring->storage == NULL) {
        free(ring);
        return NULL;
    }
    ring->capacity = capacity;
    ring->mask = capacity - 1;
    atomic_init(&ring->head, 0);
    atomic_init(&ring->tail, 0);
    // Honest capability check: on Apple arm64/x86_64 this is true.
    ring->lock_free = atomic_is_lock_free(&ring->head) && atomic_is_lock_free(&ring->tail);
    return ring;
}

void AMRing_destroy(AMRing *ring) {
    if (ring == NULL) {
        return;
    }
    free(ring->storage);
    free(ring);
}

bool AMRing_is_lock_free(const AMRing *ring) {
    return ring != NULL && ring->lock_free;
}

size_t AMRing_capacity(const AMRing *ring) {
    return ring == NULL ? 0 : ring->capacity;
}

size_t AMRing_available(const AMRing *ring) {
    if (ring == NULL) {
        return 0;
    }
    size_t head = atomic_load_explicit(&ring->head, memory_order_acquire);
    size_t tail = atomic_load_explicit(&ring->tail, memory_order_acquire);
    return head - tail;
}

size_t AMRing_free_space(const AMRing *ring) {
    if (ring == NULL) {
        return 0;
    }
    return ring->capacity - AMRing_available(ring);
}

size_t AMRing_write(AMRing *ring, const void *src, size_t length) {
    if (ring == NULL || src == NULL || length == 0) {
        return 0;
    }
    size_t head = atomic_load_explicit(&ring->head, memory_order_relaxed);
    size_t tail = atomic_load_explicit(&ring->tail, memory_order_acquire);
    size_t used = head - tail;
    if (used >= ring->capacity) {
        return 0; // full
    }
    size_t free_bytes = ring->capacity - used;
    size_t to_write = length < free_bytes ? length : free_bytes;

    // Copy in at most two spans because a block may straddle the wrap point.
    size_t offset = head & ring->mask;
    size_t first = ring->capacity - offset;
    if (first > to_write) {
        first = to_write;
    }
    memcpy(ring->storage + offset, src, first);
    size_t remaining = to_write - first;
    if (remaining > 0) {
        memcpy(ring->storage, (const uint8_t *)src + first, remaining);
    }

    // Publish the new write index only after the bytes are in place.
    atomic_store_explicit(&ring->head, head + to_write, memory_order_release);
    return to_write;
}

size_t AMRing_read(AMRing *ring, void *dst, size_t length) {
    if (ring == NULL || dst == NULL || length == 0) {
        return 0;
    }
    size_t tail = atomic_load_explicit(&ring->tail, memory_order_relaxed);
    size_t head = atomic_load_explicit(&ring->head, memory_order_acquire);
    size_t used = head - tail;
    if (used == 0) {
        return 0; // empty
    }
    size_t to_read = length < used ? length : used;

    size_t offset = tail & ring->mask;
    size_t first = ring->capacity - offset;
    if (first > to_read) {
        first = to_read;
    }
    memcpy(dst, ring->storage + offset, first);
    size_t remaining = to_read - first;
    if (remaining > 0) {
        memcpy((uint8_t *)dst + first, ring->storage, remaining);
    }

    atomic_store_explicit(&ring->tail, tail + to_read, memory_order_release);
    return to_read;
}

size_t AMRing_discard(AMRing *ring, size_t length) {
    if (ring == NULL || length == 0) {
        return 0;
    }
    size_t tail = atomic_load_explicit(&ring->tail, memory_order_relaxed);
    size_t head = atomic_load_explicit(&ring->head, memory_order_acquire);
    size_t used = head - tail;
    if (used == 0) {
        return 0;
    }
    size_t to_drop = length < used ? length : used;
    atomic_store_explicit(&ring->tail, tail + to_drop, memory_order_release);
    return to_drop;
}

void AMRing_reset(AMRing *ring) {
    if (ring == NULL) {
        return;
    }
    size_t head = atomic_load_explicit(&ring->head, memory_order_acquire);
    atomic_store_explicit(&ring->tail, head, memory_order_release);
}
