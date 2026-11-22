// The streaming decoder API of Zstandard 1.5.7, compiled into GreeceKit from
// GreeceKit/Sources/Modules/Archives/Zstd/zstddeclib.c (the official single-file decoder).
// These declarations mirror lib/zstd.h for that version.
#ifndef GREECE_ZSTD_H
#define GREECE_ZSTD_H

#include <stddef.h>

typedef struct ZSTD_DCtx_s ZSTD_DCtx;
typedef ZSTD_DCtx ZSTD_DStream;

typedef struct ZSTD_inBuffer_s {
    const void *src;
    size_t size;
    size_t pos;
} ZSTD_inBuffer;

typedef struct ZSTD_outBuffer_s {
    void *dst;
    size_t size;
    size_t pos;
} ZSTD_outBuffer;

typedef enum {
    ZSTD_reset_session_only = 1,
    ZSTD_reset_parameters = 2,
    ZSTD_reset_session_and_parameters = 3
} ZSTD_ResetDirective;

typedef enum {
    ZSTD_d_windowLogMax = 100
} ZSTD_dParameter;

ZSTD_DStream *ZSTD_createDStream(void);
size_t ZSTD_freeDStream(ZSTD_DStream *zds);
size_t ZSTD_decompressStream(ZSTD_DStream *zds, ZSTD_outBuffer *output, ZSTD_inBuffer *input);
size_t ZSTD_DStreamInSize(void);
size_t ZSTD_DStreamOutSize(void);
size_t ZSTD_DCtx_setParameter(ZSTD_DCtx *dctx, ZSTD_dParameter param, int value);
size_t ZSTD_DCtx_reset(ZSTD_DCtx *dctx, ZSTD_ResetDirective reset);
unsigned ZSTD_isError(size_t result);

#endif
