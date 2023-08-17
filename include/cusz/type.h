/**
 * @file type.h
 * @author Jiannan Tian
 * @brief C-complient type definitions; no methods in this header.
 * @version 0.3
 * @date 2022-04-29
 *
 * (C) 2022 by Washington State University, Argonne National Laboratory
 *
 */

#ifndef PSZ_TYPE_H
#define PSZ_TYPE_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>
#include <stdint.h>

enum cusz_execution_policy { CPU, CUDA, HIP, ONEAPI, HIP_NV, ONEAPI_NV };
typedef enum cusz_execution_policy cusz_execution_policy;
typedef enum cusz_execution_policy cusz_policy;
typedef enum cusz_execution_policy psz_policy;

//////// state enumeration

typedef enum cusz_error_status {  //
  CUSZ_SUCCESS = 0x00,
  CUSZ_FAIL_ONDISK_FILE_ERROR = 0x01,
  CUSZ_FAIL_DATA_NOT_READY = 0x02,
  // specify error when calling CUDA API
  CUSZ_FAIL_GPU_MALLOC,
  CUSZ_FAIL_GPU_MEMCPY,
  CUSZ_FAIL_GPU_ILLEGAL_ACCESS,
  // specify error related to our own memory manager
  CUSZ_FAIL_GPU_OUT_OF_MEMORY,
  // when compression is useless
  CUSZ_FAIL_INCOMPRESSIABLE,
  // TODO component related error
  CUSZ_FAIL_UNSUPPORTED_DATATYPE,
  CUSZ_FAIL_UNSUPPORTED_QUANTTYPE,
  CUSZ_FAIL_UNSUPPORTED_PRECISION,
  CUSZ_FAIL_UNSUPPORTED_PIPELINE,
  // not-implemented error
  CUSZ_NOT_IMPLEMENTED = 0x0100,
} cusz_error_status;
typedef cusz_error_status psz_error_status;

typedef struct cusz_fixedlen_internal { /* all nullable */
  void* encoding;
} cusz_fixedlen_internal;
typedef struct cusz_varlen_internal { /* all nullable */
  void* huffman;
  void* outlier;
} cusz_varlen_internal;

typedef enum cusz_datatype  //
{ FP32 = 0,
  FP64 = 1,
  UINT8 = 10,
  UINT16 = 11,
  UINT32 = 12,
  UINT64 = 13,
  //
  F0 = 20,
  F4 = 24,
  F8 = 28,
  //
  U0 = 30,
  U1 = 31,
  U2 = 32,
  U4 = 34,
  U8 = 38,
  //
  I0 = 40,
  I1 = 41,
  I2 = 42,
  I4 = 44,
  I8 = 48,
  //
  ULL = 51 } cusz_datatype;
typedef cusz_datatype cusz_dtype;
typedef cusz_datatype psz_dtype;

typedef uint8_t u1;
typedef uint16_t u2;
typedef uint32_t u4;
typedef uint64_t u8;
typedef int8_t i1;
typedef int16_t i2;
typedef int32_t i4;
typedef int64_t i8;
typedef float f4;
typedef double f8;

typedef enum cusz_executiontype  //
{ Device = 0,
  Host = 1,
  None = 2 } cusz_executiontype;

typedef cusz_executiontype psz_space;

typedef enum cusz_mode  //
{ Abs = 0,
  Rel = 1 } cusz_mode;

typedef enum cusz_pipelinetype  //
{ Auto = 0,
  Dense = 1,
  Sparse = 2 } cusz_pipelinetype;

typedef enum cusz_predictortype  //
{ Lorenzo0 = 0,
  LorenzoI = 1,
  LorenzoII = 2,
  Spline3 = 3 } cusz_predictortype;

typedef enum cusz_preprocessingtype  //
{ FP64toFP32 = 0,
  LogTransform,
  ShiftedLogTransform,
  Binning2x2,
  Binning2x1,
  Binning1x2,
} cusz_preprocessingtype;

typedef enum cusz_codectype  //
{ Huffman = 0,
  RunLength,
  NvcompCascade,
  NvcompLz4,
  NvcompSnappy,
} cusz_codectype;

typedef enum cusz_spcodectype  //
{ SparseMat = 0,
  SparseVec = 1 } cusz_spcodectype;

typedef enum cusz_huffman_booktype  //
{ Tree = 0,
  Canonical = 1 } cusz_huffman_booktype;

typedef enum cusz_huffman_codingtype  //
{ Coarse = 0,
  Fine = 1 } cusz_huffman_codingtype;

//////// configuration template
typedef struct cusz_custom_len {
  // clang-format off
    union { size_t x0, x; };
    union { size_t x1, y; };
    union { size_t x2, z; };
    union { size_t x3, w; };
    // double factor;
  // clang-format on
} cusz_custom_len;
typedef cusz_custom_len cusz_len;

typedef struct cusz_custom_preprocessing {
  cusz_custom_len before;
  cusz_custom_len after;
  cusz_preprocessingtype* list;
  int nstep;

} cusz_custom_preprocessing;

typedef struct cusz_custom_predictor {
  cusz_predictortype type;

  bool anchor;
  bool nondestructive;
} cusz_custom_predictor;

typedef struct cusz_custom_quantization {
  int radius;
  bool delayed;
} cusz_custom_quantization;

typedef struct cusz_custom_codec {
  cusz_codectype type;

  bool variable_length;
  float presumed_density;
} cusz_custom_codec;

typedef struct cusz_custom_huffman_codec {
  cusz_huffman_booktype book;
  cusz_executiontype book_policy;
  cusz_huffman_codingtype coding;

  int booklen;
  int coarse_pardeg;
} cusz_custom_huffman_codec;

typedef struct cusz_custom_spcodec {
  cusz_spcodectype type;
  float presumed_density;
} cusz_custom_spcodec;

////// wrap-up

/**
 * @deprecated The framework could be simplifed & unified.
 */
typedef struct cusz_custom_framework {
  cusz_datatype datatype;
  cusz_pipelinetype pipeline;

  cusz_custom_predictor predictor;
  cusz_custom_quantization quantization;
  cusz_custom_codec codec;
  // cusz_custom_spcodec      spcodec;

  cusz_custom_huffman_codec huffman;
} cusz_custom_framework;

typedef cusz_custom_framework cusz_framework;

typedef struct cusz_compressor_redundancy_compat_purpose {
  void* compressor;
  cusz_framework* framework;
  cusz_datatype type;
} cusz_compressor_compat;

typedef cusz_compressor_compat cusz_compressor;

typedef struct cusz_runtime_config {
  double eb;
  cusz_mode mode;
} cusz_runtime_config;
typedef cusz_runtime_config cusz_config;

typedef struct Res {
  double min, max, rng, std;
} Res;

typedef struct cusz_stats {
  // clang-format off
    Res odata, xdata;
    struct { double PSNR, MSE, NRMSE, coeff; } reduced;
    struct { double abs, rel, pwrrel; size_t idx; } max_err;
    struct { double lag_one, lag_two; } autocor;
    double user_eb;
    size_t len;
  // clang-format on
} cusz_stats;

#ifdef __cplusplus
}
#endif

#endif
