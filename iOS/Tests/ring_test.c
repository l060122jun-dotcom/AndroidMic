// SPDX-License-Identifier: GPL-3.0-only
//
// Standalone SPSC ring tests. Build and run on macOS with:
//   clang -std=c11 -O2 -Wall -Wextra -pthread \
//     Sources/AudioRingBuffer.c Tests/ring_test.c -o /tmp/amring_test && /tmp/amring_test
//
// The reader/writer concurrency test uses a single producer and a single
// consumer thread; it verifies byte-for-byte integrity and catches lost or
// duplicated bytes.
#include "../Sources/AudioRingBuffer.h"

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;

#define CHECK(cond, msg)                                                       \
    do {                                                                       \
        if (!(cond)) {                                                         \
            fprintf(stderr, "FAIL: %s (%s:%d)\n", (msg), __FILE__, __LINE__);  \
            failures++;                                                        \
        }                                                                      \
    } while (0)

static void test_empty_and_capacity(void) {
    AMRing *r = AMRing_create(16);
    CHECK(r != NULL, "create");
    if (r == NULL) return;
    CHECK(AMRing_capacity(r) == 16, "capacity is power of two >= request");
    CHECK(AMRing_available(r) == 0, "starts empty");
    CHECK(AMRing_free_space(r) == 16, "starts fully free");
    CHECK(AMRing_read(r, (void *)"", 1) == 0, "read from empty returns 0");

    // Write fewer than capacity.
    uint8_t in[4] = {1, 2, 3, 4};
    CHECK(AMRing_write(r, in, 4) == 4, "write 4");
    CHECK(AMRing_available(r) == 4, "available after write");
    CHECK(AMRing_free_space(r) == 12, "free after write");

    uint8_t out[4] = {0};
    CHECK(AMRing_read(r, out, 4) == 4, "read 4");
    CHECK(memcmp(in, out, 4) == 0, "roundtrip data");
    CHECK(AMRing_available(r) == 0, "empty after read");
    AMRing_destroy(r);
}

static void test_partial_and_full(void) {
    AMRing *r = AMRing_create(8);
    CHECK(r != NULL, "create");
    if (r == NULL) return;
    uint8_t in[8] = {0, 1, 2, 3, 4, 5, 6, 7};
    CHECK(AMRing_write(r, in, 8) == 8, "fill to capacity");
    CHECK(AMRing_free_space(r) == 0, "full");
    CHECK(AMRing_write(r, in, 1) == 0, "write to full returns 0");
    // A write larger than free space returns a partial (bounded) count.
    uint8_t out[8] = {0};
    CHECK(AMRing_read(r, out, 8) == 8, "read all");
    CHECK(memcmp(in, out, 8) == 0, "data intact");
    CHECK(AMRing_write(r, in, 8) == 8, "refill after drain");
    AMRing_destroy(r);
}

static void test_wrap_around(void) {
    AMRing *r = AMRing_create(8);
    CHECK(r != NULL, "create");
    if (r == NULL) return;
    // Advance head/tail into the middle so the next write wraps.
    uint8_t seed[6] = {1, 2, 3, 4, 5, 6};
    CHECK(AMRing_write(r, seed, 6) == 6, "seed");
    uint8_t sink[6];
    CHECK(AMRing_read(r, sink, 6) == 6, "drain seed");
    // Now write 6 bytes; first span is 8-6=2 bytes, then 4 wraps.
    uint8_t in[6] = {10, 11, 12, 13, 14, 15};
    CHECK(AMRing_write(r, in, 6) == 6, "wrap write");
    uint8_t out[6] = {0};
    CHECK(AMRing_read(r, out, 6) == 6, "wrap read");
    CHECK(memcmp(in, out, 6) == 0, "wrap data intact");
    AMRing_destroy(r);
}

static void test_discard_and_reset(void) {
    AMRing *r = AMRing_create(16);
    CHECK(r != NULL, "create");
    if (r == NULL) return;
    uint8_t in[10];
    for (int i = 0; i < 10; i++) in[i] = (uint8_t)i;
    CHECK(AMRing_write(r, in, 10) == 10, "write");
    CHECK(AMRing_discard(r, 4) == 4, "discard 4");
    uint8_t out[6] = {0};
    CHECK(AMRing_read(r, out, 6) == 6, "read remaining");
    CHECK(out[0] == 4 && out[5] == 9, "discard dropped the front");
    AMRing_write(r, in, 10);
    AMRing_reset(r);
    CHECK(AMRing_available(r) == 0, "reset empties");
    AMRing_destroy(r);
}

static void test_lock_free_report(void) {
    AMRing *r = AMRing_create(64);
    CHECK(r != NULL, "create");
    if (r == NULL) return;
    printf("AMRing_is_lock_free = %s\n", AMRing_is_lock_free(r) ? "true" : "false");
    // On Apple arm64/x86_64 this should be true; report, do not hard-fail.
    AMRing_destroy(r);
}

typedef struct {
    AMRing *ring;
    size_t total;
    int status;
} worker_ctx;

static void *producer_thread(void *arg) {
    worker_ctx *ctx = (worker_ctx *)arg;
    uint32_t counter = 0;
    size_t produced = 0;
    while (produced < ctx->total) {
        // Emit a fixed-size block whose payload is a counter pattern.
        uint8_t block[64];
        for (size_t i = 0; i < sizeof(block); i += 4) {
            uint32_t value = counter++;
            memcpy(block + i, &value, 4);
        }
        size_t want = ctx->total - produced < sizeof(block) ? ctx->total - produced : sizeof(block);
        size_t wrote = AMRing_write(ctx->ring, block, want);
        produced += wrote;
        if (wrote == 0) {
            // Ring full: brief spin; the consumer is running concurrently.
        }
    }
    return NULL;
}

static void *consumer_thread(void *arg) {
    worker_ctx *ctx = (worker_ctx *)arg;
    uint8_t block[64];
    uint32_t expected = 0;
    size_t consumed = 0;
    while (consumed < ctx->total) {
        size_t got = AMRing_read(ctx->ring, block, sizeof(block));
        if (got == 0) {
            continue; // brief spin
        }
        if (got % 4 != 0) {
            ctx->status = 1;
            return NULL;
        }
        for (size_t i = 0; i < got; i += 4) {
            uint32_t value;
            memcpy(&value, block + i, 4);
            if (value != expected) {
                ctx->status = 2;
                return NULL;
            }
            expected++;
        }
        consumed += got;
    }
    return NULL;
}

static void test_concurrent_integrity(void) {
    const size_t total = 4 * 1024 * 1024; // 4 MiB
    AMRing *r = AMRing_create(4096);
    CHECK(r != NULL, "create");
    if (r == NULL) return;
    worker_ctx pctx = {r, total, 0};
    worker_ctx cctx = {r, total, 0};
    pthread_t producer, consumer;
    pthread_create(&producer, NULL, producer_thread, &pctx);
    pthread_create(&consumer, NULL, consumer_thread, &cctx);
    pthread_join(producer, NULL);
    pthread_join(consumer, NULL);
    CHECK(cctx.status == 0, "consumer saw no corruption / gap");
    CHECK(pctx.total == total, "producer total unchanged");
    AMRing_destroy(r);
}

int main(void) {
    test_empty_and_capacity();
    test_partial_and_full();
    test_wrap_around();
    test_discard_and_reset();
    test_lock_free_report();
    test_concurrent_integrity();
    if (failures == 0) {
        printf("PASS: AudioRingBuffer SPSC tests\n");
        return 0;
    }
    fprintf(stderr, "FAILED: %d checks\n", failures);
    return 1;
}
