#include <curand.h>
#include <curand_kernel.h>

#include <algorithm>
#include <cassert>
#include <chrono>
#include <cstdio>
#include <cub/cub.cuh>

#include "../common.h"
#include "../constant.h"
#include "../device.h"
#include "../logging.h"
#include "../profiler.h"
#include "../timer.h"
#include "cuda_function.h"

namespace samgraph {
namespace common {
namespace cuda {

namespace {

__global__ void sample_khop1(const IdType *indptr, const IdType *indices,
                             const IdType *input, const size_t num_input,
                             const size_t fanout, IdType *tmp_src,
                             IdType *tmp_dst, curandState *random_states,
                             size_t num_random_states) {
  size_t num_task = num_input * fanout;
  size_t threadId = threadIdx.x + blockDim.x * blockIdx.x;
  size_t task_span = blockDim.x * gridDim.x;

  assert(threadId < num_random_states);
  // cache the curand state
  curandState local_state = random_states[threadId];

  for (size_t task_idx = threadId; task_idx < num_task; task_idx += task_span) {
    const IdType rid = input[task_idx / fanout];
    const IdType off = indptr[rid];
    const IdType len = indptr[rid + 1] - indptr[rid];

    size_t k = curand(&local_state) % len;
    tmp_src[task_idx] = rid;
    tmp_dst[task_idx] = indices[off + k];
  }
  // restore the state
  random_states[threadId] = local_state;
}

__global__ void count_edge(IdType *src, IdType *dst, size_t *item_prefix,
                           size_t num_task) {
  size_t threadId = threadIdx.x + blockDim.x * blockIdx.x;
  size_t task_span = blockDim.x * gridDim.x;

  for (size_t task_idx = threadId; task_idx < num_task; task_idx += task_span) {
    if (task_idx == 0) {
      item_prefix[0] = 0;
    } else {
      if (src[task_idx] == src[task_idx - 1] &&
          dst[task_idx] == dst[task_idx - 1]) {
        item_prefix[task_idx] = 0;
      } else {
        item_prefix[task_idx] = 1;
      }
    }
  }
}

__global__ void compact_edge(IdType *tmp_src, IdType *tmp_dst, IdType *out_src,
                             IdType *out_dst, size_t *item_prefix,
                             size_t num_task, size_t *num_out) {
  size_t threadId = threadIdx.x + blockDim.x * blockIdx.x;
  size_t task_span = blockDim.x * gridDim.x;

  for (size_t task_idx = threadId; task_idx < num_task; task_idx += task_span) {
    out_src[item_prefix[task_idx]] = tmp_src[task_idx];
    out_dst[item_prefix[task_idx]] = tmp_dst[task_idx];
  }

  if (threadId == 0) {
    *num_out = item_prefix[num_task - 1];
  }
}

}  // namespace

/**
 * @brief sampling algorithm from nextdoor
 * CSR format example:
        ROW_INDEX = [  0  2  4  7  8  ]
        COL_INDEX = [  0  1  1  3  2  3  4  5  ]
        V         = [ 10 20 30 40 50 60 70 80  ]
 * @param indptr         ROW_INDEX, sampling vertices
 * @param indices        COL_INDEX, neighbors
 * @param input          the indices of sampling vertices
 * @param num_input      the number of sampling vertices
 * @param fanout         the number of neighbors for each sampling vertex
 * @param out_src        src vertices of all neighbors
 * @param out_dst        dst vertices of all neighbors
 * @param num_out        the number of all neighbors
 * @param ctx            GPU context
 * @param stream         GPU stream
 * @param random_states  GPU random seeds
 * @param task_key       for profiler data
 */
void GPUSampleKHop1(const IdType *indptr, const IdType *indices,
                    const IdType *input, const size_t num_input,
                    const size_t fanout, IdType *out_src, IdType *out_dst,
                    size_t *num_out, Context ctx, StreamHandle stream,
                    GPURandomStates *random_states, uint64_t task_key) {
  LOG(DEBUG) << "GPUSample: begin with num_input " << num_input
             << " and fanout " << fanout;
  Timer t0;

  auto sampler_device = Device::Get(ctx);
  auto cu_stream = static_cast<cudaStream_t>(stream);

  IdType *tmp_src = static_cast<IdType *>(
      sampler_device->AllocWorkspace(ctx, sizeof(IdType) * num_input * fanout));
  IdType *tmp_dst = static_cast<IdType *>(
      sampler_device->AllocWorkspace(ctx, sizeof(IdType) * num_input * fanout));
  LOG(DEBUG) << "GPUSample: cuda tmp_src malloc "
             << ToReadableSize(num_input * fanout * sizeof(IdType));
  LOG(DEBUG) << "GPUSample: cuda tmp_dst malloc "
             << ToReadableSize(num_input * fanout * sizeof(IdType));

  size_t num_threads = Min(num_input * fanout, Constant::kKHop1MaxThreads);
  const dim3 grid(
      RoundUpDiv(num_threads, static_cast<size_t>(Constant::kCudaBlockSize)));
  const dim3 block(Constant::kCudaBlockSize);
  sample_khop1<<<grid, block, 0, cu_stream>>>(
      indptr, indices, input, num_input, fanout, tmp_src, tmp_dst,
      random_states->GetStates(), random_states->NumStates());
  sampler_device->StreamSync(ctx, stream);

  double sample_time = t0.Passed();
  LOG(DEBUG) << "GPUSample: kernel sampling, time cost: " << sample_time;

  // sort coo
  Timer t1;
  size_t temp_storage_bytes = 0;
  CUDA_CALL(cub::DeviceRadixSort::SortPairs(
      nullptr, temp_storage_bytes, tmp_src, tmp_src, tmp_dst, tmp_dst,
      num_input * fanout, 0, sizeof(IdType) * 8, cu_stream));
  sampler_device->StreamSync(ctx, stream);

  void *d_temp_storage =
      sampler_device->AllocWorkspace(ctx, temp_storage_bytes);
  CUDA_CALL(cub::DeviceRadixSort::SortPairs(
      d_temp_storage, temp_storage_bytes, tmp_src, tmp_src, tmp_dst, tmp_dst,
      num_input * fanout, 0, sizeof(IdType) * 8, cu_stream));
  sampler_device->StreamSync(ctx, stream);
  sampler_device->FreeWorkspace(ctx, d_temp_storage);
  double sort_coo_time = t1.Passed();
  LOG(DEBUG) << "GPUSample: sort the temporary results, time cost: "
             << sort_coo_time;

  // count the prefix num
  Timer t2;
  size_t *item_prefix = static_cast<size_t *>(
      sampler_device->AllocWorkspace(ctx, sizeof(size_t) * num_input * fanout));
  LOG(DEBUG) << "GPUSample: cuda prefix_num malloc "
             << ToReadableSize(sizeof(int) * num_input * fanout);
  count_edge<<<grid, block, 0, cu_stream>>>(tmp_src, tmp_dst, item_prefix,
                                            num_input * fanout);
  sampler_device->StreamSync(ctx, stream);

  temp_storage_bytes = 0;
  CUDA_CALL(cub::DeviceScan::ExclusiveSum(nullptr, temp_storage_bytes,
                                          item_prefix, item_prefix,
                                          num_input * fanout, cu_stream));
  sampler_device->StreamSync(ctx, stream);

  d_temp_storage = sampler_device->AllocWorkspace(ctx, temp_storage_bytes);
  LOG(DEBUG) << "GPUSample: cuda temp_storage for ExclusiveSum malloc "
             << ToReadableSize(temp_storage_bytes);
  CUDA_CALL(cub::DeviceScan::ExclusiveSum(d_temp_storage, temp_storage_bytes,
                                          item_prefix, item_prefix,
                                          num_input * fanout, cu_stream));
  sampler_device->StreamSync(ctx, stream);
  sampler_device->FreeWorkspace(ctx, d_temp_storage);
  double prefix_sum_time = t2.Passed();
  LOG(DEBUG) << "GPUSample: ExclusiveSum time cost: " << prefix_sum_time;

  // compact edge
  Timer t3;
  compact_edge<<<grid, block, 0, cu_stream>>>(tmp_src, tmp_dst, out_src,
                                              out_dst, item_prefix,
                                              num_input * fanout, num_out);
  sampler_device->StreamSync(ctx, stream);
  double compact_edge_time = t3.Passed();
  LOG(DEBUG) << "GPUSample: compact_edge time cost: " << compact_edge_time;

  sampler_device->FreeWorkspace(ctx, item_prefix);
  sampler_device->FreeWorkspace(ctx, tmp_src);
  sampler_device->FreeWorkspace(ctx, tmp_dst);

  Profiler::Get().LogAdd(task_key, kLogL3SampleCooTime, sample_time);
  Profiler::Get().LogAdd(task_key, kLogL3SampleSortCooTime, sort_coo_time);
  Profiler::Get().LogAdd(task_key, kLogL3SampleCountEdgeTime, prefix_sum_time);
  Profiler::Get().LogAdd(task_key, kLogL3SampleCompactEdgesTime,
                         compact_edge_time);

  double total_time = t0.Passed();
  LOG(DEBUG) << "GPUSample: succeed total time cost: " << total_time;
}

}  // namespace cuda
}  // namespace common
}  // namespace samgraph