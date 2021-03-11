#include <thread>
#include <chrono>
#include <numeric>

#include <cuda_runtime.h>

#include "loops.h"
#include "engine.h"
#include "cuda_sampling.h"
#include "cuda_hashtable.h"
#include "cuda_mapping.h"
#include "cuda_convert.h"

namespace samgraph {
namespace common {

bool RunHostPermutateLoopOnce() {
    auto next_op = ID_COPYH2D;
    auto next_q = SamGraphEngine::GetTaskQueue(next_op);

    if (next_q->ExceedThreshold()) {
        std::this_thread::sleep_for(std::chrono::nanoseconds(1000));
        return true;
    }

    auto p = SamGraphEngine::GetRandomPermutation();
    auto batch = p->GetBatch();

    if (batch) {
        // Create task entry
        auto task = std::make_shared<TaskEntry>();
        task->key = encodeBatchKey(p->cur_epoch(), p->cur_batch());
        task->train_nodes = batch;

        next_q->AddTask(task);
    } else {
        std::this_thread::sleep_for(std::chrono::nanoseconds(1000));
    }

    return true;
}

bool RunIdCopyHost2DeviceLoopOnce() {
    auto next_op = DEV_SAMPLE;
    auto next_q = SamGraphEngine::GetTaskQueue(next_op);
    
    if (next_q->ExceedThreshold()) {
        std::this_thread::sleep_for(std::chrono::nanoseconds(1000));
        return true;
    }

    auto this_op = ID_COPYH2D;
    auto q = SamGraphEngine::GetTaskQueue(this_op);
    auto task = q->GetTask();

    if (task) {
        auto nodes = task->train_nodes;
        auto id_copy_h2d_stream = SamGraphEngine::GetIdCopyHost2DeviceStream();
        auto device = SamGraphEngine::GetSampleDevice();

        auto d_nodes = Tensor::Empty(nodes->dtype(), nodes->shape(), device);
        CUDA_CALL(cudaSetDevice(device));
        CUDA_CALL(cudaMemcpyAsync((void *)(d_nodes->mutable_data()),
                                  (const void*)(nodes->data()),
                                  (size_t) nodes->size(),
                                  (cudaMemcpyKind)cudaMemcpyHostToDevice,
                                  (cudaStream_t) *id_copy_h2d_stream));
        CUDA_CALL(cudaStreamSynchronize((cudaStream_t)*id_copy_h2d_stream));

        task->train_nodes = d_nodes;
        task->cur_input = d_nodes;
        next_q->AddTask(task);
    } else {
        std::this_thread::sleep_for(std::chrono::nanoseconds(1000));
    }

    return true;
}

bool RunDeviceSampleLoopOnce() {
    std::vector<QueueType> next_ops = {GRAPH_COPYD2D, ID_COPYD2H};
    for (auto next_op : next_ops) {
        auto q = SamGraphEngine::GetTaskQueue(next_op);
        if (q->ExceedThreshold()) {
            std::this_thread::sleep_for(std::chrono::nanoseconds(1000));
            return true;
        }
    }

    auto this_op = DEV_SAMPLE;
    auto q = SamGraphEngine::GetTaskQueue(this_op);
    auto task = q->GetTask();

    if (task) {
        auto fanouts = SamGraphEngine::GetFanout();
        auto num_layers = fanouts.size();
        auto last_layer_idx = num_layers - 1;

        auto dataset = SamGraphEngine::GetGraphDataset();
        auto sample_device = SamGraphEngine::GetSampleDevice();
        auto sample_stream = *SamGraphEngine::GetSampleStream();

        auto train_nodes = task->train_nodes;
        size_t predict_node_num = train_nodes->shape()[0] * std::accumulate(fanouts.begin(), fanouts.end(), 0);
        cuda::OrderedHashTable hash_table(predict_node_num, sample_device, sample_stream);
        
        size_t num_train_node = train_nodes->shape()[0];
        hash_table.FillWithUnique(static_cast<const nodeid_t *>(train_nodes->data()), num_train_node, sample_stream);

        task->output_graph.resize(num_layers);
        for (int i = last_layer_idx; i >= 0; i--) {
            const nodeid_t *indptr = static_cast<const nodeid_t *>(dataset->indptr->data());;
            const nodeid_t *indices = static_cast<const nodeid_t *>(dataset->indices->data());
            const size_t num_node = dataset->num_node;
            const size_t num_edge = dataset->num_edge;
            const int fanout = fanouts[i];
            const nodeid_t *input = static_cast<const nodeid_t *>(task->cur_input->data());
            const size_t num_input = task->cur_input->shape()[0];

            nodeid_t *out_src;
            nodeid_t *out_dst;
            size_t *num_out;
            size_t host_num_out;

            CUDA_CALL(cudaMalloc(&out_src, num_node * fanout * sizeof(nodeid_t)));
            CUDA_CALL(cudaMalloc(&out_dst, num_node * fanout * sizeof(nodeid_t)));
            CUDA_CALL(cudaMalloc(&num_out, sizeof(size_t)));

            // Sample a compact coo graph
            cuda::DeviceSample((const nodeid_t *)indptr, (const nodeid_t *)indices,
                               (const size_t) num_node, (const size_t) num_edge,
                               (const nodeid_t *) input, (const size_t) num_input, (const int) fanout,
                               (nodeid_t *) out_src, (nodeid_t *) out_dst, (size_t *) num_out, 
                               (cudaStream_t) sample_stream);

            // Get nnz
            CUDA_CALL(cudaMemcpyAsync((void *)&host_num_out, (const void*)num_out, (size_t)sizeof(size_t), 
                                      (cudaMemcpyKind)cudaMemcpyDeviceToHost, (cudaStream_t)sample_stream));
            CUDA_CALL(cudaStreamSynchronize(sample_stream));
            
            // Populate the hash table with newly sampled nodes
            nodeid_t *unique;
            size_t *num_unique;

            std::swap(out_src, out_dst); // swap the src and dst
            CUDA_CALL(cudaMalloc(&unique, host_num_out * sizeof(nodeid_t)));
            CUDA_CALL(cudaMalloc(&num_unique, sizeof(size_t)));
            hash_table.FillWithDuplicates(out_src, host_num_out, unique, num_unique, sample_stream);
            CUDA_CALL(cudaGetLastError());

            // Set the input of next sampling
            size_t host_num_unique;
            CUDA_CALL(cudaMemcpyAsync((void *)&host_num_unique, (const void*)num_unique, (size_t)sizeof(size_t), 
                                      (cudaMemcpyKind)cudaMemcpyDeviceToHost, (cudaStream_t)sample_stream));
            CUDA_CALL(cudaStreamSynchronize(sample_stream));
            task->cur_input = Tensor::FromBlob((void *)unique, DataType::kSamI32, {host_num_unique}, sample_device);

            // Mapping edges
            nodeid_t *new_src;
            nodeid_t *new_dst;

            CUDA_CALL(cudaMalloc(&new_src, host_num_out * sizeof(size_t)));
            CUDA_CALL(cudaMalloc(&new_dst, host_num_out * sizeof(size_t)));

            cuda::MapEdges((const nodeid_t *) out_src,
                           (nodeid_t * const) new_src,
                           (const nodeid_t * const) out_dst,
                           (nodeid_t * const) new_dst,
                           (const size_t) host_num_out,
                           (cuda::DeviceOrderedHashTable) hash_table.DeviceHandle(),
                           (cudaStream_t) sample_stream);
            CUDA_CALL(cudaGetLastError());

            // Convert COO format to CSR format
            nodeid_t *new_indptr;
            CUDA_CALL(cudaMalloc(&new_indptr, (host_num_unique + 1) * sizeof(nodeid_t)));
            cuda::ConvertCoo2Csr(new_src, new_dst, host_num_unique, num_input, host_num_out, new_indptr, sample_device, sample_stream);

            // Construct TrainGraph
            auto train_graph = std::make_shared<TrainGraph>();
            train_graph->indptr = Tensor::FromBlob(new_indptr, DataType::kSamI32, {host_num_unique + 1}, sample_device);
            train_graph->indices = Tensor::FromBlob(new_dst, DataType::kSamI32, {host_num_out}, sample_device);
            train_graph->num_row = host_num_unique;
            train_graph->num_column = num_input;
            train_graph->num_edge = host_num_out;

            task->output_graph[i] = train_graph;

            // Do some clean jobs
            CUDA_CALL(cudaFree(out_src));
            CUDA_CALL(cudaFree(out_dst));
            CUDA_CALL(cudaFree(num_out));
            CUDA_CALL(cudaFree(new_src));
            CUDA_CALL(cudaFree(num_unique));

            if (i == 0) {
                task->output_nodes = Tensor::FromBlob(unique, DataType::kSamI32, {host_num_unique}, sample_device);
            } else {
                CUDA_CALL(cudaFree(unique));
            }

            // Deliver the taks to next worker thread
            std::vector<QueueType> next_ops = {GRAPH_COPYD2D, ID_COPYD2H};
            for (auto next_op : next_ops) {
                auto q = SamGraphEngine::GetTaskQueue(next_op);
                q->AddTask(task);
            }
        }
    } else {
        std::this_thread::sleep_for(std::chrono::nanoseconds(1000));
    }

    return true;
}

bool RunGraphCopyDevice2DeviceLoopOnce() {
    auto this_op = GRAPH_COPYD2D;
    auto q = SamGraphEngine::GetTaskQueue(this_op);
    auto task = q->GetTask();

    if (task) {
        auto train_device = SamGraphEngine::GetTrainDevice();

        auto graph_copy_stream = *SamGraphEngine::GetGraphCopyDevice2DeviceStream();

        for (auto graph : task->output_graph) {
            void *train_indptr;
            void *train_indices;
            CUDA_CALL(cudaSetDevice(train_device));
            CUDA_CALL(cudaMalloc(&train_indptr, graph->indptr->size()));
            CUDA_CALL(cudaMalloc(&train_indices, graph->indices->size()));
            CUDA_CALL(cudaMemcpyAsync(train_indptr, graph->indptr->data(), graph->indptr->size(),
                                      cudaMemcpyDeviceToDevice, graph_copy_stream));
            CUDA_CALL(cudaMemcpyAsync(train_indices, graph->indices->data(), graph->indices->size(),
                                      cudaMemcpyDeviceToDevice, graph_copy_stream));
            
            graph->indptr = Tensor::FromBlob(train_indptr, graph->indptr->dtype(), graph->indptr->shape(), train_device);
            graph->indices = Tensor::FromBlob(train_indices, graph->indptr->dtype(), graph->indices->shape(), train_device);
        }

        CUDA_CALL(cudaStreamSynchronize(graph_copy_stream));

        auto ready_table = SamGraphEngine::GetSubmitTable();
        ready_table->AddReadyCount(task->key);
    } else {
        std::this_thread::sleep_for(std::chrono::nanoseconds(1000));
    }

    return true;
}

bool RunIdCopyDevice2HostLoopOnce() {
    auto next_op = FEAT_EXTRACT;
    auto next_q = SamGraphEngine::GetTaskQueue(next_op);

    if (next_q->ExceedThreshold()) {
        std::this_thread::sleep_for(std::chrono::nanoseconds(1000));
        return true;
    }

    auto this_op = ID_COPYH2D;
    auto q = SamGraphEngine::GetTaskQueue(this_op);
    auto task = q->GetTask();

    if (task) {
        auto id_copy_d2h_stream = *SamGraphEngine::GetIdCopyDevice2HostStream();
        void *node_ids = malloc(task->output_nodes->size());

        CUDA_CALL(cudaMemcpyAsync(node_ids, task->output_nodes->data(), task->output_nodes->size(),
                                  cudaMemcpyDeviceToHost, id_copy_d2h_stream));
        
        task->output_nodes = Tensor::FromBlob(node_ids, task->output_nodes->dtype(),
                                              task->output_nodes->shape(), CPU_DEVICE_ID);

        CUDA_CALL(cudaStreamSynchronize(id_copy_d2h_stream));
        
        next_q->AddTask(task);
    } else {
        std::this_thread::sleep_for(std::chrono::nanoseconds(1000));
    }

    return true;
}

bool RunHostFeatureExtractLoopOnce() {
    auto next_op = FEAT_COPYH2D;
    auto next_q = SamGraphEngine::GetTaskQueue(next_op);
    if (next_q->ExceedThreshold()) {
        std::this_thread::sleep_for(std::chrono::nanoseconds(1000));
        return true;
    }

    auto this_op = FEAT_EXTRACT;
    auto q = SamGraphEngine::GetTaskQueue(this_op);
    auto task = q->GetTask();

    if (task) {
        auto dataset = SamGraphEngine::GetGraphDataset();
        auto output_nodes = task->output_nodes;
        auto feat_dim = dataset->feat->shape()[1];
        auto feat_type = dataset->feat->dtype();
        auto label_type = dataset->label->dtype();
        auto idx = reinterpret_cast<const nodeid_t *>(output_nodes->data()); 
        auto num_idx = output_nodes->shape()[0];

        task->output_feat = Tensor::Empty(feat_type, {num_idx, feat_dim}, CPU_DEVICE_ID);
        task->output_label = Tensor::Empty(label_type, {num_idx}, CPU_DEVICE_ID);

        auto extractor = SamGraphEngine::GetCpuExtractor();

        auto feat_dst = task->output_feat->mutable_data();
        auto feat_src = dataset->feat->data();
        extractor->extract(feat_dst, feat_src, idx, num_idx, feat_dim, feat_type);

        auto label_dst = task->output_label->mutable_data();
        auto label_src = dataset->label->data();
        extractor->extract(label_dst, label_src, idx, num_idx, 1, label_type);

        next_q->AddTask(task);
    } else {
        std::this_thread::sleep_for(std::chrono::nanoseconds(1000));
    }

    return true;
}

bool RunFeatureCopyHost2DeviceLoop() {
    auto next_op = SUBMIT;
    auto next_q = SamGraphEngine::GetTaskQueue(next_op);
    if (next_q->ExceedThreshold()) {
        std::this_thread::sleep_for(std::chrono::nanoseconds(1000));
        return true;
    }

    auto this_op = FEAT_COPYH2D;
    auto q = SamGraphEngine::GetTaskQueue(this_op);
    auto task = q->GetTask();

    if (task) {
        auto train_device = SamGraphEngine::GetTrainDevice();
        CUDA_CALL(cudaSetDevice(train_device));

        auto feat_copy_h2d_stream = *SamGraphEngine::GetFeatureCopyHost2DeviceStream();

        auto host_feat = task->output_feat;
        auto feat_dim = host_feat->shape()[1];
        auto feat_type = host_feat->dtype();

        auto num_idx = host_feat->shape()[0];

        auto host_label = task->output_label;
        auto label_type = host_label->dtype();

        auto train_feat = Tensor::Empty(feat_type, {num_idx, feat_dim}, train_device);
        auto train_label = Tensor::Empty(label_type, {num_idx}, train_device);

        CUDA_CALL(cudaMemcpyAsync(train_feat->mutable_data(), host_feat->data(), host_feat->size(),
                                  cudaMemcpyHostToDevice, feat_copy_h2d_stream));
        CUDA_CALL(cudaMemcpyAsync(train_label->mutable_data(), host_label->data(), host_label->size(),
                                  cudaMemcpyHostToDevice, feat_copy_h2d_stream));
        CUDA_CALL(cudaStreamSynchronize(feat_copy_h2d_stream));

        auto ready_table = SamGraphEngine::GetSubmitTable();
        ready_table->AddReadyCount(task->key);

        next_q->AddTask(task);
    } else {
        std::this_thread::sleep_for(std::chrono::nanoseconds(1000));
    }

    return true;
}

bool RunSubmitLoopOnce() {
    auto graph_pool = SamGraphEngine::GetGraphPool();
    if (graph_pool->ExceedThreshold()) {
        return true;
    }

    auto this_op = SUBMIT;
    auto q = SamGraphEngine::GetTaskQueue(this_op);
    auto task = q->GetTask();

    if (task) {
        graph_pool->AddGraphBatch(task->key, task);
    } else {
        std::this_thread::sleep_for(std::chrono::nanoseconds(1000));
    }

    return true;
}

void HostPermutateLoop() {
    while(RunHostPermutateLoopOnce() && !SamGraphEngine::ShouldShutdown()) {
    }
    SamGraphEngine::ReportThreadFinish();
}

void IdCopyHost2DeviceLoop() {
    CUDA_CALL(cudaSetDevice(SamGraphEngine::GetSampleDevice()));
    while(RunIdCopyHost2DeviceLoopOnce() && !SamGraphEngine::ShouldShutdown()) {        
    }
    SamGraphEngine::ReportThreadFinish();
}

void DeviceSampleLoop() {
    CUDA_CALL(cudaSetDevice(SamGraphEngine::GetSampleDevice()));
    while(RunDeviceSampleLoopOnce() && !SamGraphEngine::ShouldShutdown()) {
    }
    SamGraphEngine::ReportThreadFinish();
}

void GraphCopyDevice2DeviceLoop() {
    while(RunGraphCopyDevice2DeviceLoopOnce() && !SamGraphEngine::ShouldShutdown()) {
    }
    SamGraphEngine::ReportThreadFinish();
}

void IdCopyDevice2HostLoop() {
    CUDA_CALL(cudaSetDevice(SamGraphEngine::GetSampleDevice()));
    while(RunIdCopyDevice2HostLoopOnce() && !SamGraphEngine::ShouldShutdown()) {
    }
    SamGraphEngine::ReportThreadFinish();
}

void HostFeatureExtractLoop() {
    while(RunHostFeatureExtractLoopOnce() && !SamGraphEngine::ShouldShutdown()) {
    }
    SamGraphEngine::ReportThreadFinish();
}

void FeatureCopyHost2DeviceLoop() {
    CUDA_CALL(cudaSetDevice(SamGraphEngine::GetTrainDevice()));
    while(RunFeatureCopyHost2DeviceLoop() && !SamGraphEngine::ShouldShutdown()) {
    }
    SamGraphEngine::ReportThreadFinish();
}

void SubmitLoop() {
    while(RunSubmitLoopOnce() && !SamGraphEngine::ShouldShutdown()) {
    }
    SamGraphEngine::ReportThreadFinish();
}

} // namespace common
} // namespace samgraph
