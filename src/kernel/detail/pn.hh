/**
 * @file pn.hh
 * @author Jiannan Tian
 * @brief
 * @version 0.4
 * @date 2023-01-05
 *
 * (C) 2023 by Indiana University, Argonne National Laboratory
 *
 */

#include <stdint.h>
#include <stdlib.h>

namespace parsz {
namespace typing {

// clang-format off
template <int BYTEWIDTH> struct Int;
template <> struct Int<1> { typedef int8_t  T; }; 
template <> struct Int<2> { typedef int16_t T; }; 
template <> struct Int<4> { typedef int32_t T; }; 
template <> struct Int<8> { typedef int64_t T; };

template <int BYTEWIDTH> struct UInt;
template <> struct UInt<1> { typedef uint8_t  T; }; 
template <> struct UInt<2> { typedef uint16_t T; }; 
template <> struct UInt<4> { typedef uint32_t T; }; 
template <> struct UInt<8> { typedef uint64_t T; };
// clang-format on

}  // namespace typing
}  // namespace parsz

// TODO forward definition in another file
template <int BYTEWIDTH>
struct PN {
    using UI = typename parsz::typing::UInt<BYTEWIDTH>::T;
    using I  = typename parsz::typing::Int<BYTEWIDTH>::T;

    // reference: https://lemire.me/blog/2022/11/25/making-all-your-integers-positive-with-zigzag-encoding/

    static UI encode(I* x) { return (2 * (*x)) ^ ((*x) >> (BYTEWIDTH * 8 - 1)); }
    static UI encode(I x) { return (2 * x) ^ (x >> (BYTEWIDTH * 8 - 1)); }
    static I  decode(UI* x) { return ((*x) >> 1) ^ (-((*x) & 1)); }
    static I  decode(UI x) { return (x >> 1) ^ (-(x & 1)); }
};
