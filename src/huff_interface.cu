/**
 * @file huffman_workflow.cu
 * @author Jiannan Tian, Cody Rivera (cjrivera1@crimson.ua.edu)
 * @brief Workflow of Huffman coding.
 * @version 0.1
 * @date 2020-10-24
 * Created on 2020-04-24
 *
 * @copyright (C) 2020 by Washington State University, The University of Alabama, Argonne National Laboratory
 * See LICENSE in top-level directory
 *
 */

#include <cuda_runtime.h>

#include <sys/stat.h>
#include <unistd.h>
#include <algorithm>
#include <bitset>
#include <cassert>
#include <cmath>
#include <functional>
#include <iomanip>
#include <iostream>
#include <numeric>
#include <stdexcept>
#include <string>
#include <tuple>
#include <type_traits>
#include <vector>

#include "hist.cuh"
#include "huff_codec.cuh"
#include "huff_interface.cuh"
#include "par_huffman.cuh"
#include "type_aliasing.hh"
#include "type_trait.hh"
#include "types.hh"
#include "utils/cuda_err.cuh"
#include "utils/cuda_mem.cuh"
#include "utils/dbg_print.cuh"
#include "utils/format.hh"
#include "utils/timer.hh"

#include "cascaded.hpp"
#include "nvcomp.hpp"

int ht_state_num;
int ht_all_nodes;
// const int nvcompTHLD = 30;

typedef std::tuple<size_t, size_t, size_t, bool> tuple_3ul_1bool;

template <typename UInt_Input>
void lossless::wrapper::GetFrequency(UInt_Input* d_in, size_t len, unsigned int* d_freq, int dict_size)
{
    // Parameters for thread and block count optimization
    // Initialize to device-specific values
    int deviceId, maxbytes, maxbytesOptIn, numSMs;

    cudaGetDevice(&deviceId);
    cudaDeviceGetAttribute(&maxbytes, cudaDevAttrMaxSharedMemoryPerBlock, deviceId);
    cudaDeviceGetAttribute(&numSMs, cudaDevAttrMultiProcessorCount, deviceId);

    // Account for opt-in extra shared memory on certain architectures
    cudaDeviceGetAttribute(&maxbytesOptIn, cudaDevAttrMaxSharedMemoryPerBlockOptin, deviceId);
    maxbytes = std::max(maxbytes, maxbytesOptIn);

    // Optimize launch
    int numBuckets     = dict_size;
    int numValues      = len;
    int itemsPerThread = 1;
    int RPerBlock      = (maxbytes / (int)sizeof(int)) / (numBuckets + 1);
    int numBlocks      = numSMs;
    cudaFuncSetAttribute(
        data_process::reduce::p2013Histogram<UInt_Input, unsigned int>, cudaFuncAttributeMaxDynamicSharedMemorySize,
        maxbytes);
    // fits to size
    int threadsPerBlock = ((((numValues / (numBlocks * itemsPerThread)) + 1) / 64) + 1) * 64;
    while (threadsPerBlock > 1024) {
        if (RPerBlock <= 1) { threadsPerBlock = 1024; }
        else {
            RPerBlock /= 2;
            numBlocks *= 2;
            threadsPerBlock = ((((numValues / (numBlocks * itemsPerThread)) + 1) / 64) + 1) * 64;
        }
    }
    data_process::reduce::p2013Histogram                                                //
        <<<numBlocks, threadsPerBlock, ((numBuckets + 1) * RPerBlock) * sizeof(int)>>>  //
        (d_in, d_freq, numValues, numBuckets, RPerBlock);
    cudaDeviceSynchronize();

#ifdef DEBUG_PRINT
    print_histogram<unsigned int><<<1, 32>>>(d_freq, dict_size, dict_size / 2);
    cudaDeviceSynchronize();
#endif
}

template <typename Huff>
void lossless::utils::PrintChunkHuffmanCoding(
    size_t* dH_bit_meta,  //
    size_t* dH_uInt_meta,
    size_t  len,
    int     chunk_size,
    size_t  total_bits,
    size_t  total_uInts)
{
    cout << "\n" << log_dbg << "Huffman coding detail start ------" << endl;
    printf("| %s\t%s\t%s\t%s\t%9s\n", "chunk", "bits", "bytes", "uInt", "chunkCR");
    for (size_t i = 0; i < 8; i++) {
        size_t n_byte   = (dH_bit_meta[i] - 1) / 8 + 1;
        auto   chunk_CR = ((double)chunk_size * sizeof(float) / (1.0 * (double)dH_uInt_meta[i] * sizeof(Huff)));
        printf("| %lu\t%lu\t%lu\t%lu\t%9.6lf\n", i, dH_bit_meta[i], n_byte, dH_uInt_meta[i], chunk_CR);
    }
    cout << "| ..." << endl
         << "| Huff.total.bits:\t" << total_bits << endl
         << "| Huff.total.bytes:\t" << total_uInts * sizeof(Huff) << endl
         << "| Huff.CR (uInt):\t" << (double)len * sizeof(float) / (total_uInts * 1.0 * sizeof(Huff)) << endl;
    cout << log_dbg << "coding detail end ----------------" << endl;
    cout << endl;
}

template <typename Quant, typename Huff, typename Data>
tuple_3ul_1bool lossless::interface::HuffmanEncode(
    string& basename,
    Quant*  d_in,
    size_t  len,
    int     chunk_size,
    bool    to_nvcomp,
    int     dict_size,
    bool    export_cb)
{
    // histogram
    ht_state_num = 2 * dict_size;
    ht_all_nodes = 2 * ht_state_num;
    auto d_freq  = mem::CreateCUDASpace<unsigned int>(ht_all_nodes);
    lossless::wrapper::GetFrequency(d_in, len, d_freq, dict_size);

    // Allocate cb memory
    auto d_canonical_cb = mem::CreateCUDASpace<Huff>(dict_size, 0xff);
    // canonical Huffman; follows H to decide first and entry type
    auto type_bw = sizeof(Huff) * 8;
    // first, entry, reversed codebook
    // CHANGED first and entry to H type
    auto decode_meta_size = sizeof(Huff) * (2 * type_bw) + sizeof(Quant) * dict_size;
    auto d_decode_meta    = mem::CreateCUDASpace<uint8_t>(decode_meta_size);

    // Get codebooks
    lossless::par_huffman::ParGetCodebook<Quant, Huff>(dict_size, d_freq, d_canonical_cb, d_decode_meta);
    cudaDeviceSynchronize();

    auto decode_meta = mem::CreateHostSpaceAndMemcpyFromDevice(d_decode_meta, decode_meta_size);

    // Non-deflated output
    auto d_h = mem::CreateCUDASpace<Huff>(len);

    if (export_cb) {
        // internal evaluation, not stored in sz archive
        auto              cb_dump = mem::CreateHostSpaceAndMemcpyFromDevice(d_canonical_cb, dict_size);
        std::stringstream s;
        s << basename + "-" << dict_size << "-ui" << sizeof(Huff) << ".lean_cb";
        LogAll(log_dbg, "export \"lean\" codebook (of dict_size) as", s.str());
        io::WriteArrayToBinary(s.str(), cb_dump, dict_size);
        delete[] cb_dump;
        cb_dump = nullptr;
    }

    // fix-length space
    {
        auto block_dim = HuffConfig::Db_encode;
        auto grid_dim  = (len - 1) / block_dim + 1;
        lossless::wrapper::EncodeFixedLen<Quant, Huff><<<grid_dim, block_dim>>>(d_in, d_h, len, d_canonical_cb);
        cudaDeviceSynchronize();
    }

    // deflate
    auto n_chunk       = (len - 1) / chunk_size + 1;  // |
    auto d_h_bitwidths = mem::CreateCUDASpace<size_t>(n_chunk);
    // cout << log_dbg << "Huff.chunk x #:\t" << chunk_size << " x " << n_chunk << endl;
    {
        auto block_dim = HuffConfig::Db_deflate;
        auto grid_dim  = (n_chunk - 1) / block_dim + 1;
        lossless::wrapper::Deflate<Huff><<<grid_dim, block_dim>>>(d_h, len, d_h_bitwidths, chunk_size);
        cudaDeviceSynchronize();
    }

    // dump TODO change to int
    auto h_meta        = new size_t[n_chunk * 3]();
    auto dH_uInt_meta  = h_meta;
    auto dH_bit_meta   = h_meta + n_chunk;
    auto dH_uInt_entry = h_meta + n_chunk * 2;
    // copy back densely Huffman code (dHcode)
    cudaMemcpy(dH_bit_meta, d_h_bitwidths, n_chunk * sizeof(size_t), cudaMemcpyDeviceToHost);
    // transform in uInt
    memcpy(dH_uInt_meta, dH_bit_meta, n_chunk * sizeof(size_t));
    for_each(dH_uInt_meta, dH_uInt_meta + n_chunk, [&](size_t& i) { i = (i - 1) / (sizeof(Huff) * 8) + 1; });
    // make it entries
    memcpy(dH_uInt_entry + 1, dH_uInt_meta, (n_chunk - 1) * sizeof(size_t));
    for (auto i = 1; i < n_chunk; i++) dH_uInt_entry[i] += dH_uInt_entry[i - 1];

    // sum bits from each chunk
    auto total_bits  = std::accumulate(dH_bit_meta, dH_bit_meta + n_chunk, (size_t)0);
    auto total_uInts = std::accumulate(dH_uInt_meta, dH_uInt_meta + n_chunk, (size_t)0);

    auto fmt_enc1 = "Huffman enc: (#) " + std::to_string(n_chunk) + " x " + std::to_string(chunk_size);
    auto fmt_enc2 = std::to_string(total_uInts) + " " + std::to_string(sizeof(Huff)) + "-byte words or " +
                    std::to_string(total_bits) + " bits";
    LogAll(log_dbg, fmt_enc1, "=>", fmt_enc2);

    // print densely metadata
    // PrintChunkHuffmanCoding<H>(dH_bit_meta, dH_uInt_meta, len, chunk_size, total_bits, total_uInts);

    // copy back densely Huffman code in units of uInt (regarding endianness)
    // TODO reinterpret_cast
    auto h = new Huff[total_uInts]();
    for (auto i = 0; i < n_chunk; i++) {
        cudaMemcpy(
            h + dH_uInt_entry[i],            // dst
            d_h + i * chunk_size,            // src
            dH_uInt_meta[i] * sizeof(Huff),  // len in H-uint
            cudaMemcpyDeviceToHost);
    }

    bool nvcomp_in_use = false;
    // if(!gzip_in_use && len*4/sizeof(Huff)/total_uInts>=nvcompTHLD){
    if (to_nvcomp) {
        int*         uncompressed_data;
        const size_t in_bytes = sizeof(Huff) * total_uInts;
        cudaMalloc(&uncompressed_data, in_bytes);
        cudaMemcpy(uncompressed_data, h, in_bytes, cudaMemcpyHostToDevice);
        cudaStream_t stream;
        cudaStreamCreate(&stream);
        // 2 layers RLE, 1 Delta encoding, bitpacking enabled
        nvcomp::CascadedCompressor<int> compressor(uncompressed_data, in_bytes / sizeof(int), 2, 1, true);
        const size_t                    temp_size = compressor.get_temp_size();
        void*                           temp_space;
        cudaMalloc(&temp_space, temp_size);
        size_t output_size = compressor.get_max_output_size(temp_space, temp_size);
        void*  output_space;
        cudaMalloc(&output_space, output_size);
        compressor.compress_async(temp_space, temp_size, output_space, &output_size, stream);
        cudaStreamSynchronize(stream);

        delete[] h;
        total_uInts = output_size / sizeof(Huff);
        h           = new Huff[total_uInts]();
        cudaMemcpy(h, output_space, output_size, cudaMemcpyDeviceToHost);
        cudaFree(uncompressed_data);
        cudaFree(temp_space);
        cudaFree(output_space);
        cudaStreamDestroy(stream);

        // record nvcomp status in metadata
        // TODO nvcomp_in_use is to export: rename it
        nvcomp_in_use = true;
    }

    auto time_a = hires::now();
    // dump bit_meta and uInt_meta
    io::WriteArrayToBinary(basename + ".hmeta", h_meta + n_chunk, (2 * n_chunk));
    // write densely Huffman code and its metadata
    io::WriteArrayToBinary(basename + ".hbyte", h, total_uInts);
    // to save first, entry and keys
    io::WriteArrayToBinary(
        basename + ".canon",                                      //
        reinterpret_cast<uint8_t*>(decode_meta),                  //
        sizeof(Huff) * (2 * type_bw) + sizeof(Quant) * dict_size  // first, entry, reversed dict (keys)
    );
    auto time_z = hires::now();
    LogAll(log_dbg, "time writing Huff. binary:", static_cast<duration_t>(time_z - time_a).count(), "sec");

    size_t metadata_size = (2 * n_chunk) * sizeof(decltype(h_meta))                     //
                           + sizeof(Huff) * (2 * type_bw) + sizeof(Quant) * dict_size;  // uint8_t

    //////// clean up
    cudaFree(d_freq);
    cudaFree(d_canonical_cb);
    cudaFree(d_decode_meta);
    cudaFree(d_h);
    cudaFree(d_h_bitwidths);
    delete[] h;
    delete[] h_meta;
    delete[] decode_meta;

    return std::make_tuple(total_bits, total_uInts, metadata_size, nvcomp_in_use);
}

/**
 * @brief experiment warpup; use after dual-quant; of anysize
 * @todo experiment only, no decoding yet
 */
template <typename Quant, typename Huff, typename Data>
void lossless::interface::HuffmanEncodeWithTree_3D(
    Index<3>::idx_t idx,
    string&         basename,
    Quant*          h_q_in,
    size_t          len,
    int             dict_size)
{
    auto d_quant_in = mem::CreateDeviceSpaceAndMemcpyFromHost(h_q_in, len);

    auto d_freq = mem::CreateCUDASpace<unsigned int>(dict_size);
    lossless::wrapper::GetFrequency(d_quant_in, len, d_freq, dict_size);
    auto h_freq = mem::CreateHostSpaceAndMemcpyFromDevice(d_freq, dict_size);

    auto entropy = GetEntropyFromFrequency(h_freq, len, dict_size);

    std::stringstream s;
    s << basename + "-" << dict_size << "-ui" << sizeof(Huff) << ".lean_cb";
    auto h_cb = io::ReadBinaryToNewArray<Huff>(s.str(), dict_size);

    auto GetBitcount = [&](Quant& q) { return (size_t) * ((uint8_t*)&h_cb[q] + sizeof(Huff) - 1); };

    double total_bitcounts = 0;
    for (auto i = 0; i < len; i++) { total_bitcounts += GetBitcount(h_q_in[i]); }
    auto nbytes   = total_bitcounts / 8;
    auto cr_quant = len * sizeof(Quant) / nbytes;
    auto cr_data  = len * sizeof(Data) / nbytes;
    LogAll(
        log_exp,                                                //
        idx._0, idx._1, idx._2, "\t",                           //
        std::setprecision(4),                                   //
        " entropy:", entropy,                                   //
        " \e[1mavg bitcount:", total_bitcounts / len, "\e[0m",  //
        " total bitcount:", total_bitcounts,                    //
        " nbytes:", nbytes,                                     //
        " CR against quant and data:", cr_quant, cr_data);

    cudaFree(d_freq);
    cudaFree(d_quant_in);
}

template <typename Quant, typename Huff, typename Data>
Quant* lossless::interface::HuffmanDecode(
    std::string& basename,  //
    size_t       len,
    int          chunk_size,
    int          total_uInts,
    bool         nvcomp_in_use,
    int          dict_size)
{
    auto type_bw        = sizeof(Huff) * 8;
    auto canonical_meta = sizeof(Huff) * (2 * type_bw) + sizeof(Quant) * dict_size;
    auto canonical_byte = io::ReadBinaryToNewArray<uint8_t>(basename + ".canon", canonical_meta);
    cudaDeviceSynchronize();

    auto n_chunk         = (len - 1) / chunk_size + 1;
    auto huff_multibyte  = io::ReadBinaryToNewArray<Huff>(basename + ".hbyte", total_uInts);
    auto huff_chunk_meta = io::ReadBinaryToNewArray<size_t>(basename + ".hmeta", 2 * n_chunk);
    auto block_dim       = HuffConfig::Db_deflate;  // the same as deflating
    auto grid_dim        = (n_chunk - 1) / block_dim + 1;

    auto d_xq             = mem::CreateCUDASpace<Quant>(len);
    auto d_huff_multibyte = mem::CreateDeviceSpaceAndMemcpyFromHost(huff_multibyte, total_uInts);

    // if nvcomp is used to compress *.hbyte
    if (nvcomp_in_use) {
        cudaStream_t stream;
        cudaStreamCreate(&stream);

        nvcomp::Decompressor<int> decompressor(d_huff_multibyte, total_uInts * sizeof(Huff), stream);
        const size_t              temp_size = decompressor.get_temp_size();
        void*                     temp_space;
        cudaMalloc(&temp_space, temp_size);

        const size_t output_count = decompressor.get_num_elements();
        int*         output_space;
        cudaMalloc((void**)&output_space, output_count * sizeof(int));

        decompressor.decompress_async(temp_space, temp_size, output_space, output_count, stream);

        cudaStreamSynchronize(stream);
        cudaFree(d_huff_multibyte);

        d_huff_multibyte = mem::CreateCUDASpace<Huff>((unsigned long)(output_count * sizeof(int)));
        cudaMemcpy(d_huff_multibyte, output_space, output_count * sizeof(int), cudaMemcpyDeviceToDevice);
        total_uInts = output_count * sizeof(int) / sizeof(Huff);

        cudaFree(output_space);

        cudaStreamDestroy(stream);
        cudaFree(temp_space);
    }

    auto d_huff_chunk_meta = mem::CreateDeviceSpaceAndMemcpyFromHost(huff_chunk_meta, 2 * n_chunk);
    auto d_canonical_byte  = mem::CreateDeviceSpaceAndMemcpyFromHost(canonical_byte, canonical_meta);
    cudaDeviceSynchronize();

    lossless::wrapper::Decode<<<grid_dim, block_dim, canonical_meta>>>(  //
        d_huff_multibyte, d_huff_chunk_meta, d_xq, len, chunk_size, n_chunk, d_canonical_byte, (size_t)canonical_meta);
    cudaDeviceSynchronize();

    auto xq = mem::CreateHostSpaceAndMemcpyFromDevice(d_xq, len);
    cudaFree(d_xq);
    cudaFree(d_huff_multibyte);
    cudaFree(d_huff_chunk_meta);
    cudaFree(d_canonical_byte);
    delete[] huff_multibyte;
    delete[] huff_chunk_meta;
    delete[] canonical_byte;

    return xq;
}

// TODO mark types using Q/H-byte binding; internally resolve UI8-UI8_2 issue
// using Q1 = QuantTrait<1>::Quant;
// using H4 = HuffTrait<4>::Huff;

// clang-format off
template tuple_3ul_1bool lossless::interface::HuffmanEncode<UI1, UI4, FP4>(string&, UI1*, size_t, int, bool, int, bool);
template tuple_3ul_1bool lossless::interface::HuffmanEncode<UI2, UI4, FP4>(string&, UI2*, size_t, int, bool, int, bool);
template tuple_3ul_1bool lossless::interface::HuffmanEncode<UI1, UI8, FP4>(string&, UI1*, size_t, int, bool, int, bool);
template tuple_3ul_1bool lossless::interface::HuffmanEncode<UI2, UI8, FP4>(string&, UI2*, size_t, int, bool, int, bool);

template UI1* lossless::interface::HuffmanDecode<UI1, UI4, FP4>(std::string&, size_t, int, int, bool, int);
template UI2* lossless::interface::HuffmanDecode<UI2, UI4, FP4>(std::string&, size_t, int, int, bool, int);
template UI1* lossless::interface::HuffmanDecode<UI1, UI8, FP4>(std::string&, size_t, int, int, bool, int);
template UI2* lossless::interface::HuffmanDecode<UI2, UI8, FP4>(std::string&, size_t, int, int, bool, int);

template void lossless::interface::HuffmanEncodeWithTree_3D<UI1, UI4>(Index<3>::idx_t, string&, UI1*, size_t, int);
template void lossless::interface::HuffmanEncodeWithTree_3D<UI1, UI8>(Index<3>::idx_t, string&, UI1*, size_t, int);
template void lossless::interface::HuffmanEncodeWithTree_3D<UI2, UI4>(Index<3>::idx_t, string&, UI2*, size_t, int);
template void lossless::interface::HuffmanEncodeWithTree_3D<UI2, UI8>(Index<3>::idx_t, string&, UI2*, size_t, int);
