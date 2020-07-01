/*!
 *  Copyright (c) 2020 by Contributors
 * \file array/cuda/csr_sort.cc
 * \brief Sort COO index
 */
#include <dgl/array.h>
#include "../../runtime/cuda/cuda_common.h"
#include "./utils.h"

namespace dgl {

using runtime::NDArray;

namespace aten {
namespace impl {

/*!
 * \brief Check whether each row is sorted.
 */
template <typename IdType>
__global__ void _SegmentIsSorted(
    const IdType* indptr, const IdType* indices,
    int64_t num_rows, int8_t* flags) {
  int tx = blockIdx.x * blockDim.x + threadIdx.x;
  const int stride_x = gridDim.x * blockDim.x;
  while (tx < num_rows) {
    bool f = true;
    for (IdType i = indptr[tx] + 1; f && i < indptr[tx + 1]; ++i) {
      f = (indices[i - 1] <= indices[i]);
    }
    flags[tx] = static_cast<int8_t>(f);
    tx += stride_x;
  }
}

template <DLDeviceType XPU, typename IdType>
bool CSRIsSorted(CSRMatrix csr) {
  const auto& ctx = csr.indptr->ctx;
  auto* thr_entry = runtime::CUDAThreadEntry::ThreadLocal();
  auto device = runtime::DeviceAPI::Get(ctx);
  // We allocate a workspace of num_rows bytes. It wastes a little bit memory but should
  // be fine.
  int8_t* flags = static_cast<int8_t*>(device->AllocWorkspace(ctx, csr.num_rows));
  const int nt = cuda::FindNumThreads(csr.num_rows);
  const int nb = (csr.num_rows + nt - 1) / nt;
  _SegmentIsSorted<<<nb, nt, 0, thr_entry->stream>>>(
      csr.indptr.Ptr<IdType>(), csr.indices.Ptr<IdType>(),
      csr.num_rows, flags);
  bool ret = cuda::AllTrue(flags, csr.num_rows, ctx);
  device->FreeWorkspace(ctx, flags);
  return ret;
}

template bool CSRIsSorted<kDLGPU, int32_t>(CSRMatrix csr);
template bool CSRIsSorted<kDLGPU, int64_t>(CSRMatrix csr);

template <DLDeviceType XPU, typename IdType>
void CSRSort_(CSRMatrix* csr) {
  CHECK(sizeof(IdType) == 4) << "CUDA CSRSort_ does not support int64.";
  auto* thr_entry = runtime::CUDAThreadEntry::ThreadLocal();
  auto device = runtime::DeviceAPI::Get(csr->indptr->ctx);
  // allocate cusparse handle if needed
  if (!thr_entry->cusparse_handle) {
    CUSPARSE_CALL(cusparseCreate(&(thr_entry->cusparse_handle)));
  }
  CUSPARSE_CALL(cusparseSetStream(thr_entry->cusparse_handle, thr_entry->stream));

  NDArray indptr = csr->indptr;
  NDArray indices = csr->indices;
  const auto& ctx = indptr->ctx;
  const int64_t nnz = indices->shape[0];
  if (!aten::CSRHasData(*csr))
    csr->data = aten::Range(0, nnz, indices->dtype.bits, ctx);
  NDArray data = csr->data;

  size_t workspace_size = 0;
  CUSPARSE_CALL(cusparseXcsrsort_bufferSizeExt(
      thr_entry->cusparse_handle,
      csr->num_rows, csr->num_cols, nnz,
      indptr.Ptr<int32_t>(), indices.Ptr<int32_t>(),
      &workspace_size));
  void* workspace = device->AllocWorkspace(ctx, workspace_size);

  cusparseMatDescr_t descr;
  CUSPARSE_CALL(cusparseCreateMatDescr(&descr));
  CUSPARSE_CALL(cusparseSetMatType(descr, CUSPARSE_MATRIX_TYPE_GENERAL));
  CUSPARSE_CALL(cusparseSetMatIndexBase(descr, CUSPARSE_INDEX_BASE_ZERO));
  CUSPARSE_CALL(cusparseXcsrsort(
      thr_entry->cusparse_handle,
      csr->num_rows, csr->num_cols, nnz,
      descr,
      indptr.Ptr<int32_t>(), indices.Ptr<int32_t>(),
      data.Ptr<int32_t>(),
      workspace));

  csr->sorted = true;

  // free resources
  CUSPARSE_CALL(cusparseDestroyMatDescr(descr));
  device->FreeWorkspace(ctx, workspace);
}

template void CSRSort_<kDLGPU, int32_t>(CSRMatrix* csr);
template void CSRSort_<kDLGPU, int64_t>(CSRMatrix* csr);

}  // namespace impl
}  // namespace aten
}  // namespace dgl
