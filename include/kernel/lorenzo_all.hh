/**
 * @file kernel_cuda.hh
 * @author Jiannan Tian
 * @brief
 * @version 0.3
 * @date 2022-11-01
 *
 * (C) 2022 by Indiana University, Argonne National Laboratory
 *
 */

#ifndef C8C37773_7EF2_439B_B0EF_14D0058DC714
#define C8C37773_7EF2_439B_B0EF_14D0058DC714

#include <stdint.h>
#include "cusz/type.h"

template <typename T, typename E, typename FP>
cusz_error_status compress_predict_lorenzo_i(
    T* const     data,          // input
    dim3 const   data_len3,     //
    double const eb,            // input (config)
    int const    radius,        //
    E* const     eq,            // output
    dim3 const   eq_len3,       //
    T* const     anchor,        //
    dim3 const   anchor_len3,   //
    T*           outlier,       //
    uint32_t*    outlier_idx,   //
    uint32_t*    num_outliers,  //
    float*       time_elapsed,  // optional
    cudaStream_t stream);       //

template <typename T, typename E, typename FP>
cusz_error_status decompress_predict_lorenzo_i(
    E*             eq,            // input
    dim3 const     eq_len3,       //
    T*             anchor,        //
    dim3 const     anchor_len3,   //
    T*             outlier,       //
    uint32_t*      outlier_idx,   //
    uint32_t const num_outliers,  //
    double const   eb,            // input (config)
    int const      radius,        //
    T*             xdata,         // output
    dim3 const     xdata_len3,    //
    float*         time_elapsed,  // optional
    cudaStream_t   stream);

namespace asz {
namespace experimental {

template <typename T, typename DeltaT, typename FP>
cusz_error_status compress_predict_lorenzo_ivar(
    T*           data,
    dim3 const   len3,
    double const eb,
    DeltaT*      delta,
    bool*        signum,
    float*       time_elapsed,
    cudaStream_t stream);

template <typename T, typename DeltaT, typename FP>
cusz_error_status decompress_predict_lorenzo_ivar(
    DeltaT*      delta,
    bool*        signum,
    dim3 const   len3,
    double const eb,
    T*           xdata,
    float*       time_elapsed,
    cudaStream_t stream);

}  // namespace experimental
}  // namespace asz

template <typename T, typename E, typename FP>
cusz_error_status compress_predict_lorenzo_iproto(
    T* const     data,          // input
    dim3 const   data_len3,     //
    double const eb,            // input (config)
    int const    radius,        //
    E* const     eq,            // output
    dim3 const   eq_len3,       //
    T* const     anchor,        //
    dim3 const   anchor_len3,   //
    T*           outlier,       //
    uint32_t*    outlier_idx,   //
    uint32_t*    num_outliers,  //
    float*       time_elapsed,  // optional
    cudaStream_t stream);       //

template <typename T, typename E, typename FP>
cusz_error_status decompress_predict_lorenzo_iproto(
    E*             eq,            // input
    dim3 const     eq_len3,       //
    T*             anchor,        //
    dim3 const     anchor_len3,   //
    T*             outlier,       //
    uint32_t*      outlier_idx,   //
    uint32_t const num_outliers,  //
    double const   eb,            // input (config)
    int const      radius,        //
    T*             xdata,         // output
    dim3 const     xdata_len3,    //
    float*         time_elapsed,  // optional
    cudaStream_t   stream);

#endif /* C8C37773_7EF2_439B_B0EF_14D0058DC714 */
