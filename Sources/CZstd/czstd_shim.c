#include "czstd_shim.h"

#define ZSTD_STATIC_LINKING_ONLY
#include <zstd.h>
#include <zstd_errors.h>

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct czstd_dstream {
  ZSTD_DStream *dstream;
  unsigned long frames;
};

static _Thread_local char g_last_error[256] = "no error";

static void czstd_set_error_code(size_t code) {
  const char *name = ZSTD_getErrorName(code);
  snprintf(g_last_error, sizeof(g_last_error), "%s", name ? name : "unknown zstd error");
}

static void czstd_set_error_text(const char *text) {
  snprintf(g_last_error, sizeof(g_last_error), "%s", text ? text : "unknown error");
}

void czstd_free(void *p) { free(p); }

const char *czstd_last_error(void) { return g_last_error; }

int czstd_is_frame_magic(const void *src, size_t srcLen) {
  if (src == NULL || srcLen < 4) return 0;
  const unsigned char *b = (const unsigned char *)src;
  return b[0] == 0x28 && b[1] == 0xB5 && b[2] == 0x2F && b[3] == 0xFD;
}

czstd_dstream *czstd_dstream_new(void) {
  ZSTD_DStream *inner = ZSTD_createDStream();
  if (inner == NULL) {
    czstd_set_error_text("ZSTD_createDStream returned NULL");
    return NULL;
  }
  size_t rc = ZSTD_initDStream(inner);
  if (ZSTD_isError(rc)) {
    czstd_set_error_code(rc);
    ZSTD_freeDStream(inner);
    return NULL;
  }
  struct czstd_dstream *s = (struct czstd_dstream *)calloc(1, sizeof(struct czstd_dstream));
  if (s == NULL) {
    ZSTD_freeDStream(inner);
    czstd_set_error_text("out of memory allocating czstd_dstream");
    return NULL;
  }
  s->dstream = inner;
  s->frames = 0;
  return s;
}

void czstd_dstream_free(czstd_dstream *s) {
  if (s == NULL) return;
  if (s->dstream != NULL) ZSTD_freeDStream(s->dstream);
  free(s);
}

void czstd_dstream_reset(czstd_dstream *s) {
  if (s == NULL) return;
  ZSTD_initDStream(s->dstream);
  s->frames = 0;
}

unsigned long czstd_dstream_frame_count(const czstd_dstream *s) {
  return s == NULL ? 0 : s->frames;
}

czstd_outcome czstd_decompress_stream(czstd_dstream *s, const void *src, size_t srcLen, void *out, size_t outCap) {
  czstd_outcome result = {.written = 0, .consumed = 0, .frameEnded = 0, .streamComplete = 0};
  if (s == NULL || s->dstream == NULL) {
    czstd_set_error_text("null decompression stream");
    result.written = -1;
    return result;
  }

  ZSTD_inBuffer in = {.src = src, .size = srcLen, .pos = 0};

  for (;;) {
    size_t remaining = outCap - (size_t)result.written;
    ZSTD_outBuffer ob = {.dst = out, .size = outCap, .pos = (size_t)result.written};
    /* With a zero-capacity output buffer we still need libzstd to advance on
     * input, so hand it a 1-byte scratch (only used by the skip-ahead path). */
    char scratch = 0;
    if (out == NULL || remaining == 0) {
      ob.dst = &scratch;
      ob.size = 1;
      ob.pos = 0;
    }
    size_t before = ob.pos;
    size_t rc = ZSTD_decompressStream(s->dstream, &ob, &in);
    if (ZSTD_isError(rc)) {
      czstd_set_error_code(rc);
      result.written = -1;
      result.consumed = in.pos;
      return result;
    }
    if (out == NULL || remaining == 0) {
      /* Scratch was used: only count the byte when it was actually written. */
      if (ob.pos > before && out != NULL) {
        result.written += (long)(ob.pos - before);
      }
      /* Leaving the scratch path is safe only when the caller asked us to skip. */
    } else {
      result.written = (long)ob.pos;
    }

    result.consumed = in.pos;

    if (rc == 0) {
      /* A frame boundary: libzstd is ready to start the next concatenated frame. */
      s->frames += 1;
      result.frameEnded = 1;
      if (in.pos == in.size) {
        result.streamComplete = 1;
        return result;
      }
      continue;
    }

    if (in.pos == in.size) {
      /* Input exhausted mid-frame; caller feeds more later. */
      result.frameEnded = 0;
      return result;
    }

    if (out != NULL && (size_t)result.written == outCap) {
      /* Output buffer full; caller drains and calls again. */
      return result;
    }
  }
}

static void *czstd_copy_into_heap(const void *src, size_t len) {
  void *buf = malloc(len == 0 ? 1 : len);
  if (buf == NULL) {
    czstd_set_error_text("out of memory");
    return NULL;
  }
  if (len > 0) memcpy(buf, src, len);
  return buf;
}

void *czstd_decompress_all(const void *src, size_t srcLen, size_t *outLen) {
  if (outLen != NULL) *outLen = 0;
  if (src == NULL || srcLen == 0) {
    czstd_set_error_text("empty input");
    return NULL;
  }

  unsigned long long bound = ZSTD_getFrameContentSize(src, srcLen);
  size_t capacity;
  if (bound != ZSTD_CONTENTSIZE_UNKNOWN && bound != ZSTD_CONTENTSIZE_ERROR) {
    /* Known size only covers the first frame; concatenated logs need slack. */
    capacity = (size_t)bound * 2 + 1024;
  } else {
    capacity = srcLen * 8 + 65536;
  }

  unsigned char *buffer = (unsigned char *)malloc(capacity);
  if (buffer == NULL) {
    czstd_set_error_text("out of memory");
    return NULL;
  }

  czstd_dstream *s = czstd_dstream_new();
  if (s == NULL) {
    free(buffer);
    return NULL;
  }

  size_t inPos = 0;
  size_t outPos = 0;
  for (;;) {
    if (outPos == capacity) {
      capacity *= 2;
      unsigned char *grown = (unsigned char *)realloc(buffer, capacity);
      if (grown == NULL) {
        czstd_set_error_text("out of memory growing output buffer");
        free(buffer);
        czstd_dstream_free(s);
        return NULL;
      }
      buffer = grown;
    }
    czstd_outcome r = czstd_decompress_stream(s, (const unsigned char *)src + inPos, srcLen - inPos,
                                              buffer + outPos, capacity - outPos);
    if (r.written < 0) {
      free(buffer);
      czstd_dstream_free(s);
      return NULL;
    }
    outPos += (size_t)r.written;
    inPos += r.consumed;
    if (r.streamComplete) break;
    if (inPos >= srcLen && r.consumed == 0 && r.written == 0 && !r.frameEnded) {
      czstd_set_error_text("truncated zstd stream");
      free(buffer);
      czstd_dstream_free(s);
      return NULL;
    }
  }

  czstd_dstream_free(s);
  if (outLen != NULL) *outLen = outPos;
  return buffer;
}

void *czstd_compress_checksummed(const void *src, size_t srcLen, int level, size_t *outLen) {
  if (outLen != NULL) *outLen = 0;
  ZSTD_CCtx *cctx = ZSTD_createCCtx();
  if (cctx == NULL) {
    czstd_set_error_text("ZSTD_createCCtx returned NULL");
    return NULL;
  }
  size_t rc = ZSTD_CCtx_setParameter(cctx, ZSTD_c_compressionLevel, level);
  if (!ZSTD_isError(rc)) rc = ZSTD_CCtx_setParameter(cctx, ZSTD_c_checksumFlag, 1);
  if (ZSTD_isError(rc)) {
    czstd_set_error_code(rc);
    ZSTD_freeCCtx(cctx);
    return NULL;
  }
  size_t bound = ZSTD_compressBound(srcLen);
  void *buffer = malloc(bound == 0 ? 1 : bound);
  if (buffer == NULL) {
    czstd_set_error_text("out of memory");
    ZSTD_freeCCtx(cctx);
    return NULL;
  }
  size_t written = ZSTD_compress2(cctx, buffer, bound, src, srcLen);
  ZSTD_freeCCtx(cctx);
  if (ZSTD_isError(written)) {
    czstd_set_error_code(written);
    free(buffer);
    return NULL;
  }
  if (outLen != NULL) *outLen = written;
  return buffer;
}

void *czstd_compress(const void *src, size_t srcLen, int level, size_t *outLen) {
  if (outLen != NULL) *outLen = 0;
  size_t bound = ZSTD_compressBound(srcLen);
  void *buffer = malloc(bound == 0 ? 1 : bound);
  if (buffer == NULL) {
    czstd_set_error_text("out of memory");
    return NULL;
  }
  size_t written = ZSTD_compress(buffer, bound, src, srcLen, level);
  if (ZSTD_isError(written)) {
    czstd_set_error_code(written);
    free(buffer);
    return NULL;
  }
  if (outLen != NULL) *outLen = written;
  return buffer;
}
