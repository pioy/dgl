/*!
 *  Copyright (c) 2020 by Contributors
 * \file array/cuda/spmat_op_impl.cu
 * \brief Sparse matrix operator CPU implementation
 */
#include <dgl/array.h>
#include <vector>
#include <unordered_set>
#include <numeric>
#include "../../runtime/cuda/cuda_common.h"
#include "./utils.h"

namespace dgl {

using runtime::NDArray;

namespace aten {
namespace impl {

/*!
 * \brief Search adjacency list linearly for each (row, col) pair and
 * write the matched position in the indices array to the output.
 * 
 * If there is no match, -1 is written.
 * If there are multiple matches, only the first match is written.
 */
template <typename IdType>
__global__ void _LinearSearchKernel(
    const IdType* indptr, const IdType* indices,
    const IdType* row, const IdType* col,
    int64_t row_stride, int64_t col_stride,
    int64_t length, IdType* out) {
  int tx = blockIdx.x * blockDim.x + threadIdx.x;
  const int stride_x = gridDim.x * blockDim.x;
  int rpos = tx, cpos = tx;
  while (tx < length) {
    out[tx] = -1;
    const IdType r = row[rpos], c = col[cpos];
    for (IdType i = indptr[r]; i < indptr[r + 1]; ++i) {
      if (indices[i] == c) {
        out[tx] = i;
        break;
      }
    }
    rpos += row_stride;
    cpos += col_stride;
    tx += stride_x;
  }
}

///////////////////////////// CSRIsNonZero /////////////////////////////

template <DLDeviceType XPU, typename IdType>
bool CSRIsNonZero(CSRMatrix csr, int64_t row, int64_t col) {
  auto* thr_entry = runtime::CUDAThreadEntry::ThreadLocal();
  const auto& ctx = csr.indptr->ctx;
  IdArray rows = aten::VecToIdArray<int64_t>({row}, sizeof(IdType) * 8, ctx);
  IdArray cols = aten::VecToIdArray<int64_t>({col}, sizeof(IdType) * 8, ctx);
  rows = rows.CopyTo(ctx);
  cols = cols.CopyTo(ctx);
  IdArray out = aten::NewIdArray(1, ctx, sizeof(IdType) * 8);
  // TODO(minjie): use binary search for sorted csr
  _LinearSearchKernel<<<1, 1, 0, thr_entry->stream>>>(
      csr.indptr.Ptr<IdType>(), csr.indices.Ptr<IdType>(),
      rows.Ptr<IdType>(), cols.Ptr<IdType>(),
      1, 1, 1,
      out.Ptr<IdType>());
  out = out.CopyTo(DLContext{kDLCPU, 0});
  return *out.Ptr<IdType>() != -1;
}

template bool CSRIsNonZero<kDLGPU, int32_t>(CSRMatrix, int64_t, int64_t);
template bool CSRIsNonZero<kDLGPU, int64_t>(CSRMatrix, int64_t, int64_t);

template <DLDeviceType XPU, typename IdType>
NDArray CSRIsNonZero(CSRMatrix csr, NDArray row, NDArray col) {
  const auto rowlen = row->shape[0];
  const auto collen = col->shape[0];
  const auto rstlen = std::max(rowlen, collen);
  NDArray rst = NDArray::Empty({rstlen}, row->dtype, row->ctx);
  if (rstlen == 0)
    return rst;
  const int64_t row_stride = (rowlen == 1 && collen != 1) ? 0 : 1;
  const int64_t col_stride = (collen == 1 && rowlen != 1) ? 0 : 1;
  auto* thr_entry = runtime::CUDAThreadEntry::ThreadLocal();
  const int nt = cuda::FindNumThreads(rstlen);
  const int nb = (rstlen + nt - 1) / nt;
  // TODO(minjie): use binary search for sorted csr
  _LinearSearchKernel<<<nb, nt, 0, thr_entry->stream>>>(
      csr.indptr.Ptr<IdType>(), csr.indices.Ptr<IdType>(),
      row.Ptr<IdType>(), col.Ptr<IdType>(),
      row_stride, col_stride, rstlen,
      rst.Ptr<IdType>());
  return rst != -1;
}

template NDArray CSRIsNonZero<kDLGPU, int32_t>(CSRMatrix, NDArray, NDArray);
template NDArray CSRIsNonZero<kDLGPU, int64_t>(CSRMatrix, NDArray, NDArray);

///////////////////////////// CSRGetRowNNZ /////////////////////////////

template <DLDeviceType XPU, typename IdType>
int64_t CSRGetRowNNZ(CSRMatrix csr, int64_t row) {
  const IdType cur = aten::IndexSelect<IdType>(csr.indptr, row);
  const IdType next = aten::IndexSelect<IdType>(csr.indptr, row + 1);
  return next - cur;
}

template int64_t CSRGetRowNNZ<kDLGPU, int32_t>(CSRMatrix, int64_t);
template int64_t CSRGetRowNNZ<kDLGPU, int64_t>(CSRMatrix, int64_t);

template <typename IdType>
__global__ void _CSRGetRowNNZKernel(
    const IdType* vid,
    const IdType* indptr,
    IdType* out,
    int64_t length) {
  int tx = blockIdx.x * blockDim.x + threadIdx.x;
  int stride_x = gridDim.x * blockDim.x;
  while (tx < length) {
    const IdType vv = vid[tx];
    out[tx] = indptr[vv + 1] - indptr[vv];
    tx += stride_x;
  }
}

template <DLDeviceType XPU, typename IdType>
NDArray CSRGetRowNNZ(CSRMatrix csr, NDArray rows) {
  auto* thr_entry = runtime::CUDAThreadEntry::ThreadLocal();
  const auto len = rows->shape[0];
  const IdType* vid_data = static_cast<IdType*>(rows->data);
  const IdType* indptr_data = static_cast<IdType*>(csr.indptr->data);
  NDArray rst = NDArray::Empty({len}, rows->dtype, rows->ctx);
  IdType* rst_data = static_cast<IdType*>(rst->data);
  const int nt = cuda::FindNumThreads(len);
  const int nb = (len + nt - 1) / nt;
  _CSRGetRowNNZKernel<<<nb, nt, 0, thr_entry->stream>>>(
      vid_data, indptr_data, rst_data, len);
  return rst;
}

template NDArray CSRGetRowNNZ<kDLGPU, int32_t>(CSRMatrix, NDArray);
template NDArray CSRGetRowNNZ<kDLGPU, int64_t>(CSRMatrix, NDArray);

///////////////////////////// CSRGetRowColumnIndices /////////////////////////////

template <DLDeviceType XPU, typename IdType>
NDArray CSRGetRowColumnIndices(CSRMatrix csr, int64_t row) {
  const int64_t len = impl::CSRGetRowNNZ<XPU, IdType>(csr, row);
  const int64_t offset = aten::IndexSelect<IdType>(csr.indptr, row) * sizeof(IdType);
  return csr.indices.CreateView({len}, csr.indices->dtype, offset);
}

template NDArray CSRGetRowColumnIndices<kDLGPU, int32_t>(CSRMatrix, int64_t);
template NDArray CSRGetRowColumnIndices<kDLGPU, int64_t>(CSRMatrix, int64_t);

///////////////////////////// CSRGetRowData /////////////////////////////

template <DLDeviceType XPU, typename IdType>
NDArray CSRGetRowData(CSRMatrix csr, int64_t row) {
  const int64_t len = impl::CSRGetRowNNZ<XPU, IdType>(csr, row);
  const int64_t offset = aten::IndexSelect<IdType>(csr.indptr, row) * sizeof(IdType);
  if (aten::CSRHasData(csr))
    return csr.data.CreateView({len}, csr.data->dtype, offset);
  else
    return aten::Range(offset, offset + len, csr.indptr->dtype.bits, csr.indptr->ctx);
}

template NDArray CSRGetRowData<kDLGPU, int32_t>(CSRMatrix, int64_t);
template NDArray CSRGetRowData<kDLGPU, int64_t>(CSRMatrix, int64_t);

///////////////////////////// CSRSliceRows /////////////////////////////

template <DLDeviceType XPU, typename IdType>
CSRMatrix CSRSliceRows(CSRMatrix csr, int64_t start, int64_t end) {
  const int64_t num_rows = end - start;
  const IdType st_pos = aten::IndexSelect<IdType>(csr.indptr, start);
  const IdType ed_pos = aten::IndexSelect<IdType>(csr.indptr, end);
  const IdType nnz = ed_pos - st_pos;
  IdArray ret_indptr = aten::IndexSelect(csr.indptr, start, end + 1) - st_pos;
  // indices and data can be view arrays
  IdArray ret_indices = csr.indices.CreateView(
      {nnz}, csr.indices->dtype, st_pos * sizeof(IdType));
  IdArray ret_data;
  if (CSRHasData(csr))
    ret_data = csr.data.CreateView({nnz}, csr.data->dtype, st_pos * sizeof(IdType));
  else
    ret_data = aten::Range(st_pos, ed_pos,
                           csr.indptr->dtype.bits, csr.indptr->ctx);
  return CSRMatrix(num_rows, csr.num_cols,
                   ret_indptr, ret_indices, ret_data,
                   csr.sorted);
}

template CSRMatrix CSRSliceRows<kDLGPU, int32_t>(CSRMatrix, int64_t, int64_t);
template CSRMatrix CSRSliceRows<kDLGPU, int64_t>(CSRMatrix, int64_t, int64_t);

/*!
 * \brief Copy data segment to output buffers
 * 
 * For the i^th row r = row[i], copy the data from indptr[r] ~ indptr[r+1]
 * to the out_data from out_indptr[i] ~ out_indptr[i+1]
 *
 * If the provided `data` array is nullptr, write the read index to the out_data.
 *
 */
template <typename IdType, typename DType>
__global__ void _SegmentCopyKernel(
    const IdType* indptr, const DType* data,
    const IdType* row, int64_t row_stride, int64_t length,
    const IdType* out_indptr, DType* out_data) {
  int tx = blockIdx.x * blockDim.x + threadIdx.x;
  const int stride_x = gridDim.x * blockDim.x;
  int rpos = tx;
  while (tx < length) {
    const IdType r = row[rpos];
    DType* out_buf = out_data + out_indptr[tx];
    for (IdType i = indptr[r]; i < indptr[r + 1]; ++i) {
      *(out_buf++) = data? data[i] : i;
    }
    rpos += row_stride;
    tx += stride_x;
  }
}

template <DLDeviceType XPU, typename IdType>
CSRMatrix CSRSliceRows(CSRMatrix csr, NDArray rows) {
  auto* thr_entry = runtime::CUDAThreadEntry::ThreadLocal();
  const int64_t len = rows->shape[0];
  IdArray ret_indptr = aten::CumSum(aten::CSRGetRowNNZ(csr, rows), true);
  const int64_t nnz = aten::IndexSelect<IdType>(ret_indptr, len);

  const int nt = cuda::FindNumThreads(len);
  const int nb = (len + nt - 1) / nt;
  // Copy indices.
  IdArray ret_indices = NDArray::Empty({nnz}, csr.indptr->dtype, csr.indptr->ctx);
  _SegmentCopyKernel<<<nb, nt, 0, thr_entry->stream>>>(
      csr.indptr.Ptr<IdType>(), csr.indices.Ptr<IdType>(),
      rows.Ptr<IdType>(), 1, len,
      ret_indptr.Ptr<IdType>(), ret_indices.Ptr<IdType>());
  // Copy data.
  IdArray ret_data = NDArray::Empty({nnz}, csr.indptr->dtype, csr.indptr->ctx);
  _SegmentCopyKernel<<<nb, nt, 0, thr_entry->stream>>>(
      csr.indptr.Ptr<IdType>(), CSRHasData(csr)? csr.data.Ptr<IdType>() : nullptr,
      rows.Ptr<IdType>(), 1, len,
      ret_indptr.Ptr<IdType>(), ret_data.Ptr<IdType>());
  return CSRMatrix(len, csr.num_cols,
                   ret_indptr, ret_indices, ret_data,
                   csr.sorted);
}

template CSRMatrix CSRSliceRows<kDLGPU, int32_t>(CSRMatrix , NDArray);
template CSRMatrix CSRSliceRows<kDLGPU, int64_t>(CSRMatrix , NDArray);

}  // namespace impl
}  // namespace aten
}  // namespace dgl
