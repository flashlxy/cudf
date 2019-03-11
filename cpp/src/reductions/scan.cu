#include "cudf.h"
#include "rmm/rmm.h"
#include "utilities/cudf_utils.h"
#include "utilities/error_utils.hpp"
#include "bitmask/bit_mask.cuh"
#include "utilities/type_dispatcher.hpp"

#include <cub/device/device_scan.cuh>

#include "reduction_operators.cuh"

namespace { //anonymous

#define COPYMASK_BLOCK_SIZE 1024

    template <class T>
    __global__
        void gpu_copy_and_replace_nulls(
            const T *data, const gdf_valid_type *mask,
            gdf_size_type size, T *results, T identity)
    {
        gdf_size_type id = threadIdx.x + blockIdx.x * blockDim.x;

        while (id < size) {
            results[id] = (gdf_is_valid(mask, id)) ? data[id] : identity;
            id += blockDim.x * gridDim.x;
        }
    }

/* --------------------------------------------------------------------------*/
/**
 * @brief Copy data stream and replace nulls by a scholar value
 *
 * @Param[in] data The stream to be copied
 * @Param[in] mask The bitmask stream for nulls
 * @Param[in] size The element count of stream
 * @Param[out] results The stream for the result
 * @Param[in] identity The scholar value to be used to replace nulls
 * @Param[in] stream The cuda stream to be used
 *
 * @Returns  If the operation was successful, returns GDF_SUCCESS
 */
/* ----------------------------------------------------------------------------*/
    template <typename T>
    inline
        gdf_error copy_and_replace_nulls(
            const T *data, const gdf_valid_type *mask,
            gdf_size_type size, T *results, T identity, cudaStream_t stream)
    {
        int blocksize = (size < COPYMASK_BLOCK_SIZE ?
            size : COPYMASK_BLOCK_SIZE);
        int gridsize = (size + COPYMASK_BLOCK_SIZE - 1) /
            COPYMASK_BLOCK_SIZE;

        // launch kernel
        gpu_copy_and_replace_nulls << <gridsize, blocksize, 0, stream >> > (
            data, mask, size, results, identity);

        CUDA_CHECK_LAST();
        return GDF_SUCCESS;
    }

    template <typename T, typename Op>
    struct Scan {
        static
        gdf_error call(const gdf_column *input, gdf_column *output,
            bool inclusive, cudaStream_t stream)
        {
            gdf_error ret;
            auto scan_function = (inclusive ? inclusive_scan : exclusive_scan);
            size_t size = input->size;
            const T* d_input = static_cast<const T*>(input->data);
            T* d_output = static_cast<T*>(output->data);

            // Prepare temp storage
            void *temp_storage = NULL;
            size_t temp_storage_bytes = 0;
            GDF_REQUIRE(GDF_SUCCESS == (ret = scan_function(temp_storage,
                temp_storage_bytes, d_input, d_output, size, stream)), ret);
            RMM_TRY(RMM_ALLOC(&temp_storage, temp_storage_bytes, stream));

            if( nullptr != input->valid ){
                // copy null bitmask
                size_t valid_byte_length = gdf_get_num_chars_bitmask(size);
                CUDA_TRY(cudaMemcpyAsync(output->valid, input->valid,
                        valid_byte_length, cudaMemcpyDeviceToDevice, stream));
                output->null_count = input->null_count;
            }

            bool const input_has_nulls{ nullptr != input->valid &&
                                        input->null_count > 0 };
            if (input_has_nulls) {
                // allocate temporary column data
                T* temp_input;
                RMM_TRY(RMM_ALLOC(&temp_input, size * sizeof(T), stream));

                T identity = Op::template identity<T>();
                // copy d_input data and replace with 0 if mask is null
                copy_and_replace_nulls(
                    static_cast<const T*>(input->data), input->valid,
                    size, temp_input, identity, stream);

                // Do scan
                ret = scan_function(temp_storage, temp_storage_bytes,
                    temp_input, d_output, size, stream);
                GDF_REQUIRE(GDF_SUCCESS == ret, ret);

                RMM_TRY(RMM_FREE(temp_input, stream));
            }
            else {  // Do scan
                ret = scan_function(temp_storage, temp_storage_bytes,
                    d_input, d_output, size, stream);
                GDF_REQUIRE(GDF_SUCCESS == ret, ret);
            }

            // Cleanup
            RMM_TRY(RMM_FREE(temp_storage, stream));

            return GDF_SUCCESS;
        }

        static
        gdf_error exclusive_scan(void *&temp_storage, size_t &temp_storage_bytes,
            const T *input, T *output, size_t size, cudaStream_t stream)
        {
            Op op;
            T identity = Op::template identity<T>(); // value for output[0]
            cub::DeviceScan::ExclusiveScan(temp_storage, temp_storage_bytes,
                input, output, op, identity, size, stream);
            CUDA_CHECK_LAST();
            return GDF_SUCCESS;
        }

        static
        gdf_error inclusive_scan(void *&temp_storage, size_t &temp_storage_bytes,
            const T *input, T *output, size_t size, cudaStream_t stream)
        {
            Op op;
            cub::DeviceScan::InclusiveScan(temp_storage, temp_storage_bytes,
                input, output, op, size, stream);
            CUDA_CHECK_LAST();
            return GDF_SUCCESS;
        }
    };

    template <typename Op>
    struct PrefixSumDispatcher {
        template <typename T,
            typename std::enable_if_t<std::is_arithmetic<T>::value>* = nullptr>
        gdf_error operator()(const gdf_column *input, gdf_column *output,
            bool inclusive, cudaStream_t stream = 0)
        {
            GDF_REQUIRE(input->size == output->size, GDF_COLUMN_SIZE_MISMATCH);
            GDF_REQUIRE(input->dtype == output->dtype, GDF_DTYPE_MISMATCH);

            if (nullptr == input->valid) {
                GDF_REQUIRE(0 == input->null_count, GDF_VALIDITY_MISSING);
                GDF_REQUIRE(nullptr == output->valid, GDF_VALIDITY_UNSUPPORTED);
            }
            else {
                GDF_REQUIRE(nullptr != input->valid && nullptr != output->valid,
                            GDF_VALIDITY_MISSING);
            }
            return Scan<T, Op>::call(input, output, inclusive, stream);
        }

        template <typename T,
            typename std::enable_if_t<!std::is_arithmetic<T>::value, T>* = nullptr>
            gdf_error operator()(const gdf_column *input, gdf_column *output,
                bool inclusive, cudaStream_t stream = 0) {
            return GDF_UNSUPPORTED_DTYPE;
        }
    };

} // end anonymous namespace


gdf_error gdf_scan(const gdf_column *input, gdf_column *output,
    gdf_scan_op op, bool inclusive)
{
    using namespace cudf::reduction;

    switch(op){
    case GDF_SCAN_SUM:
        return cudf::type_dispatcher(input->dtype,
            PrefixSumDispatcher<DeviceSum>(), input, output, inclusive);
    case GDF_SCAN_MIN:
        return cudf::type_dispatcher(input->dtype,
            PrefixSumDispatcher<DeviceMin>(), input, output, inclusive);
    case GDF_SCAN_MAX:
        return cudf::type_dispatcher(input->dtype,
            PrefixSumDispatcher<DeviceMax>(), input, output, inclusive);
    case GDF_SCAN_PRODUCTION:
        return cudf::type_dispatcher(input->dtype,
            PrefixSumDispatcher<DeviceProduct>(), input, output, inclusive);
    default:
        return GDF_INVALID_API_CALL;
    }
}

