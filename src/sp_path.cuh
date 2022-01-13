/**
 * @file sp_path.cuh
 * @author Jiannan Tian
 * @brief
 * @version 0.3
 * @date 2021-09-29
 * meged file created on 2021-06-06
 *
 * (C) 2021 by Washington State University, Argonne National Laboratory
 *
 */

#ifndef CUSZ_SP_PATH_CUH
#define CUSZ_SP_PATH_CUH

#include "base_cusz.cuh"
#include "binding.hh"
#include "header.hh"
#include "wrapper.hh"

template <class BINDING, int SP_FACTOR = 10>
class SpPathCompressor : public BaseCompressor<typename BINDING::PREDICTOR> {
    using Predictor = typename BINDING::PREDICTOR;
    using SpReducer = typename BINDING::SPREDUCER;

    using T    = typename Predictor::Origin;   // wrong in type inference
    using E    = typename Predictor::ErrCtrl;  // wrong in type inference
    using BYTE = uint8_t;                      // non-interpreted type; bytestream

    unsigned int len;
    dim3         data_size;

    Predictor* predictor;
    SpReducer* spreducer;

    BYTE* d_reserved_compressed{nullptr};

   public:
    struct header_t {
        static const int HEADER = 0;
        static const int ANCHOR = 1;
        static const int SPFMT  = 2;
        static const int END    = 3;

        int      header_nbyte : 16;
        uint32_t entry[END + 1];

        uint32_t file_size() const { return entry[END]; }
    };
    using HEADER = struct header_t;

   public:
    uint32_t get_data_len() { return data_size.x * data_size.y * data_size.z; }
    uint32_t get_anchor_len() { return predictor->get_anchor_len(); }

   private:
   public:
    SpPathCompressor() = default;

    /**
     * @brief Given the input data size, determine the internal memory footprint and allocate accordingly.
     *
     * @param xyz 3D unsigned integer
     */
    void allocate_workspace(dim3 xyz)
    {
        predictor = new Predictor;
        spreducer = new SpReducer;

        data_size = xyz;

        (*predictor).allocate_workspace(xyz);

        // cout << "predictor data len\t" << (*predictor).get_data_len() << endl;

        // TODO encapsulate more
        auto spreducer_in_len = (*predictor).get_quant_footprint();

        (*spreducer).allocate_workspace(spreducer_in_len);

        CHECK_CUDA(cudaMalloc(&d_reserved_compressed, (*predictor).get_data_len() * sizeof(T) / 2));
    }

    /**
     * @brief
     *
     * @param uncompressed device pointer, uncompressed input
     * @param eb host variable, error bound
     * @param radius host variable, in many cases, it is 0
     * @param compressed device pointer, modified inside the method, output cusz archive binary
     * @param compressed_len host variable, modified inside the method, output compressed length
     * @param stream CUDA stream
     */
    void compress(
        T*           uncompressed,
        double const eb,
        int const    radius,
        BYTE*&       compressed,
        size_t&      compressed_len,
        cudaStream_t stream = nullptr)
    {
        T*     d_anchor{nullptr};
        E*     d_errctrl{nullptr};
        BYTE*  d_spreducer_out{nullptr};
        size_t spreducer_out_len{0};

        HEADER header;

        auto subfile_collect = [&]() {
            header.header_nbyte = sizeof(HEADER);

            uint32_t nbyte[HEADER::END];
            nbyte[HEADER::HEADER] = 128;
            nbyte[HEADER::ANCHOR] = sizeof(T) * (*predictor).get_anchor_len();
            nbyte[HEADER::SPFMT]  = sizeof(BYTE) * spreducer_out_len;

            header.entry[0] = 0;
            // *.END + 1; need to know the ending position
            for (auto i = 1; i < HEADER::END + 1; i++) { header.entry[i] = nbyte[i - 1]; }
            for (auto i = 1; i < HEADER::END + 1; i++) { header.entry[i] += header.entry[i - 1]; }

            auto debug_header_entry = [&]() {
                printf("\nsubfile collect in compressor:\n");
                for (auto i = 0; i < HEADER::END + 1; i++) printf("%d, header entry: %d\n", i, header.entry[i]);
            };
            debug_header_entry();

            CHECK_CUDA(cudaMemcpyAsync(d_reserved_compressed, &header, sizeof(header), cudaMemcpyHostToDevice, stream));

#define D2D_CPY(VAR, FIELD)                                                                            \
    {                                                                                                  \
        auto dst = d_reserved_compressed + header.entry[HEADER::FIELD];                                \
        auto src = reinterpret_cast<BYTE*>(d_##VAR);                                                   \
        CHECK_CUDA(cudaMemcpyAsync(dst, src, nbyte[HEADER::FIELD], cudaMemcpyDeviceToDevice, stream)); \
    }
            D2D_CPY(anchor, ANCHOR)
            D2D_CPY(spreducer_out, SPFMT)
#undef D2D_CPY

            /* debug */ CHECK_CUDA(cudaStreamSynchronize(stream));
        };

        (*predictor).construct(uncompressed, eb, radius, d_anchor, d_errctrl, stream);

        auto spreducer_in_len = (*predictor).get_quant_footprint();

        (*spreducer).gather_new(d_errctrl, spreducer_in_len, d_spreducer_out, spreducer_out_len, stream);

        /* debug */ CHECK_CUDA(cudaStreamSynchronize(stream));

        subfile_collect();
        compressed_len = header.file_size();

        cout << "(c) predictor time: " << predictor->get_time_elapsed() << " ms\n";
        cout << "(c) spreducer time: " << spreducer->get_time_elapsed() << " ms\n";
    }

    /**
     * @brief High-level decompress method for this compressor
     *
     * @param in_compressed device pointer, the cusz archive bianry
     * @param eb host variable, error bound
     * @param radius host variable, in this case, it is 0
     * @param out_decompressed device pointer, output decompressed data
     * @param stream CUDA stream
     */
    void decompress(BYTE* in_compressed, double const eb, int const radius, T* out_decompressed, cudaStream_t stream)
    {
        auto prev_ms = (*spreducer).get_time_elapsed();

        HEADER header;
        CHECK_CUDA(cudaMemcpyAsync(&header, in_compressed, sizeof(header), cudaMemcpyDeviceToHost, stream));
        CHECK_CUDA(cudaStreamSynchronize(stream));

#define ACCESSOR(SYM, TYPE) reinterpret_cast<TYPE*>(in_compressed + header.entry[HEADER::SYM])
        auto d_anchor       = ACCESSOR(ANCHOR, T);
        auto d_spreducer_in = ACCESSOR(SPFMT, BYTE);
#undef ACCESSOR

        auto d_errctrl = (*predictor).expose_quant();  // reuse

        (*spreducer).scatter_new(d_spreducer_in, d_errctrl, stream);
        (*predictor).reconstruct(d_anchor, d_errctrl, eb, radius, out_decompressed, stream);

        // TODO timer
        cout << "(x) spreducer time: " << spreducer->get_time_elapsed() - prev_ms << " ms\n";
        cout << "(x) predictor time: " << predictor->get_time_elapsed() << " ms\n";
    }

    ~SpPathCompressor()
    {
        delete predictor;
        delete spreducer;
    }
};

struct SparsityAwarePath {
   private:
    using DATA    = DataTrait<4>::type;
    using ERRCTRL = ErrCtrlTrait<4, true>::type;
    using FP      = FastLowPrecisionTrait<true>::type;

   public:
    using DefaultBinding = PredictorReducerBinding<  //
        cusz::Spline3<DATA, ERRCTRL, FP>,
        cusz::CSR11<ERRCTRL>>;

    using DefaultCompressor = class SpPathCompressor<DefaultBinding, 10>;

    using FallbackBinding = PredictorReducerBinding<  //
        cusz::PredictorLorenzo<DATA, ERRCTRL, FP>,
        cusz::CSR11<ERRCTRL>>;

    using FallbackCompressor = class SpPathCompressor<FallbackBinding, 10>;
};

#endif