/*!
 *  Copyright (c) 2020 by Contributors
 * \file array/cuda/spmm.cu
 * \brief SPMM C APIs and definitions.
 */
#include <dgl/array.h>
#include "./spmm.cuh"
#include "./functor.cuh"
#include "../../runtime/cuda/cuda_common.h"

namespace dgl {

using namespace cuda;

namespace aten {
namespace {

/*! \brief Fill the vector started from ptr of size length with val */
template <typename DType>
void _Fill(DType* ptr, size_t length, DType val) {
  auto* thr_entry = runtime::CUDAThreadEntry::ThreadLocal();
  int nt = FindNumThreads(length);
  int nb = (length + nt - 1) / nt;  // on x-axis, no need to worry about upperbound.
  cuda::_FillKernel<<<nb, nt, 0, thr_entry->stream>>>(ptr, length, val);
}

}  // namespace

namespace cusparse {

template <typename DType>
cusparseStatus_t Xcsrmm2(cusparseHandle_t handle, cusparseOperation_t transA,
    cusparseOperation_t transB, int m, int n, int k, int nnz,
    const DType* alpha, const cusparseMatDescr_t descrA,
    const DType* csrValA, const int* csrRowPtrA, const int* csrColIndA,
    const DType* B, int ldb, const DType* beta, DType* C, int ldc) {
  LOG(INFO) << "Not supported dtype";
  return CUSPARSE_STATUS_EXECUTION_FAILED;
}

template <>
cusparseStatus_t Xcsrmm2<float>(cusparseHandle_t handle, cusparseOperation_t transA,
    cusparseOperation_t transB, int m, int n, int k, int nnz,
    const float* alpha, const cusparseMatDescr_t descrA,
    const float* csrValA, const int* csrRowPtrA, const int* csrColIndA,
    const float* B, int ldb, const float* beta, float* C, int ldc) {
  return cusparseScsrmm2(handle, transA, transB, m, n, k, nnz,
      alpha, descrA, csrValA, csrRowPtrA, csrColIndA,
      B, ldb, beta, C, ldc);
}

template <>
cusparseStatus_t Xcsrmm2<double>(cusparseHandle_t handle, cusparseOperation_t transA,
    cusparseOperation_t transB, int m, int n, int k, int nnz,
    const double* alpha, const cusparseMatDescr_t descrA,
    const double* csrValA, const int* csrRowPtrA, const int* csrColIndA,
    const double* B, int ldb, const double* beta, double* C, int ldc) {
  return cusparseDcsrmm2(handle, transA, transB, m, n, k, nnz,
      alpha, descrA, csrValA, csrRowPtrA, csrColIndA,
      B, ldb, beta, C, ldc);
}

template <typename DType>
cublasStatus_t Xgeam(cublasHandle_t handle, cublasOperation_t transa,
    cublasOperation_t transb, int m, int n,
    const DType* alpha, const DType* A, int lda,
    const DType* beta, const DType* B, int ldb,
    DType* C, int ldc) {
  LOG(INFO) << "Not supported dtype";
  return CUBLAS_STATUS_EXECUTION_FAILED;
}

template <>
cublasStatus_t Xgeam<float>(cublasHandle_t handle, cublasOperation_t transa,
    cublasOperation_t transb, int m, int n,
    const float* alpha, const float* A, int lda,
    const float* beta, const float* B, int ldb,
    float* C, int ldc) {
  return cublasSgeam(handle, transa, transb, m, n, alpha, A, lda,
      beta, B, ldb, C, ldc);
}

template <>
cublasStatus_t Xgeam<double>(cublasHandle_t handle, cublasOperation_t transa,
    cublasOperation_t transb, int m, int n,
    const double* alpha, const double* A, int lda,
    const double* beta, const double* B, int ldb,
    double* C, int ldc) {
  return cublasDgeam(handle, transa, transb, m, n, alpha, A, lda,
      beta, B, ldb, C, ldc);
}

/*! Cusparse implementation of SpMM on Csr format. */
template <typename DType>
void CusparseCsrmm2(
    const DLContext& ctx,
    const CSRMatrix& csr,
    const DType* B_data, const DType* A_data,
    DType* C_data,
    int x_length) {
  // We use csrmm2 to perform following operation:
  // C = A x B, where A is a sparse matrix in csr format, B is the dense matrix for node
  // feature tensor. However, since cusparse only supports column-major, while our tensor
  // is stored in row-major, the actual computation is:
  // C = trans(A x trans(B)).
  // Currently, we use cublasXgeam to implement transposition and allocate intermediate
  // workspace memory for this.
  const int m = csr.num_rows;
  const int n = x_length;
  const int k = csr.num_cols;
  const int nnz = csr.indices->shape[0];
  const DType alpha = 1.0;
  const DType beta = 0.0;
  // device
  auto device = runtime::DeviceAPI::Get(ctx);
  auto* thr_entry = runtime::CUDAThreadEntry::ThreadLocal();
  // allocate cusparse handle if needed
  if (!thr_entry->cusparse_handle) {
    CUSPARSE_CALL(cusparseCreate(&(thr_entry->cusparse_handle)));
  }
  CUSPARSE_CALL(cusparseSetStream(thr_entry->cusparse_handle, thr_entry->stream));
  // allocate matrix for temporary transposed output
  DType* trans_out = static_cast<DType*>(device->AllocWorkspace(ctx, m * n * sizeof(DType)));
  // all one data array
  DType* valptr = nullptr;
  if (!A_data) {
    valptr = static_cast<DType*>(device->AllocWorkspace(ctx, nnz * sizeof(DType)));
    _Fill(valptr, nnz, static_cast<DType>(1.));
  }
  cusparseMatDescr_t descr;
  CUSPARSE_CALL(cusparseCreateMatDescr(&descr));
  CUSPARSE_CALL(cusparseSetMatType(descr, CUSPARSE_MATRIX_TYPE_GENERAL));
  CUSPARSE_CALL(cusparseSetMatIndexBase(descr, CUSPARSE_INDEX_BASE_ZERO));
  CUSPARSE_CALL(Xcsrmm2<DType>(
      thr_entry->cusparse_handle,
      CUSPARSE_OPERATION_NON_TRANSPOSE,
      CUSPARSE_OPERATION_TRANSPOSE,
      m, n, k, nnz, &alpha,
      descr, (valptr)? valptr : A_data,
      static_cast<int32_t*>(csr.indptr->data),
      static_cast<int32_t*>(csr.indices->data),
      B_data, n, &beta, trans_out, m));
  CUSPARSE_CALL(cusparseDestroyMatDescr(descr));
  if (valptr)
    device->FreeWorkspace(ctx, valptr);
  // transpose the output matrix
  if (!thr_entry->cublas_handle)
    CUBLAS_CALL(cublasCreate(&(thr_entry->cublas_handle)));
  CUBLAS_CALL(cublasSetStream(thr_entry->cublas_handle, thr_entry->stream));
  CUBLAS_CALL(Xgeam<DType>(
      thr_entry->cublas_handle,
      CUBLAS_OP_T,
      CUBLAS_OP_N,
      n, m,
      &alpha, trans_out, m,
      &beta, nullptr, n,
      C_data, n));
  device->FreeWorkspace(ctx, trans_out);
}
}  // namespace cusparse

#define SWITCH_OP(op, Op, ...)                                      \
  do {                                                              \
    if ((op) == "add") {                                            \
      typedef cuda::binary::Add<DType> Op;                          \
      { __VA_ARGS__ }                                               \
    } else if ((op) == "sub") {                                     \
      typedef cuda::binary::Sub<DType> Op;                          \
      { __VA_ARGS__ }                                               \
    } else if ((op) == "mul") {                                     \
      typedef cuda::binary::Mul<DType> Op;                          \
      { __VA_ARGS__ }                                               \
    } else if ((op) == "div") {                                     \
      typedef cuda::binary::Div<DType> Op;                          \
      { __VA_ARGS__ }                                               \
    } else if ((op) == "copy_u") {                                  \
      typedef cuda::binary::CopyU<DType> Op;                        \
      { __VA_ARGS__ }                                               \
    } else if ((op) == "copy_e") {                                  \
      typedef cuda::binary::CopyE<DType> Op;                        \
      { __VA_ARGS__ }                                               \
    } else {                                                        \
      LOG(FATAL) << "Unsupported SpMM binary operator: " << op;     \
    }                                                               \
  } while (0)

/*!
 * \brief CUDA implementation of g-SpMM on Csr format.
 * \note use cusparse if the reduce operator is `sum` and there is
 *       no broadcast, use dgl's kernel in other cases.
 */
template <int XPU, typename IdType, typename DType>
void SpMMCsr(const std::string& op, const std::string& reduce,
             const BcastOff& bcast,
             const CSRMatrix& csr,
             NDArray ufeat,
             NDArray efeat,
             NDArray out,
             std::vector<NDArray> out_aux) {
  if (reduce == "sum") {
    if (sizeof(IdType) == 4 && op == "copy_u") {
      int64_t x_length = 1;
      for (int i = 1; i < ufeat->ndim; ++i)
        x_length *= ufeat->shape[i];
      cusparse::CusparseCsrmm2<DType>(
          ufeat->ctx, csr,
          static_cast<DType*>(ufeat->data),
          nullptr,
          static_cast<DType*>(out->data),
          x_length);
    } else if (sizeof(IdType) == 4 && op == "mul" && efeat.NumElements() == csr.indices->shape[0]) {
      int64_t x_length = 1;
      for (int i = 1; i < ufeat->ndim; ++i)
        x_length *= ufeat->shape[i];
      if (!IsNullArray(csr.data))
        efeat = IndexSelect(efeat, csr.data);
      cusparse::CusparseCsrmm2<DType>(
          ufeat->ctx, csr,
          static_cast<DType*>(ufeat->data),
          static_cast<DType*>(efeat->data),
          static_cast<DType*>(out->data),
          x_length);
    } else {
      SWITCH_OP(op, Op, {
        cuda::SpMMCsr<IdType, DType, Op, cuda::reduce::Sum<IdType, DType> >(
            bcast, csr, ufeat, efeat, out, NullArray(), NullArray());
      });
    }
  } else if (reduce == "max") {
    SWITCH_OP(op, Op, {
      cuda::SpMMCsr<IdType, DType, Op, cuda::reduce::Max<IdType, DType> >(
          bcast, csr, ufeat, efeat, out, out_aux[0], out_aux[1]);
    });
  } else if (reduce == "min") {
    SWITCH_OP(op, Op, {
      cuda::SpMMCsr<IdType, DType, Op, cuda::reduce::Min<IdType, DType> >(
          bcast, csr, ufeat, efeat, out, out_aux[0], out_aux[1]);
    });
  } else {
    LOG(FATAL) << "Not implemented";
  }
}

/*!
 * \brief CUDA implementation of g-SpMM on Coo format.
 */
template <int XPU, typename IdType, typename DType>
void SpMMCoo(const std::string& op, const std::string& reduce,
             const BcastOff& bcast,
             const COOMatrix& coo,
             NDArray ufeat,
             NDArray efeat,
             NDArray out,
             std::vector<NDArray> out_aux) {
  if (reduce == "sum") {
    SWITCH_OP(op, Op, {
      cuda::SpMMCoo<IdType, DType, Op, cuda::reduce::Sum<IdType, DType, true> > (
          bcast, coo, ufeat, efeat, out, NullArray(), NullArray());
    });
  } else if (reduce == "max") {
    SWITCH_OP(op, Op, {
      cuda::SpMMCoo<IdType, DType, Op, cuda::reduce::Max<IdType, DType, true> > (
          bcast, coo, ufeat, efeat, out, out_aux[0], out_aux[1]);
    });
  }  else if (reduce == "min") {
    SWITCH_OP(op, Op, {
      cuda::SpMMCoo<IdType, DType, Op, cuda::reduce::Min<IdType, DType, true> > (
          bcast, coo, ufeat, efeat, out, out_aux[0], out_aux[1]);
    });
  } else {
    LOG(FATAL) << "Not implemented";
  }
}

template void SpMMCsr<kDLGPU, int32_t, float>(
    const std::string& op, const std::string& reduce,
    const BcastOff& bcast, const CSRMatrix& csr,
    NDArray ufeat, NDArray efeat, NDArray out, std::vector<NDArray> out_aux);
template void SpMMCsr<kDLGPU, int64_t, float>(
    const std::string& op, const std::string& reduce,
    const BcastOff& bcast, const CSRMatrix& csr,
    NDArray ufeat, NDArray efeat, NDArray out, std::vector<NDArray> out_aux);
template void SpMMCsr<kDLGPU, int32_t, double>(
    const std::string& op, const std::string& reduce,
    const BcastOff& bcast, const CSRMatrix& csr,
    NDArray ufeat, NDArray efeat, NDArray out, std::vector<NDArray> out_aux);
template void SpMMCsr<kDLGPU, int64_t, double>(
    const std::string& op, const std::string& reduce,
    const BcastOff& bcast, const CSRMatrix& csr,
    NDArray ufeat, NDArray efeat, NDArray out, std::vector<NDArray> out_aux);

template void SpMMCoo<kDLGPU, int32_t, float>(
    const std::string& op, const std::string& reduce,
    const BcastOff& bcast, const COOMatrix& coo,
    NDArray ufeat, NDArray efeat, NDArray out, std::vector<NDArray> out_aux);
template void SpMMCoo<kDLGPU, int64_t, float>(
    const std::string& op, const std::string& reduce,
    const BcastOff& bcast, const COOMatrix& coo,
    NDArray ufeat, NDArray efeat, NDArray out, std::vector<NDArray> out_aux);
template void SpMMCoo<kDLGPU, int32_t, double>(
    const std::string& op, const std::string& reduce,
    const BcastOff& bcast, const COOMatrix& coo,
    NDArray ufeat, NDArray efeat, NDArray out, std::vector<NDArray> out_aux);
template void SpMMCoo<kDLGPU, int64_t, double>(
    const std::string& op, const std::string& reduce,
    const BcastOff& bcast, const COOMatrix& coo,
    NDArray ufeat, NDArray efeat, NDArray out, std::vector<NDArray> out_aux);

}  // namespace aten
}  // namespace dgl
