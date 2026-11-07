/*
 * SDL_crc16, SDL_crc32 and SDL_murmur3_32 (src/stdlib/SDL_crc16.c, SDL_crc32.c, SDL_murmur3.c).
 *
 * Each reads exactly the `len` bytes it is given, from any alignment: the data is a heap object
 * of exactly len bytes at offset 0..3 of its allocation, so murmur3's aligned 32-bit fast path
 * and its byte-wise path are both explored. Memory safety and absence of undefined behaviour
 * only; the hash values themselves are covered by testautomation.
 *
 * CBMC-SOURCES: src/stdlib/SDL_crc16.c src/stdlib/SDL_crc32.c src/stdlib/SDL_murmur3.c
 * CBMC-BOUND: len <= 9, start offset 0..3
 * CBMC-UNWIND: 14
 */
#include "cbmc_common.h"

#define MAX 9

void harness(void)
{
    const size_t len = nondet_size_t();
    ASSUME(len <= MAX);
    const size_t off = nondet_size_t();
    ASSUME(off <= 3);
    /* The object is off + len bytes, so reading data[len] is out of bounds. */
    char *raw = nondet_buffer(off + len);
    const void *data = raw + off;

    (void)SDL_crc16((Uint16)nondet_int(), data, len);
    (void)SDL_crc32((Uint32)nondet_int(), data, len);
    (void)SDL_murmur3_32(data, len, (Uint32)nondet_int());
}
