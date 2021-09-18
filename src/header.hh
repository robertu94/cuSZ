#ifndef HEADER_HH
#define HEADER_HH

/**
 * @file header.hh
 * @author Jiannan Tian
 * @brief
 * @version 0.2
 * @date 2021-01-22
 * (created) 2020-09-25, (rev.1) 2021-01-22 (rev.2) 2021-09-08
 *
 * @copyright (C) 2020 by Washington State University, Argonne National Laboratory
 * See LICENSE in top-level directory
 *
 */

#include "context.hh"

typedef struct alignas(128) cuszHEADER {
    uint32_t x, y, z, w;
    uint32_t data_len;
    double   eb;

    uint32_t ndim : 2;
    uint32_t dtype : 8;        // (1) fp32, (2) fp64
    uint32_t quant_nbyte : 4;  //
    uint32_t huff_nbyte : 4;   //

    int nnz_outlier;

    // uint32_t huffman_num_bits;
    uint32_t huffman_chunk;
    uint32_t huffman_num_uints;

    struct {
        bool skip_huffman;
    } task_is;

    // stat
    float maximum, minimum;

    struct {
        /* 0 header */
        /* 1 */ uint32_t book;
        /* 2 */ uint32_t quant;
        /* 3 */ uint32_t revbook;
        /* 4 */ uint32_t outlier;  // TODO -> ancillary
        /* 5 */ uint32_t huff_meta;
        /* 6 */ uint32_t huff_bitstream;
    } nbyte;

} cusz_header;

#endif