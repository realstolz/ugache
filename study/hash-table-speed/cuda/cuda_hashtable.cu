/*
 * Copyright 2022 Institute of Parallel and Distributed Systems, Shanghai Jiao Tong University
 * 
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 * 
 *     http://www.apache.org/licenses/LICENSE-2.0
 * 
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 */

#include <cuda_runtime.h>

#include <cassert>
#include <cstdio>
#include <cub/cub.cuh>

#include "../common.h"
#include "../device.h"
#include "../logging.h"
#include "../timer.h"
#include "cuda_hashtable.h"
#include "cuda_utils.h"

namespace samgraph {
namespace common {
namespace cuda {

class MutableDeviceOrderedHashTable : public DeviceOrderedHashTable {
  static inline __host__ __device__ uint32_t high32(uint64_t val) {
    constexpr uint64_t kI32Mask = 0xffffffff;
    return (val >> 32) & kI32Mask;
  }
  static inline __host__ __device__ uint32_t low32(uint64_t val) {
    constexpr uint64_t kI32Mask = 0xffffffff;
    return val & kI32Mask;
  }
  static inline __host__ __device__ uint64_t uint_to_ll(uint32_t low, uint32_t high) {
    return (((uint64_t)high) << 32) + low;
  }
 public:
  typedef typename DeviceOrderedHashTable::BucketO2N *IteratorO2N;

  explicit MutableDeviceOrderedHashTable(OrderedHashTable *const host_table)
      : DeviceOrderedHashTable(host_table->DeviceHandle()) {}

  inline __device__ IteratorO2N SearchO2N(const IdType id) {
    const IdType pos = SearchForPositionO2N(id);

    return GetMutableO2N(pos);
  }

  static constexpr IdType MAX_DELTA = 100;
  enum InsertStatus {
    kConflict = 0,
    kFirstSuccess,
    kDupSuccess,
  };
  inline __device__ InsertStatus AttemptInsertAtO2N(const IdType pos, const IdType id,
                                            const IdType val,
                                            const IdType _) {
    auto iter = GetMutableO2N(pos);
#ifndef SXN_NAIVE_HASHMAP
    // FIXME: only support sizeof(IdType) == 4
    static_assert(sizeof(IdType) == 4, "");

    using ull = unsigned long long int;
    // constexpr ull kI32Mask = 0xffffffff;
    ull old = *(reinterpret_cast<ull*>(iter));
    auto old_state = high32(old);
    auto old_key = low32(old);
    if (old_state == kOccupied) {
      if (old_key == id) assert(false);
      return kConflict;
    }
    ull new_val = uint_to_ll(id, kOccupied);
    ull ret_val = atomicCAS(reinterpret_cast<ull*>(iter), old, new_val);
    if (ret_val == old) {
      iter->val = val;
      return kFirstSuccess;
    }
    IdType ret_key = low32(ret_val);
    if (ret_key == id) assert(false);
    return kConflict;
#else
    IdType old_version = iter->version;
    if (old_version == version) return kDupSuccess;
    if (atomicCAS(&(iter->version), old_version, version) == old_version) {
      iter->key = id;
      iter->index = index;
      iter->local = Constant::kEmptyKey;
      return kFirstSuccess;
    }
    return kDupSuccess;
#endif
  }

  /** Return corresponding bucket on first insertion.
   *  Duplicate attemps return nullptr
   */
  inline __device__ IteratorO2N InsertO2N(const IdType id, const IdType index,
                                          const IdType version) {
#ifndef SXN_NAIVE_HASHMAP
    IdType pos = HashO2N(id);

    // linearly scan for an empty slot or matching entry
    IdType delta = 1;
    InsertStatus ret;
    while ((ret = AttemptInsertAtO2N(pos, id, index, version)) == kConflict) {
      pos = HashO2N(pos + delta);
      delta += 1;
    }
#else
    IdType pos = id;
    ret = AttemptInsertAtO2N(pos, id, index, version);
    assert(ret != kConflict);
#endif
    return (ret == kFirstSuccess) ? GetMutableO2N(pos) : nullptr;
  }

  inline __device__ IdType IterO2NToPos(const IteratorO2N iter) {
    return iter - _o2n_table;
  }

//  private:
  inline __device__ IteratorO2N GetMutableO2N(const IdType pos) {
    assert(pos < this->_o2n_size);
    // The parent class Device is read-only, but we ensure this can only be
    // constructed from a mutable version of OrderedHashTable, making this
    // a safe cast to perform.
    return const_cast<IteratorO2N>(this->_o2n_table + pos);
  }

};

/**
 * Calculate the number of buckets in the hashtable. To guarantee we can
 * fill the hashtable in the worst case, we must use a number of buckets which
 * is a power of two.
 * https://en.wikipedia.org/wiki/Quadratic_probing#Limitations
 */
size_t TableSize(const size_t num, const size_t scale) {
  const size_t next_pow2 = 1 << static_cast<size_t>(1 + std::log2(num >> 1));
  return next_pow2 << scale;
}

template <size_t BLOCK_SIZE, size_t TILE_SIZE>
__global__ void generate_hashmap_unique(const IdType *const items,
                                        const size_t num_items,
                                        MutableDeviceOrderedHashTable table,
                                        const IdType global_offset,
                                        const IdType version) {
  assert(BLOCK_SIZE == blockDim.x);

  using IteratorO2N = typename MutableDeviceOrderedHashTable::IteratorO2N;

  const size_t block_start = TILE_SIZE * blockIdx.x;
  const size_t block_end = TILE_SIZE * (blockIdx.x + 1);

#pragma unroll
  for (size_t index = threadIdx.x + block_start; index < block_end;
       index += BLOCK_SIZE) {
    if (index < num_items) {
      const IteratorO2N bucket = table.InsertO2N(items[index], index, version);
      // since we are only inserting unique items, we know their local id
      // will be equal to their index
    }
  }
}
template <size_t BLOCK_SIZE, size_t TILE_SIZE>
__global__ void evict_hashmap_unique(const IdType *const items,
                                    const size_t num_items,
                                    MutableDeviceOrderedHashTable table,
                                    const IdType version) {
  assert(BLOCK_SIZE == blockDim.x);

  using IteratorO2N = typename MutableDeviceOrderedHashTable::IteratorO2N;

  const size_t block_start = TILE_SIZE * blockIdx.x;
  const size_t block_end = TILE_SIZE * (blockIdx.x + 1);

#pragma unroll
  for (size_t index = threadIdx.x + block_start; index < block_end;
       index += BLOCK_SIZE) {
    if (index < num_items) {
      const IteratorO2N bucket = table.SearchO2N(items[index]);
      bucket->state = kInvalid;
    }
  }
}
template <size_t BLOCK_SIZE, size_t TILE_SIZE>
__global__ void lookup_hashmap_ifexist(const IdType *const items,
                             const size_t num_items,
                             IdType* pos,
                             MutableDeviceOrderedHashTable table,
                             const IdType version) {
  assert(BLOCK_SIZE == blockDim.x);

  const size_t block_start = TILE_SIZE * blockIdx.x;
  const size_t block_end = TILE_SIZE * (blockIdx.x + 1);

#pragma unroll
  for (size_t index = threadIdx.x + block_start; index < block_end;
       index += BLOCK_SIZE) {
    if (index < num_items) {
      auto rst_pos = table.SearchForPositionO2N(items[index]);
      pos[index] = rst_pos;
    }
  }
}

template <size_t BLOCK_SIZE, size_t TILE_SIZE>
__global__ void lookup_val_hashmap(const IdType *const items,
                             const size_t num_items,
                             ValType* vals,
                             MutableDeviceOrderedHashTable table,
                             const IdType version) {
  assert(BLOCK_SIZE == blockDim.x);

  const size_t block_start = TILE_SIZE * blockIdx.x;
  const size_t block_end = TILE_SIZE * (blockIdx.x + 1);

#pragma unroll
  for (size_t index = threadIdx.x + block_start; index < block_end;
       index += BLOCK_SIZE) {
    if (index < num_items) {
      auto iter = table.SearchO2N(items[index]);
      vals[index] = iter->val;
    }
  }
}


// DeviceOrderedHashTable implementation
DeviceOrderedHashTable::DeviceOrderedHashTable(const BucketO2N *const o2n_table,
                                               const size_t o2n_size,
                                               const IdType version)
    : _o2n_table(o2n_table),
      _o2n_size(o2n_size),
      _version(version) {}

DeviceOrderedHashTable OrderedHashTable::DeviceHandle() const {
  return DeviceOrderedHashTable(_o2n_table,
      _o2n_size, _version);
}

// OrderedHashTable implementation
OrderedHashTable::OrderedHashTable(const size_t size, Context ctx,
                                   StreamHandle stream, const size_t scale)
    : _o2n_table(nullptr),
#ifndef SXN_NAIVE_HASHMAP
      _o2n_size(TableSize(size, scale)),
#else
      _o2n_size(size),
#endif
      _ctx(ctx),
      _version(0),
      _num_items(0) {
  // make sure we will at least as many buckets as items.
  auto device = Device::Get(_ctx);
  auto cu_stream = static_cast<cudaStream_t>(stream);

  _o2n_table = static_cast<BucketO2N *>(
      device->AllocDataSpace(_ctx, sizeof(BucketO2N) * _o2n_size));

  CUDA_CALL(cudaMemsetAsync(_o2n_table, (int)Constant::kEmptyKey,
                       sizeof(BucketO2N) * _o2n_size, cu_stream));
  device->StreamSync(_ctx, stream);
  LOG(INFO) << "cuda hashtable init with " << _o2n_size
            << " O2N table size";
}

OrderedHashTable::~OrderedHashTable() {
  Timer t;

  auto device = Device::Get(_ctx);
  device->FreeDataSpace(_ctx, _o2n_table);

  LOG(DEBUG) << "free " << t.Passed();
}

void OrderedHashTable::Reset(StreamHandle stream) {
  _version++;
  _num_items = 0;
}


void OrderedHashTable::FillWithUnique(const IdType *const input,
                                      const size_t num_input,
                                      StreamHandle stream) {
  const size_t num_tiles = RoundUpDiv(num_input, Constant::kCudaTileSize);
  const dim3 grid(num_tiles);
  const dim3 block(Constant::kCudaBlockSize);

  auto device_table = MutableDeviceOrderedHashTable(this);
  auto cu_stream = static_cast<cudaStream_t>(stream);

  generate_hashmap_unique<Constant::kCudaBlockSize, Constant::kCudaTileSize>
      <<<grid, block, 0, cu_stream>>>(input, num_input, device_table,
                                      _num_items, _version);
  // Device::Get(_ctx)->StreamSync(_ctx, stream);

  _num_items += num_input;

  LOG(DEBUG) << "OrderedHashTable::FillWithUnique insert " << num_input
             << " items, now " << _num_items << " in total";
}

void OrderedHashTable::EvictWithUnique(const IdType *const input,
                                       const size_t num_input,
                                       StreamHandle stream) {
  const size_t num_tiles = RoundUpDiv(num_input, Constant::kCudaTileSize);
  const dim3 grid(num_tiles);
  const dim3 block(Constant::kCudaBlockSize);

  auto device_table = MutableDeviceOrderedHashTable(this);
  auto cu_stream = static_cast<cudaStream_t>(stream);

  evict_hashmap_unique<Constant::kCudaBlockSize, Constant::kCudaTileSize>
      <<<grid, block, 0, cu_stream>>>(input, num_input, device_table, _version);
  // Device::Get(_ctx)->StreamSync(_ctx, stream);

  _num_items -= num_input;

  LOG(DEBUG) << "OrderedHashTable::EvictWithUnique remove " << num_input
             << " items, now " << _num_items << " in total";
}

void OrderedHashTable::LookupIfExist(const IdType *const input, const size_t num_input, IdType *pos, StreamHandle stream) {
  const size_t num_tiles = RoundUpDiv(num_input, Constant::kCudaTileSize);
  const dim3 grid(num_tiles);
  const dim3 block(Constant::kCudaBlockSize);

  auto device_table = MutableDeviceOrderedHashTable(this);
  auto cu_stream = static_cast<cudaStream_t>(stream);

  lookup_hashmap_ifexist<Constant::kCudaBlockSize, Constant::kCudaTileSize>
      <<<grid, block, 0, cu_stream>>>(input, num_input, pos, device_table, _version);
  // Device::Get(_ctx)->StreamSync(_ctx, stream);
}

template <size_t BLOCK_SIZE, size_t TILE_SIZE>
__global__ void check_cuda_array_(IdType* array, IdType cmp, IdType num_items, bool exp) {
  assert(BLOCK_SIZE == blockDim.x);
  const size_t block_start = TILE_SIZE * blockIdx.x;
  const size_t block_end = TILE_SIZE * (blockIdx.x + 1);

  for (size_t index = threadIdx.x + block_start; index < block_end;
       index += BLOCK_SIZE) {
    if (index < num_items) {
      assert((array[index] == cmp) == exp);
    }
  }
}

void check_cuda_array(IdType* array, IdType cmp, IdType num_items, bool exp, StreamHandle stream) {
  const size_t num_tiles = RoundUpDiv<size_t>(num_items, Constant::kCudaTileSize);
  const dim3 grid(num_tiles);
  const dim3 block(Constant::kCudaBlockSize);
  auto cu_stream = static_cast<cudaStream_t>(stream);
  check_cuda_array_<Constant::kCudaBlockSize, Constant::kCudaTileSize>
      <<<grid, block, 0, cu_stream>>>(array, cmp, num_items, exp);
}

template <
    typename OffsetT = ptrdiff_t>
struct cubEntryIs {
  // Required iterator traits
  typedef cubEntryIs                       self_type;              ///< My own type
  typedef OffsetT                          difference_type;        ///< Type to express the result of subtracting one iterator from another
  typedef IdType                           value_type;             ///< The type of the element the iterator can point to
  typedef IdType*                          pointer;                ///< The type of a pointer to an element the iterator can point to
  typedef IdType                           reference;              ///< The type of a reference to an element the iterator can point to
  typedef std::random_access_iterator_tag     iterator_category;      ///< The iterator category
  OrderedHashTable::BucketO2N* array;
  IdType cmp;
  __host__ __device__ cubEntryIs(OrderedHashTable::BucketO2N* arr, IdType c) : array(arr),cmp(c) {}
  template <typename Distance>
  __host__ __device__ __forceinline__ IdType operator[](const Distance d) const {
  // __host__ __device__ __forceinline__ IdType operator[](const IdType d) {
    return (array[d].state == cmp) ? 1 : 0;
  }
  template <typename Distance>
  __host__ __device__ __forceinline__ self_type operator+(Distance n) const {
    return self_type(array + n, cmp);
  }
};

void OrderedHashTable::CountEntries(StreamHandle stream){
  void* d_temp_storage = nullptr;
  size_t temp_storage_bytes;
  cubEntryIs<> input_iter(this->_o2n_table, kOccupied);
  auto out = Tensor::Empty(kI32, {1}, GPU(0), "");
  auto cu_stream = static_cast<cudaStream_t>(stream);
  cub::DeviceReduce::Sum(d_temp_storage, temp_storage_bytes, input_iter, out->Ptr<IdType>(), this->_o2n_size, cu_stream);
  CUDA_CALL(cudaMalloc(&d_temp_storage, temp_storage_bytes));

  auto print_out = [out, stream](std::string s){
    auto cpu_out = Tensor::CopyTo(out, CPU(), stream);
    Device::Get(GPU(0))->StreamSync(GPU(0), stream);
    LOG(ERROR) << s << cpu_out->CPtr<IdType>()[0];
  };

  cub::DeviceReduce::Sum(d_temp_storage, temp_storage_bytes, input_iter, out->Ptr<IdType>(), this->_o2n_size, cu_stream);
  Device::Get(GPU(0))->StreamSync(GPU(0), stream);
  print_out("Occupied ");

  input_iter.cmp = kInvalid;
  cub::DeviceReduce::Sum(d_temp_storage, temp_storage_bytes, input_iter, out->Ptr<IdType>(), this->_o2n_size, cu_stream);
  Device::Get(GPU(0))->StreamSync(GPU(0), stream);
  print_out("Invalid ");

  input_iter.cmp = kUnused;
  cub::DeviceReduce::Sum(d_temp_storage, temp_storage_bytes, input_iter, out->Ptr<IdType>(), this->_o2n_size, cu_stream);
  Device::Get(GPU(0))->StreamSync(GPU(0), stream);
  print_out("Unused ");

  input_iter.cmp = 0xffffffff;
  cub::DeviceReduce::Sum(d_temp_storage, temp_storage_bytes, input_iter, out->Ptr<IdType>(), this->_o2n_size, cu_stream);
  Device::Get(GPU(0))->StreamSync(GPU(0), stream);
  print_out("Default ");
}

}  // namespace cuda
}  // namespace common
}  // namespace samgraph
