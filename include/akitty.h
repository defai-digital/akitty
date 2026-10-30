#ifndef AKITTY_H
#define AKITTY_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* ABI 1: JSON requests/responses use schema version 1. Requests are borrowed
 * for this call only. Calls are serialized internally and may move threads.
 * Never free an AkittyBuffer with a foreign allocator. Free each non-null
 * buffer exactly once using akitty_buffer_free_v1, with the original length.
 * A null data pointer indicates an allocation/serialization failure.
 * Session IDs are opaque monotonically assigned integers, not pointers.
 * Unknown/closed IDs return structured errors; closing is idempotent.
 * No upstream engine types or layouts form part of this contract. */
typedef struct { uint8_t *data; size_t len; } AkittyBuffer;
uint32_t akitty_abi_version(void);
AkittyBuffer akitty_request_v1(const uint8_t *data, size_t len);
void akitty_buffer_free_v1(AkittyBuffer buffer);
/* Copies the RGBA pixels (width * height * 4 bytes, row-major) of a stored Kitty
 * graphics image into `out`. Returns the byte count, or 0 for an unknown session
 * or image, or when `capacity` is too small. Sizes come from the snapshot. */
size_t akitty_image_read_v1(uint64_t session, uint32_t image, uint8_t *out, size_t capacity);
#ifdef __cplusplus
}
#endif
#endif
