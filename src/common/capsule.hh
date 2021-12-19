/**
 * @file capsule.hh
 * @author Jiannan Tian
 * @brief Simple data analysis (header)
 * @version 0.2.3
 * @date 2020-11-03
 * (create) 2020-11-03 (rev1) 2021-03-24 (rev2) 2021-09-08
 *
 * @copyright (C) 2020 by Washington State University, Argonne National Laboratory
 * See LICENSE in top-level directory
 *
 */

#ifndef CAPSULE_HH
#define CAPSULE_HH

#if __cplusplus >= 201703L
#define CONSTEXPR constexpr
#else
#define CONSTEXPR
#endif

#ifdef __CUDACC__
#include <cuda_runtime.h>
#include <driver_types.h>
#include <thrust/device_ptr.h>
#include <thrust/extrema.h>
#endif

#include <stdexcept>
#include <string>

#include "../utils/io.hh"
#include "../utils/timer.hh"
#include "configs.hh"
#include "definition.hh"

using cusz::OK;
using std::string;

template <typename T, bool USE_UNIFIED = false>
class Capsule {
   private:
    static const bool use_unified = USE_UNIFIED;

    template <cusz::LOC LOC>
    void raise_error_if_misuse_unified()
    {
        static_assert(
            (LOC == cusz::LOC::UNIFIED and USE_UNIFIED == true)           //
                or (LOC != cusz::LOC::UNIFIED and USE_UNIFIED == false),  //
            "[Capsule] misused unified memory API");
    }

    template <cusz::LOC LOC>
    void hostdevice_not_allowed()
    {
        static_assert(LOC != cusz::LOC::HOST_DEVICE, "[Capsule] LOC at HOST_DEVICE not allowed");
    }

    std::string ERRSTR_BUILDER(std::string func, std::string msg)
    {  //
        return "[Capsule(\"" + name + "\")::" + func + "] " + msg;
    }

    std::string ERROR_UNDEFINED_BEHAVIOR(std::string func, std::string msg = "undefined behavior")
    {  //
        return ERRSTR_BUILDER(func, "undefined behavior");
    }

   public:
    using type = T;
    unsigned int len;

    std::string name;

    T* dptr;
    T* hptr;
    T* uniptr;

    template <cusz::LOC LOC = cusz::LOC::UNIFIED>
    T*& get()
    {
        raise_error_if_misuse_unified<LOC>();
        hostdevice_not_allowed<LOC>();

        if CONSTEXPR (LOC == cusz::LOC::HOST)
            return hptr;
        else if (LOC == cusz::LOC::DEVICE)
            return dptr;
        else if (LOC == cusz::LOC::UNIFIED)
            return uniptr;
        else
            throw std::runtime_error(ERROR_UNDEFINED_BEHAVIOR("get"));
    }

    template <cusz::LOC LOC = cusz::LOC::UNIFIED>
    T* set(T* ptr)
    {
        raise_error_if_misuse_unified<LOC>();
        hostdevice_not_allowed<LOC>();

        if CONSTEXPR (LOC == cusz::LOC::HOST)
            hptr = ptr;
        else if (LOC == cusz::LOC::DEVICE)
            dptr = ptr;
        else if (LOC == cusz::LOC::UNIFIED)  // rare
            uniptr = ptr;
        else
            throw std::runtime_error(ERROR_UNDEFINED_BEHAVIOR("set"));
    }

    Capsule() = default;

    Capsule(unsigned int _len, const std::string _str = std::string("<unnamed>")) : len(_len), name(_str) {}

    Capsule(const string _str) : name(_str){};

    Capsule(T* _h_in, T* _d_in, unsigned int _len) : hptr(_h_in), dptr(_d_in), len(_len) {}

    Capsule& set_name(std::string _str)
    {
        name = _str;
        return *this;
    }

    Capsule& set_len(unsigned int _len)
    {
        len = _len;
        return *this;
    }

    template <cusz::ALIGNDATA AD = cusz::ALIGNDATA::NONE>
    unsigned int get_len()
    {
        return Align::get_aligned_datalen<AD>(len);
    }

    template <cusz::LOC LOC>
    Capsule& shallow_copy(T* in)
    {
        raise_error_if_misuse_unified<LOC>();
        hostdevice_not_allowed<LOC>();

        if (LOC == cusz::LOC::HOST)
            hptr = in;
        else if (LOC == cusz::LOC::DEVICE)
            dptr = in;
        else if (LOC == cusz::LOC::UNIFIED)
            uniptr = in;
        else
            throw std::runtime_error(ERROR_UNDEFINED_BEHAVIOR("shallow_copy"));

        return *this;
    }

    /**
     * @brief specify single-source data
     *
     * @tparam DST the destination of loaded data
     * @tparam VIA the ephemeral/in transition
     * @param fname
     * @return Capsule&
     */
    template <cusz::LOC DST, cusz::LOC VIA = cusz::LOC::NONE>
    Capsule& from_fs_to(std::string fname, double* time = nullptr)
    {
        auto a = hires::now();

        if (DST == cusz::LOC::HOST) {
            if (VIA == cusz::LOC::NONE) {
                if (not hptr) {  //
                    throw std::runtime_error(ERRSTR_BUILDER("from_fs_to", "hptr not set"));
                }
                io::read_binary_to_array<T>(fname, hptr, len);
            }
            else {
                throw std::runtime_error(ERROR_UNDEFINED_BEHAVIOR("from_fs_to"));
            }
        }
        else if (DST == cusz::LOC::DEVICE) {
            throw std::runtime_error(ERRSTR_BUILDER("from_fs_to", "to DEVICE not implemented"));
            // (VIA == cusz::LOC::HOST)
            // (VIA == cusz::LOC::NONE)
        }
        else if (DST == cusz::LOC::UNIFIED) {
            if (not uniptr) {  //
                throw std::runtime_error(ERRSTR_BUILDER("from_fs_to", "uniptr not set"));
            }
            io::read_binary_to_array<T>(fname, uniptr, len);
        }
        else {
            throw std::runtime_error(ERROR_UNDEFINED_BEHAVIOR("from_fs_to"));
        }

        auto z = hires::now();
        if (time) *time = static_cast<duration_t>(z - a).count();

        return *this;
    }

    template <cusz::LOC SRC, cusz::LOC VIA = cusz::LOC::NONE>
    Capsule& to_fs_from(std::string fname)
    {
        if (SRC == cusz::LOC::HOST) {
            if (not hptr) {  //
                throw std::runtime_error(ERRSTR_BUILDER("to_fs_from", "hptr not set"));
            }
            io::write_array_to_binary<T>(fname, hptr, len);
        }
        else if (SRC == cusz::LOC::UNIFIED) {
            if (not uniptr) {  //
                throw std::runtime_error(ERRSTR_BUILDER("to_fs_from", "uniptr not set"));
            }
            io::write_array_to_binary<T>(fname, uniptr, len);
        }
        else {
            throw std::runtime_error(ERROR_UNDEFINED_BEHAVIOR("to_fs_from"));
        }
        return *this;
    }

    unsigned int nbyte() const { return len * sizeof(T); }

    // TODO really useful?
    Capsule& memset(unsigned char init = 0x0u)
    {
        cudaMemset(dptr, init, nbyte());
        return *this;
    }

    Capsule& host2device()
    {
        cudaMemcpy(dptr, hptr, nbyte(), cudaMemcpyHostToDevice);
        return *this;
    }

    Capsule& device2host()
    {
        cudaMemcpy(hptr, dptr, nbyte(), cudaMemcpyDeviceToHost);
        return *this;
    }

    Capsule& host2device_async(cudaStream_t stream)
    {
        cudaMemcpyAsync(dptr, hptr, nbyte(), cudaMemcpyHostToDevice, stream);
        return *this;
    }

    Capsule& device2host_async(cudaStream_t stream)
    {
        cudaMemcpyAsync(hptr, dptr, nbyte(), cudaMemcpyDeviceToHost, stream);
        return *this;
    }

    /**
     * @brief
     *
     * @tparam LOC where to allocate: HOST, DEVICE, HOST_DEVICE, UNIFIED
     * @tparam AD alignment of data length; not reflecting the real datalen
     * @tparam AM alignment of underlying memory; not reflecting the real datalen
     * @tparam M mode, use with caution (easy to disable repo-wide)
     * @return Capsule& return *this for chained call
     */
    template <
        cusz::LOC       LOC,  //
        cusz::ALIGNDATA AD = cusz::ALIGNDATA::NONE,
        cusz::ALIGNMEM  AM = cusz::ALIGNMEM::WARP128B,
        cusz::DEV       M  = cusz::DEV::DEV>
    Capsule& alloc()
    {
        OK::ALLOC<M>();
        raise_error_if_misuse_unified<LOC>();

        auto aligned_datalen    = Align::get_aligned_datalen<AD>(len);
        auto __memory_footprint = Align::get_aligned_nbyte<T>(aligned_datalen);

        if (LOC == cusz::LOC::HOST) {
            cudaMallocHost(&hptr, __memory_footprint);
            cudaMemset(hptr, 0x00, __memory_footprint);
        }
        else if (LOC == cusz::LOC::DEVICE) {
            cudaMalloc(&dptr, __memory_footprint);
            cudaMemset(dptr, 0x00, __memory_footprint);
        }
        else if (LOC == cusz::LOC::HOST_DEVICE) {
            cudaMallocHost(&hptr, __memory_footprint);
            cudaMemset(hptr, 0x00, __memory_footprint);
            cudaMalloc(&dptr, __memory_footprint);
            cudaMemset(dptr, 0x00, __memory_footprint);
        }
        else if (LOC == cusz::LOC::UNIFIED) {
            cudaMallocManaged(&uniptr, __memory_footprint);
            cudaMemset(uniptr, 0x00, __memory_footprint);
        }
        else {
            throw std::runtime_error(ERROR_UNDEFINED_BEHAVIOR("alloc"));
        }

        return *this;
    }

    template <cusz::LOC LOC, cusz::DEV M = cusz::DEV::DEV>
    Capsule& free()
    {
        OK::FREE<M>();
        raise_error_if_misuse_unified<LOC>();

        if (LOC == cusz::LOC::HOST)
            cudaFreeHost(hptr);
        else if (LOC == cusz::LOC::DEVICE)
            cudaFree(dptr);
        else if (LOC == cusz::LOC::HOST_DEVICE) {
            cudaFreeHost(hptr);
            cudaFree(dptr);
        }
        else if (LOC == cusz::LOC::UNIFIED) {
            cudaFree(uniptr);
        }
        else {
            throw std::runtime_error(ERROR_UNDEFINED_BEHAVIOR("free"));
        }

        return *this;
    }

   private:
    double maxval, minval, rng;

   public:
    double get_maxval() { return maxval; }
    double get_minval() { return minval; }
    double get_rng() { return rng; }

    Capsule& prescan(double& max_value, double& min_value, double& rng)
    {
        thrust::device_ptr<T> g_ptr;

        if (use_unified)
            g_ptr = thrust::device_pointer_cast(uniptr);
        else
            g_ptr = thrust::device_pointer_cast(dptr);

        // excluding padded
        auto max_el_loc = thrust::max_element(g_ptr, g_ptr + len);
        auto min_el_loc = thrust::min_element(g_ptr, g_ptr + len);

        max_value = *max_el_loc;
        min_value = *min_el_loc;
        rng       = max_value - min_value;

        return *this;
    }

    Capsule& prescan()
    {
        prescan(maxval, minval, rng);
        return *this;
    }
};

#endif