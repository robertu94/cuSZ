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
#include "type_aliasing.hh"
#include "type_trait.hh"
#include "types.hh"
#include "utils/cuda_err.cuh"
#include "utils/cuda_mem.cuh"
#include "utils/format.hh"
#include "utils/io.hh"
#include "utils/timer.hh"

#include "cascaded.hpp"
#include "nvcomp.hpp"

#if __cplusplus >= 201703L
#define CONSTEXPR constexpr
#else
#define CONSTEXPR
#endif

typedef std::tuple<size_t, size_t, size_t, bool> tuple_3ul_1bool;
namespace kernel = data_process::reduce;

#define nworker blockDim.x

template <typename Huff>
__global__ void draft::CopyHuffmanUintsDenseToSparse(
    Huff*   input_dn,
    Huff*   output_sp,
    size_t* sp_entries,
    size_t* sp_uints,
    size_t  dn_chunk_size)
{
    auto len      = sp_uints[blockIdx.x];
    auto sp_entry = sp_entries[blockIdx.x];
    auto dn_entry = dn_chunk_size * blockIdx.x;

    for (auto i = 0; i < (len + nworker - 1) / nworker; i++) {
        auto _tid = threadIdx.x + i * nworker;
        if (_tid < len) *(output_sp + sp_entry + _tid) = *(input_dn + dn_entry + _tid);
        __syncthreads();
    }
}

template <typename Huff>
void draft::GatherSpHuffMetadata(
    size_t* _counts,
    size_t* d_sp_bits,
    size_t  nchunk,
    size_t& total_bits,
    size_t& total_uints)
{
    static const size_t Huff_bytes = sizeof(Huff) * 8;

    auto sp_uints = _counts, sp_bits = _counts + nchunk, sp_entries = _counts + nchunk * 2;

    cudaMemcpy(sp_bits, d_sp_bits, nchunk * sizeof(size_t), cudaMemcpyDeviceToHost);
    memcpy(sp_uints, sp_bits, nchunk * sizeof(size_t));
    for_each(sp_uints, sp_uints + nchunk, [&](size_t& i) { i = (i + Huff_bytes - 1) / Huff_bytes; });
    memcpy(sp_entries + 1, sp_uints, (nchunk - 1) * sizeof(size_t));
    for (auto i = 1; i < nchunk; i++) sp_entries[i] += sp_entries[i - 1];  // inclusive scan

    total_bits  = std::accumulate(sp_bits, sp_bits + nchunk, (size_t)0);
    total_uints = std::accumulate(sp_uints, sp_uints + nchunk, (size_t)0);

    //    auto fmt_enc1 = "Huffman enc: (#) " + std::to_string(nchunk) + " x " + std::to_string(dn_chunk);
    //    auto fmt_enc2 = std::to_string(total_uints) + " " + std::to_string(sizeof(Huff)) + "-byte words or " +
    //                    std::to_string(total_bits) + " bits";
    //    LogAll(log_dbg, fmt_enc1, "=>", fmt_enc2);
}

template <typename T>
void draft::UseNvcompZip(T* space, size_t& len)
{
    int*         uncompressed_data;
    const size_t in_bytes = len * sizeof(T);

    cudaMalloc(&uncompressed_data, in_bytes);
    cudaMemcpy(uncompressed_data, space, in_bytes, cudaMemcpyHostToDevice);
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
    // TODO ad hoc; should use original GPU space
    memset(space, 0x0, len * sizeof(T));
    len = output_size / sizeof(T);
    cudaMemcpy(space, output_space, output_size, cudaMemcpyDeviceToHost);

    cudaFree(uncompressed_data);
    cudaFree(temp_space);
    cudaFree(output_space);
    cudaStreamDestroy(stream);
}

template <typename T>
void draft::UseNvcompUnzip(T** d_space, size_t& len)
{
    cudaStream_t stream;
    cudaStreamCreate(&stream);

    nvcomp::Decompressor<int> decompressor(*d_space, len * sizeof(T), stream);
    const size_t              temp_size = decompressor.get_temp_size();
    void*                     temp_space;
    cudaMalloc(&temp_space, temp_size);

    const size_t output_count = decompressor.get_num_elements();
    int*         output_space;
    cudaMalloc((void**)&output_space, output_count * sizeof(int));

    decompressor.decompress_async(temp_space, temp_size, output_space, output_count, stream);

    cudaStreamSynchronize(stream);
    cudaFree(*d_space);

    *d_space = mem::CreateCUDASpace<T>((unsigned long)(output_count * sizeof(int)));
    cudaMemcpy(*d_space, output_space, output_count * sizeof(int), cudaMemcpyDeviceToDevice);
    len = output_count * sizeof(int) / sizeof(T);

    cudaFree(output_space);

    cudaStreamDestroy(stream);
    cudaFree(temp_space);
}

template <typename Input>
void lossless::wrapper::GetFrequency(Input* d_in, size_t len, unsigned int* d_freq, int dict_size)
{
    static_assert(
        std::is_same<Input, UI1>::value         //
            or std::is_same<Input, UI2>::value  //
            or std::is_same<Input, I1>::value   //
            or std::is_same<Input, I2>::value,
        "To get frequency, input dtype must be uint/int{8,16}_t");

    // Parameters for thread and block count optimization
    // Initialize to device-specific values
    int deviceId, max_bytes, max_bytes_opt_in, num_SMs;

    cudaGetDevice(&deviceId);
    cudaDeviceGetAttribute(&max_bytes, cudaDevAttrMaxSharedMemoryPerBlock, deviceId);
    cudaDeviceGetAttribute(&num_SMs, cudaDevAttrMultiProcessorCount, deviceId);

    // Account for opt-in extra shared memory on certain architectures
    cudaDeviceGetAttribute(&max_bytes_opt_in, cudaDevAttrMaxSharedMemoryPerBlockOptin, deviceId);
    max_bytes = std::max(max_bytes, max_bytes_opt_in);

    // Optimize launch
    int num_buckets      = dict_size;
    int num_values       = len;
    int items_per_thread = 1;
    int r_per_block      = (max_bytes / (int)sizeof(int)) / (num_buckets + 1);
    int num_blocks       = num_SMs;
    // fits to size
    int threads_per_block = ((((num_values / (num_blocks * items_per_thread)) + 1) / 64) + 1) * 64;
    while (threads_per_block > 1024) {
        if (r_per_block <= 1) { threads_per_block = 1024; }
        else {
            r_per_block /= 2;
            num_blocks *= 2;
            threads_per_block = ((((num_values / (num_blocks * items_per_thread)) + 1) / 64) + 1) * 64;
        }
    }

    if CONSTEXPR (
        std::is_same<Input, UI1>::value     //
        or std::is_same<Input, UI2>::value  //
        or std::is_same<Input, UI4>::value) {
        cudaFuncSetAttribute(
            kernel::p2013Histogram<Input, unsigned int>, cudaFuncAttributeMaxDynamicSharedMemorySize, max_bytes);
        kernel::p2013Histogram                                                                    //
            <<<num_blocks, threads_per_block, ((num_buckets + 1) * r_per_block) * sizeof(int)>>>  //
            (d_in, d_freq, num_values, num_buckets, r_per_block);
    }
    else if CONSTEXPR (
        std::is_same<Input, I1>::value     //
        or std::is_same<Input, I2>::value  //
        or std::is_same<Input, I4>::value) {
        cudaFuncSetAttribute(
            kernel::p2013Histogram_int_input<Input, unsigned int>, cudaFuncAttributeMaxDynamicSharedMemorySize,
            max_bytes);
        kernel::p2013Histogram_int_input                                                          //
            <<<num_blocks, threads_per_block, ((num_buckets + 1) * r_per_block) * sizeof(int)>>>  //
            (d_in, d_freq, num_values, num_buckets, r_per_block, dict_size / 2);
    }
    else {
        LogAll(log_err, "must be Signed or Unsigned integer as Input type");
    }

    cudaDeviceSynchronize();
}

template <typename Quant, typename Huff, typename Data>
tuple_3ul_1bool lossless::interface::HuffmanEncode(
    string&  basename,
    Quant*   d_input,
    Huff*    d_canon_cb,
    uint8_t* d_reverse_cb,
    size_t   _nbyte,
    size_t   len,
    int      dn_chunk,
    bool     to_nvcomp,
    int      dict_size)
{
    static const auto type_bitcount = sizeof(Huff) * 8;  // canonical Huffman; follows H to decide first and entry type

    auto get_Dg = [](size_t problem_size, size_t Db) { return (problem_size + Db - 1) / Db; };

    auto decode_meta = mem::CreateHostSpaceAndMemcpyFromDevice(d_reverse_cb, _nbyte);
    io::WriteArrayToBinary(
        basename + ".canon", reinterpret_cast<uint8_t*>(decode_meta),
        sizeof(Huff) * (2 * type_bitcount) + sizeof(Quant) * dict_size);
    delete[] decode_meta;

    // Huffman space in dense format (full of zeros), fix-length space
    auto d_huff_dn = mem::CreateCUDASpace<Huff>(len + dn_chunk + HuffConfig::Db_encode);  // TODO ad hoc (big) padding
    {
        auto Db = HuffConfig::Db_encode;
        lossless::wrapper::EncodeFixedLen_cub<Quant, Huff, HuffConfig::enc_sequentiality>
            <<<get_Dg(len, Db), Db / HuffConfig::enc_sequentiality>>>(d_input, d_huff_dn, len, d_canon_cb);
        cudaDeviceSynchronize();
    }

    // deflate
    auto nchunk    = (len + dn_chunk - 1) / dn_chunk;
    auto d_sp_bits = mem::CreateCUDASpace<size_t>(nchunk);
    {
        auto Db = HuffConfig::Db_deflate;
        lossless::wrapper::Deflate<Huff><<<get_Dg(nchunk, Db), Db>>>(d_huff_dn, len, d_sp_bits, dn_chunk);
        cudaDeviceSynchronize();
    }

    // gather metadata (without write) before gathering huff as sp on GPU
    auto   _counts    = new size_t[nchunk * 3]();
    size_t total_bits = 0, total_uints = 0;
    draft::GatherSpHuffMetadata<Huff>(_counts, d_sp_bits, nchunk, total_bits, total_uints);

    // partially gather on GPU and copy back (TODO fully)
    auto huff_sp = new Huff[total_uints]();
    {
        auto d_huff_sp = mem::CreateCUDASpace<Huff>(total_uints);
        auto d_uints   = mem::CreateDeviceSpaceAndMemcpyFromHost(_counts, nchunk);               // sp_uints
        auto d_entries = mem::CreateDeviceSpaceAndMemcpyFromHost(_counts + nchunk * 2, nchunk);  // sp_entries
        draft::CopyHuffmanUintsDenseToSparse<<<nchunk, 128>>>(d_huff_dn, d_huff_sp, d_entries, d_uints, dn_chunk);
        cudaDeviceSynchronize();
        cudaMemcpy(huff_sp, d_huff_sp, total_uints * sizeof(Huff), cudaMemcpyDeviceToHost);
        cudaFree(d_entries), cudaFree(d_uints), cudaFree(d_huff_sp);
    }

    // use nvcomp, which changes metadata to write to fs
    bool status_nvcomp_in_use = false;
    if (to_nvcomp) {
        draft::UseNvcompZip<Huff>(huff_sp, total_uints);
        status_nvcomp_in_use = true;
    }

    // write metadata to fs
    io::WriteArrayToBinary(basename + ".hmeta", _counts + nchunk, 2 * nchunk);
    io::WriteArrayToBinary(basename + ".hbyte", huff_sp, total_uints);

    size_t metadata_size =
        (2 * nchunk) * sizeof(decltype(_counts)) + sizeof(Huff) * (2 * type_bitcount) + sizeof(Quant) * dict_size;

    // clean up
    cudaFree(d_huff_dn), cudaFree(d_sp_bits);
    delete[] huff_sp, delete[] _counts;

    return std::make_tuple(total_bits, total_uints, metadata_size, status_nvcomp_in_use);
}

/**
 * @brief experiment warpup; use after dual-quant; of anysize
 * @todo experiment only, no decoding yet
 */
template <typename Quant, typename Huff, typename Data>
void lossless::interface::HuffmanEncodeWithTree_3D(
    Index<3>::idx_t idx,
    string&         basename,
    Quant*          h_quant_in,
    size_t          len,
    int             dict_size)
{
    auto d_quant_in = mem::CreateDeviceSpaceAndMemcpyFromHost(h_quant_in, len);

    auto d_freq = mem::CreateCUDASpace<unsigned int>(dict_size);
    lossless::wrapper::GetFrequency(d_quant_in, len, d_freq, dict_size);
    cudaFree(d_freq);
    auto h_freq = mem::CreateHostSpaceAndMemcpyFromDevice(d_freq, dict_size);

    auto entropy = GetEntropyFromFrequency(h_freq, len, dict_size);

    std::stringstream s;
    s << basename + "-" << dict_size << "-ui" << sizeof(Huff) << ".lean_cb";
    auto h_cb       = io::ReadBinaryToNewArray<Huff>(s.str(), dict_size);
    auto d_canon_cb = mem::CreateDeviceSpaceAndMemcpyFromHost(h_cb, dict_size);

    auto get_Dg = [](size_t problem_size, size_t Db) { return (problem_size + Db - 1) / Db; };

    // Huffman space in dense format (full of zeros), fix-length space
    auto d_huff_dn = mem::CreateCUDASpace<Huff>(len);
    {
        auto Db = HuffConfig::Db_encode;
        lossless::wrapper::EncodeFixedLen<Quant, Huff><<<get_Dg(len, Db), Db>>>(d_quant_in, d_huff_dn, len, d_canon_cb);
        cudaDeviceSynchronize();
    }

    const static int dn_chunk = 4096;
    // deflate
    auto nchunk    = (len + dn_chunk - 1) / dn_chunk;
    auto d_sp_bits = mem::CreateCUDASpace<size_t>(nchunk);
    {
        auto Db = HuffConfig::Db_deflate;
        lossless::wrapper::Deflate<Huff><<<get_Dg(nchunk, Db), Db>>>(d_huff_dn, len, d_sp_bits, dn_chunk);
        cudaDeviceSynchronize();
    }

    // gather metadata (without write) before gathering huff as sp on GPU
    auto   _counts    = new size_t[nchunk * 3]();
    size_t total_bits = 0, total_uints = 0;
    draft::GatherSpHuffMetadata<Huff>(_counts, d_sp_bits, nchunk, total_bits, total_uints);

    // partially gather on GPU and copy back (TODO fully)
    auto huff_sp = new Huff[total_uints]();
    {
        auto d_huff_sp = mem::CreateCUDASpace<Huff>(total_uints);
        auto d_uints   = mem::CreateDeviceSpaceAndMemcpyFromHost(_counts, nchunk);               // sp_uints
        auto d_entries = mem::CreateDeviceSpaceAndMemcpyFromHost(_counts + nchunk * 2, nchunk);  // sp_entries
        draft::CopyHuffmanUintsDenseToSparse<<<nchunk, 128>>>(d_huff_dn, d_huff_sp, d_entries, d_uints, dn_chunk);
        cudaDeviceSynchronize();
        cudaMemcpy(huff_sp, d_huff_sp, total_uints * sizeof(Huff), cudaMemcpyDeviceToHost);
        cudaFree(d_entries), cudaFree(d_uints), cudaFree(d_huff_sp);
    }

    cudaFree(d_huff_dn);

    io::WriteArrayToBinary(
        basename + "_huff_" + std::to_string(len) + "_part_" + std::to_string(idx._0) + std::to_string(idx._1) +
            std::to_string(idx._2),
        huff_sp, total_uints);

    auto total_uints_before_nvcomp = total_uints;
    //    draft::UseNvcompZip<Huff>(huff_sp, total_uints);
    //    auto total_uints_after_nvcomp = total_uints;
    auto avg_bits         = 1.0 * total_bits / len;
    auto cr_before_nvcomp = 1.0 * len * sizeof(Data) / (total_uints_before_nvcomp * sizeof(Huff));
    //    auto cr_after_nvcomp  = 1.0 * len * sizeof(Data) / (total_uints_after_nvcomp * sizeof(Huff));

    LogAll(
        log_exp,                                   //
        idx._0, idx._1, idx._2, "\t",              //
        std::setprecision(4),                      //
        " \e[1mavg bitcount:", avg_bits, "\e[0m",  //
        " CR before nvcomp:", cr_before_nvcomp);

    delete[] huff_sp;

    cudaFree(d_freq);
    cudaFree(d_quant_in);
}

template <typename Quant, typename Huff, typename Data>
Quant* lossless::interface::HuffmanDecode(
    std::string& basename,  //
    size_t       len,
    int          chunk_size,
    size_t       total_uints,
    bool         nvcomp_in_use,
    int          dict_size)
{
    auto type_bw    = sizeof(Huff) * 8;
    auto canon_meta = sizeof(Huff) * (2 * type_bw) + sizeof(Quant) * dict_size;
    auto canon_byte = io::ReadBinaryToNewArray<uint8_t>(basename + ".canon", canon_meta);

    auto nchunk       = (len - 1) / chunk_size + 1;
    auto huff_sp      = io::ReadBinaryToNewArray<Huff>(basename + ".hbyte", total_uints);
    auto huff_sp_meta = io::ReadBinaryToNewArray<size_t>(basename + ".hmeta", 2 * nchunk);
    auto Db           = HuffConfig::Db_deflate;  // the same as deflating
    auto Dg           = (nchunk - 1) / Db + 1;

    auto d_xq      = mem::CreateCUDASpace<Quant>(len);
    auto d_huff_sp = mem::CreateDeviceSpaceAndMemcpyFromHost(huff_sp, total_uints);

    if (nvcomp_in_use) draft::UseNvcompUnzip(&d_huff_sp, total_uints);

    auto d_huff_sp_meta = mem::CreateDeviceSpaceAndMemcpyFromHost(huff_sp_meta, 2 * nchunk);
    auto d_canon_byte   = mem::CreateDeviceSpaceAndMemcpyFromHost(canon_byte, canon_meta);
    cudaDeviceSynchronize();

    lossless::wrapper::Decode<<<Dg, Db, canon_meta>>>(  //
        d_huff_sp, d_huff_sp_meta, d_xq, len, chunk_size, nchunk, d_canon_byte, (size_t)canon_meta);
    cudaDeviceSynchronize();

    auto xq = mem::CreateHostSpaceAndMemcpyFromDevice(d_xq, len);
    cudaFree(d_xq);
    cudaFree(d_huff_sp);
    cudaFree(d_huff_sp_meta);
    cudaFree(d_canon_byte);
    delete[] huff_sp;
    delete[] huff_sp_meta;
    delete[] canon_byte;

    return xq;
}

// TODO mark types using Q/H-byte binding; internally resolve UI8-UI8_2 issue
// using Q1 = QuantTrait<1>::Quant;
// using H4 = HuffTrait<4>::Huff;

// clang-format off
template tuple_3ul_1bool lossless::interface::HuffmanEncode<UI1, UI4, FP4>(string&, UI1*, UI4*, uint8_t*, size_t, size_t, int, bool, int);
template tuple_3ul_1bool lossless::interface::HuffmanEncode<UI2, UI4, FP4>(string&, UI2*, UI4*, uint8_t*, size_t, size_t, int, bool, int);
template tuple_3ul_1bool lossless::interface::HuffmanEncode<UI1, UI8, FP4>(string&, UI1*, UI8*, uint8_t*, size_t, size_t, int, bool, int);
template tuple_3ul_1bool lossless::interface::HuffmanEncode<UI2, UI8, FP4>(string&, UI2*, UI8*, uint8_t*, size_t, size_t, int, bool, int);

template UI1* lossless::interface::HuffmanDecode<UI1, UI4, FP4>(std::string&, size_t, int, size_t, bool, int);
template UI2* lossless::interface::HuffmanDecode<UI2, UI4, FP4>(std::string&, size_t, int, size_t, bool, int);
template UI1* lossless::interface::HuffmanDecode<UI1, UI8, FP4>(std::string&, size_t, int, size_t, bool, int);
template UI2* lossless::interface::HuffmanDecode<UI2, UI8, FP4>(std::string&, size_t, int, size_t, bool, int);

template void lossless::interface::HuffmanEncodeWithTree_3D<UI1, UI4>(Index<3>::idx_t, string&, UI1*, size_t, int);
template void lossless::interface::HuffmanEncodeWithTree_3D<UI1, UI8>(Index<3>::idx_t, string&, UI1*, size_t, int);
template void lossless::interface::HuffmanEncodeWithTree_3D<UI2, UI4>(Index<3>::idx_t, string&, UI2*, size_t, int);
template void lossless::interface::HuffmanEncodeWithTree_3D<UI2, UI8>(Index<3>::idx_t, string&, UI2*, size_t, int);
