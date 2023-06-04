/**
 * @file base_compressor.cuh
 * @author Jiannan Tian
 * @brief T-only Base Compressor; can also be used for dryrun.
 * @version 0.3
 * @date 2021-10-05
 *
 * (C) 2021 by Washington State University, Argonne National Laboratory
 *
 */

#ifndef BB504423_E0DF_4AAA_8AF3_BEEEA28053DB
#define BB504423_E0DF_4AAA_8AF3_BEEEA28053DB

#include "common/definition.hh"
#include "common/type_traits.hh"
#include "context.hh"
// #include "hf/hf.hh"
#include "kernel/dryrun.cuh"
// #include "pipeline/prediction.inl"
// #include "pipeline/spcodec.inl"
#include "stat/compare_gpu.hh"
#include "utils.hh"
#include "utils/analyzer.hh"
#include "utils/configs.hh"
#include "utils/quality_viewer.hh"
#include "utils/verify.hh"

namespace cusz {

template <typename T>
Dryrunner<T>&
Dryrunner<T>::generic_dryrun(const std::string fname, double eb, int radius, bool r2r, cudaStream_t stream)
{
    throw std::runtime_error("Generic dryrun is disabled.");
    return *this;
}

template <typename T>
Dryrunner<T>& Dryrunner<T>::dualquant_dryrun(const std::string fname, double eb, bool r2r, cudaStream_t stream)
{
    auto len = original.len();

    original.fromfile(fname).host2device_async(stream);
    CHECK_CUDA(cudaStreamSynchronize(stream));

    if (r2r) original.prescan(max, min, rng), eb *= rng;

    auto ebx2_r = 1 / (eb * 2);
    auto ebx2   = eb * 2;

    cusz::dualquant_dryrun_kernel                                              //
        <<<ConfigHelper::get_npart(len, 256), 256, 256 * sizeof(T), stream>>>  //
        (original.dptr(), reconst.dptr(), len, ebx2_r, ebx2);

    reconst.device2host_async(stream);
    CHECK_CUDA(cudaStreamSynchronize(stream));

    cusz_stats stat;
    psz::thrustgpu_assess_quality(&stat, reconst.hptr(), original.hptr(), len);
    cusz::QualityViewer::print_metrics_cross<T>(&stat, 0, true);

    return *this;
}

template <typename T>
Dryrunner<T>::~Dryrunner()
{
}

template <typename T>
Dryrunner<T>& Dryrunner<T>::init_generic_dryrun(dim3 size)
{
    throw std::runtime_error("Generic dryrun is disabled.");
    return *this;
}

template <typename T>
Dryrunner<T>& Dryrunner<T>::destroy_generic_dryrun()
{
    throw std::runtime_error("Generic dryrun is disabled.");
    return *this;
}

template <typename T>
Dryrunner<T>& Dryrunner<T>::init_dualquant_dryrun(dim3 size)
{
    auto len = size.x * size.y * size.z;
    original.set_len(len).mallochost().malloc();
    reconst.set_len(len).mallochost().malloc();

    return *this;
}

template <typename T>
Dryrunner<T>& Dryrunner<T>::destroy_dualquant_dryrun()
{
    original.freehost().free();
    reconst.freehost().free();

    return *this;
}

}  // namespace cusz

#endif /* BB504423_E0DF_4AAA_8AF3_BEEEA28053DB */