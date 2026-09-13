/* CZstd shim — the only place in the project that touches libzstd directly.
 *
 * Why a shim at all:
 *   1. Apple's Compression framework has no `COMPRESSION_ZSTD`, and macOS ships no
 *      libzstd — so the library is vendored under `Vendor/zstd` (BSD-3-Clause).
 *   2. Session logs (`session.jsonl.zstd`) are *concatenated* zstd frames — one frame
 *      per append. `ZSTD_decompressStream` is the only mode that walks frames
 *      transparently; the one-shot API stops at the first frame end.
 *   3. Swift cannot express `ZSTD_DStream`'s opaque lifecycle ergonomically, so the
 *      stream object is owned here.
 *
 * All functions are thread-confined: a `czstd_dstream` must not be shared across
 * threads. One stream per concurrent decode.
 */

#ifndef CZSTD_SHIM_H
#define CZSTD_SHIM_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct czstd_dstream czstd_dstream;

typedef struct czstd_outcome {
  /* Bytes written into `out`. -1 when the call failed. */
  long written;
  /* Bytes consumed from `src`. */
  size_t consumed;
  /* 1 when a complete frame ended and no partial input remains buffered. */
  int frameEnded;
  /* 1 when the buffer ended exactly on a frame boundary and all frames are flushed. */
  int streamComplete;
} czstd_outcome;

czstd_dstream *czstd_dstream_new(void);
void czstd_dstream_free(czstd_dstream *s);
void czstd_dstream_reset(czstd_dstream *s);

/* Number of frames fully decoded since the last reset. Lets callers assert the
 * multi-frame behaviour that the official runtime relies on. */
unsigned long czstd_dstream_frame_count(const czstd_dstream *s);

/* Streaming decode. Feed arbitrary chunks; each call drains as much as `outCap`
 * allows. `out` may be NULL only when `outCap` is 0 (used to skip ahead). */
czstd_outcome czstd_decompress_stream(czstd_dstream *s, const void *src, size_t srcLen, void *out, size_t outCap);

/* Convenience: decompress every concatenated frame of `src` into a heap buffer.
 * The returned pointer must be released with czstd_free. Returns NULL on failure. */
void *czstd_decompress_all(const void *src, size_t srcLen, size_t *outLen);

/* One-shot compress. Returns a heap buffer to release with czstd_free. */
void *czstd_compress(const void *src, size_t srcLen, int level, size_t *outLen);

/* One-shot compress with the frame-level checksum bit set.
 *
 * The official JSONL persistence writer compresses every durable batch with
 * `ZSTD_c_checksumFlag`, so frames written by this build carry the same flag and a
 * reader can validate integrity the same way for both. */
void *czstd_compress_checksummed(const void *src, size_t srcLen, int level, size_t *outLen);

void czstd_free(void *p);

/* Human-readable message for the most recent error on this stream (or on the
 * calling thread for one-shot calls). Never NULL. */
const char *czstd_last_error(void);

/* 1 when the byte buffer begins with a zstd frame magic number. */
int czstd_is_frame_magic(const void *src, size_t srcLen);

#ifdef __cplusplus
}
#endif

#endif /* CZSTD_SHIM_H */
