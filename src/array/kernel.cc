/*!
 *  Copyright (c) 2020 by Contributors
 * \file array/kernel.cc
 * \brief New kernels
 */
#include <dgl/packed_func_ext.h>
#include <dgl/base_heterograph.h>

#include "kernel_decl.h"
#include "../c_api_common.h"

using namespace dgl::runtime;

namespace dgl {
namespace aten {
namespace {

// Check whether the given arguments have the same context.
inline void CheckCtx(
    const DLContext& ctx,
    const std::vector<NDArray>& arrays,
    const std::vector<std::string>& names) {
  for (size_t i = 0; i < arrays.size(); ++i) {
    if (IsNullArray(arrays[i]))
      continue;
    CHECK_EQ(ctx, arrays[i]->ctx)
      << "Expected device context " << ctx << ". But got "
      << arrays[i]->ctx << " for " << names[i] << ".";
  }
}

// Check whether input tensors are contiguous.
inline void CheckContiguous(
    const std::vector<NDArray>& arrays,
    const std::vector<std::string>& names) {
  for (size_t i = 0; i < arrays.size(); ++i) {
    if (IsNullArray(arrays[i]))
      continue;
    CHECK(arrays[i].IsContiguous())
      << "Expect " << names[i] << " to be a contiguous tensor";
  }
}

// Check whether input tensors have valid shape.
inline void CheckShape(
    const std::vector<uint64_t>& gdim,
    const std::vector<int>& uev_idx,
    const std::vector<NDArray>& arrays,
    const std::vector<std::string>& names) {
  for (size_t i = 0; i < arrays.size(); ++i) {
    if (IsNullArray(arrays[i]))
      continue;
    CHECK_GE(arrays[i]->ndim, 2)
      << "Expect " << names[i] << " to have ndim >= 2, "
      << "Note that for scalar feature we expand its "
      << "dimension with an additional dimension of "
      << "length one.";
    CHECK_EQ(gdim[uev_idx[i]], arrays[i]->shape[0])
      << "Expect " << names[i] << " to have size "
      << gdim[uev_idx[i]] << " on the first dimension, "
      << "but got " << arrays[i]->shape[0];
  }
}

}  // namespace

/*! \brief Generalized Sparse Matrix-Matrix Multiplication. */
void SpMM(const std::string& op, const std::string& reduce,
          HeteroGraphPtr graph,
          NDArray ufeat,
          NDArray efeat,
          NDArray out,
          std::vector<NDArray> out_aux,
          SparseFormat format) {
  // TODO(zihao): format tuning
  format = SparseFormat::kCSR;
  const auto& bcast = CalcBcastOff(op, ufeat, efeat);

  ATEN_XPU_SWITCH_CUDA(graph->Context().device_type, XPU, "SpMM", {
    ATEN_ID_TYPE_SWITCH(graph->DataType(), IdType, {
      ATEN_FLOAT_TYPE_SWITCH(out->dtype, DType, "Feature data", {
        if (format == SparseFormat::kCSR) {
          SpMMCsr<XPU, IdType, DType>(
              op, reduce, bcast, graph->GetCSCMatrix(0),
              ufeat, efeat, out, out_aux);
        } else if (format == SparseFormat::kCOO) {
          SpMMCoo<XPU, IdType, DType>(
              op, reduce, bcast, graph->GetCOOMatrix(0),
              ufeat, efeat, out, out_aux);
        } else {
          LOG(FATAL) << "SpMM only supports CSR and COO foramts";
        }
      });
    });
  });
}

/*! \brief Generalized Sampled Dense-Dense Matrix Multiplication. */
void SDDMM(const std::string& op,
           HeteroGraphPtr graph,
           NDArray ufeat,
           NDArray efeat,
           NDArray out,
           SparseFormat format) {
  // TODO(zihao): format tuning
  format = SparseFormat::kCOO;
  const auto& bcast = CalcBcastOff(op, ufeat, efeat);

  ATEN_XPU_SWITCH_CUDA(graph->Context().device_type, XPU, "SDDMM", {
    ATEN_ID_TYPE_SWITCH(graph->DataType(), IdType, {
      ATEN_FLOAT_TYPE_SWITCH(out->dtype, DType, "Feature data", {
        if (format == SparseFormat::kCSR) {
          SDDMMCsr<XPU, IdType, DType>(
              op, bcast, graph->GetCSRMatrix(0),
              ufeat, efeat, out);
        } else if (format == SparseFormat::kCOO) {
          SDDMMCoo<XPU, IdType, DType>(
              op, bcast, graph->GetCOOMatrix(0),
              ufeat, efeat, out);
        } else {
          LOG(FATAL) << "SDDMM only supports CSR and COO foramts";
        }
      });
    });
  });
}

DGL_REGISTER_GLOBAL("sparse._CAPI_DGLKernelSpMM")
.set_body([] (DGLArgs args, DGLRetValue* rv) {
    HeteroGraphRef graph = args[0];
    const std::string op = args[1];
    const std::string reduce_op = args[2];
    NDArray U = args[3];
    NDArray E = args[4];
    NDArray V = args[5];
    NDArray ArgU = args[6];
    NDArray ArgE = args[7];
    CheckCtx(graph->Context(), {U, E, V, ArgU, ArgE},
        {"U_data", "E_data", "out", "Arg_U", "Arg_E"});
    CheckContiguous({U, E, V, ArgU, ArgE},
        {"U_data", "E_data", "out", "Arg_U", "Arg_E"});
    CHECK_EQ(graph->NumEdgeTypes(), 1);
    auto pair = graph->meta_graph()->FindEdge(0);  // only one etype in the graph.
    const dgl_type_t src_vtype = pair.first;
    const dgl_type_t dst_vtype = pair.second;
    CheckShape(
        {graph->NumVertices(src_vtype), graph->NumEdges(0), graph->NumVertices(dst_vtype)},
        {0, 1, 2, 2, 2},
        {U, E, V, ArgU, ArgE},
        {"U_data", "E_data", "out", "Arg_U", "Arg_E"});
    SpMM(op, reduce_op, graph.sptr(), U, E, V, {ArgU, ArgE}, SparseFormat::kAny);
  });

DGL_REGISTER_GLOBAL("sparse._CAPI_DGLKernelSDDMM")
.set_body([] (DGLArgs args, DGLRetValue* rv) {
    HeteroGraphRef graph = args[0];
    const std::string op = args[1];
    NDArray U = args[2];
    NDArray V = args[3];
    NDArray E = args[4];
    CheckCtx(graph->Context(), {U, V, E}, {"U_data", "V_data", "E_data"});
    CheckContiguous({U, V, E}, {"U_data", "V_data", "E_data"});
    CHECK_EQ(graph->NumEdgeTypes(), 1);
    auto pair = graph->meta_graph()->FindEdge(0);  // only one etype in the graph.
    const dgl_type_t src_vtype = pair.first;
    const dgl_type_t dst_vtype = pair.second;
    CheckShape(
        {graph->NumVertices(src_vtype), graph->NumEdges(0), graph->NumVertices(dst_vtype)},
        {0, 1, 2},
        {U, E, V},
        {"U_data", "E_data", "V_data"});
    SDDMM(op, graph.sptr(), U, V, E, SparseFormat::kAny);
  });

}  // namespace aten
}  // namespace dgl
