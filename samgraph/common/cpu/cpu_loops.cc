#include "cpu_loops.h"

#include <cuda_runtime.h>

#include <chrono>
#include <cstdlib>
#include <iostream>
#include <numeric>

#include "../device.h"
#include "../logging.h"
#include "../profiler.h"
#include "../timer.h"
#include "cpu_engine.h"
#include "cpu_function.h"
#include "cpu_hashtable.h"

namespace samgraph {
namespace common {
namespace cpu {

using TaskPtr = std::shared_ptr<Task>;

TaskPtr DoPermuate() {
  auto p = CpuEngine::Get()->GetPermutator();
  auto batch = p->GetBatch();

  if (batch) {
    auto task = std::make_shared<Task>();
    task->key = CpuEngine::Get()->GetBatchKey(p->Epoch(), p->Step());
    task->output_nodes = batch;
    return task;
  } else {
    return nullptr;
  }
}

void DoCpuSample(TaskPtr task) {
  auto fanouts = CpuEngine::Get()->GetFanout();
  auto num_layers = fanouts.size();
  auto last_layer_idx = num_layers - 1;

  auto dataset = CpuEngine::Get()->GetGraphDataset();
  auto cpu_device = Device::Get(CPU());

  auto hash_table = CpuEngine::Get()->GetHashTable();
  hash_table->Reset();

  size_t num_train_node = task->output_nodes->Shape()[0];
  hash_table->Populate(static_cast<const IdType *>(task->output_nodes->Data()),
                       num_train_node);

  task->graphs.resize(num_layers);

  const IdType *indptr = static_cast<const IdType *>(dataset->indptr->Data());
  const IdType *indices = static_cast<const IdType *>(dataset->indices->Data());

  auto cur_input = task->output_nodes;

  for (int i = last_layer_idx; i >= 0; i--) {
    Timer t0;
    const int fanout = fanouts[i];
    const IdType *input = static_cast<const IdType *>(cur_input->Data());
    const size_t num_input = cur_input->Shape()[0];
    LOG(DEBUG) << "CpuSample: begin sample layer " << i;

    IdType *out_src = static_cast<IdType *>(
        cpu_device->AllocWorkspace(CPU(), num_input * fanout * sizeof(IdType)));
    IdType *out_dst = static_cast<IdType *>(
        cpu_device->AllocWorkspace(CPU(), num_input * fanout * sizeof(IdType)));
    size_t num_out;
    LOG(DEBUG) << "CpuSample: cpu out_src malloc "
               << ToReadableSize(num_input * fanout * sizeof(IdType));
    LOG(DEBUG) << "CpuSample: cpu out_src malloc "
               << ToReadableSize(num_input * fanout * sizeof(IdType));

    // Sample a compact coo graph
    CpuSample(indptr, indices, input, num_input, out_src, out_dst, &num_out,
              fanout);
    LOG(DEBUG) << "CpuSample: num_out " << num_out;
    Profiler::Get()->num_samples[task->key] += num_out;
    double ns_time = t0.Passed();

    Timer t1;
    Timer t2;

    // Populate the hash table with newly sampled nodes
    hash_table->Populate(out_dst, num_out);

    double populate_time = t2.Passed();

    Timer t3;
    size_t num_unique = hash_table->NumItems();
    LOG(DEBUG) << "CpuSample: num_unique " << num_unique;
    IdType *unique = static_cast<IdType *>(
        cpu_device->AllocWorkspace(CPU(), num_unique * sizeof(IdType)));
    hash_table->MapNodes(unique, num_unique);

    double map_nodes_time = t3.Passed();

    Timer t4;
    // Mapping edges
    IdType *new_src = static_cast<IdType *>(
        cpu_device->AllocWorkspace(CPU(), num_out * sizeof(IdType)));
    IdType *new_dst = static_cast<IdType *>(
        cpu_device->AllocWorkspace(CPU(), num_out * sizeof(IdType)));
    LOG(DEBUG) << "CpuSample: cpu new_src malloc "
               << ToReadableSize(num_out * sizeof(IdType));
    LOG(DEBUG) << "CpuSample: cpu new_src malloc "
               << ToReadableSize(num_out * sizeof(IdType));
    hash_table->MapEdges(out_src, out_dst, num_out, new_src, new_dst);

    double map_edges_time = t4.Passed();

    double remap_time = t1.Passed();

    auto train_graph = std::make_shared<TrainGraph>();
    train_graph->row = Tensor::FromBlob(
        new_dst, DataType::kI32, {num_out}, CPU(),
        "train_graph.row_cpu_sample_" + std::to_string(task->key) + "_" +
            std::to_string(i));
    train_graph->col = Tensor::FromBlob(
        new_src, DataType::kI32, {num_out}, CPU(),
        "train_graph.col_cpu_sample_" + std::to_string(task->key) + "_" +
            std::to_string(i));
    train_graph->num_row = num_unique;
    train_graph->num_column = num_input;
    train_graph->num_edge = num_out;

    task->graphs[i] = train_graph;
    cur_input =
        Tensor::FromBlob((void *)unique, DataType::kI32, {num_unique}, CPU(),
                         "cur_input_unique_cpu_" + std::to_string(task->key) +
                             "_" + std::to_string(i));

    cpu_device->FreeWorkspace(CPU(), out_src);
    cpu_device->FreeWorkspace(CPU(), out_dst);

    Profiler::Get()->ns_time[task->key] += ns_time;
    Profiler::Get()->remap_time[task->key] += remap_time;
    Profiler::Get()->populate_time[task->key] += populate_time;
    Profiler::Get()->map_node_time[task->key] += map_nodes_time;
    Profiler::Get()->map_edge_time[task->key] += map_edges_time;

    LOG(DEBUG) << "layer " << i << " ns " << ns_time << " remap " << remap_time;

    LOG(DEBUG) << "CpuSample: finish layer " << i;
  }

  task->input_nodes = cur_input;
}

void DoFeatureExtract(TaskPtr task) {
  auto dataset = CpuEngine::Get()->GetGraphDataset();

  auto input_nodes = task->input_nodes;
  auto output_nodes = task->output_nodes;

  auto feat_dim = dataset->feat->Shape()[1];
  auto feat_type = dataset->feat->Type();
  auto label_type = dataset->label->Type();

  auto input_data = reinterpret_cast<const IdType *>(input_nodes->Data());
  auto output_data = reinterpret_cast<const IdType *>(output_nodes->Data());
  auto num_input = input_nodes->Shape()[0];
  auto num_ouput = output_nodes->Shape()[0];

  auto feat = Tensor::Empty(feat_type, {num_input, feat_dim}, CPU(),
                            "task.input_feat_cpu_" + std::to_string(task->key));
  auto label =
      Tensor::Empty(label_type, {num_ouput}, CPU(),
                    "task.output_label_cpu" + std::to_string(task->key));

  auto extractor = CpuEngine::Get()->GetExtractor();

  auto feat_dst = feat->MutableData();
  auto feat_src = dataset->feat->Data();
  extractor->extract(feat_dst, feat_src, input_data, num_input, feat_dim,
                     feat_type);

  auto label_dst = label->MutableData();
  auto label_src = dataset->label->Data();
  extractor->extract(label_dst, label_src, output_data, num_ouput, 1,
                     label_type);

  task->input_feat = feat;
  task->output_label = label;
}

void DoGraphCopy(TaskPtr task) {
  auto trainer_ctx = CpuEngine::Get()->GetTrainerCtx();
  auto trainer_device = Device::Get(trainer_ctx);
  auto work_stream = CpuEngine::Get()->GetWorkStream();

  for (size_t i = 0; i < task->graphs.size(); i++) {
    auto graph = task->graphs[i];
    auto train_row =
        Tensor::Empty(graph->row->Type(), graph->row->Shape(), trainer_ctx,
                      "train_graph.row_cuda_train_" +
                          std::to_string(task->key) + "_" + std::to_string(i));
    auto train_col =
        Tensor::Empty(graph->col->Type(), graph->col->Shape(), trainer_ctx,
                      "train_graph.col_cuda_train_" +
                          std::to_string(task->key) + "_" + std::to_string(i));
    LOG(DEBUG) << "GraphCopyDevice2DeviceLoop: cuda train_row malloc "
               << ToReadableSize(graph->row->NumBytes());
    LOG(DEBUG) << "GraphCopyDevice2DeviceLoop: cuda train_col malloc "
               << ToReadableSize(graph->col->NumBytes());

    trainer_device->CopyDataFromTo(
        graph->row->Data(), 0, train_row->MutableData(), 0,
        graph->row->NumBytes(), CPU(), trainer_ctx, work_stream);
    trainer_device->CopyDataFromTo(
        graph->col->Data(), 0, train_col->MutableData(), 0,
        graph->col->NumBytes(), CPU(), trainer_ctx, work_stream);
    trainer_device->StreamSync(trainer_ctx, work_stream);

    graph->row = train_row;
    graph->col = train_col;
  }
}

void DoFeatureCopy(TaskPtr task) {
  auto trainer_ctx = CpuEngine::Get()->GetTrainerCtx();
  auto trainer_device = Device::Get(trainer_ctx);
  auto work_stream = CpuEngine::Get()->GetWorkStream();

  auto feat = task->input_feat;
  auto label = task->output_label;

  auto train_feat =
      Tensor::Empty(feat->Type(), feat->Shape(), trainer_ctx,
                    "task.train_feat_cuda_" + std::to_string(task->key));
  auto train_label =
      Tensor::Empty(label->Type(), label->Shape(), trainer_ctx,
                    "task.train_label_cuda" + std::to_string(task->key));

  trainer_device->CopyDataFromTo(feat->Data(), 0, train_feat->MutableData(), 0,
                                 feat->NumBytes(), CPU(), trainer_ctx,
                                 work_stream);

  trainer_device->CopyDataFromTo(label->Data(), 0, train_label->MutableData(),
                                 0, label->NumBytes(), CPU(), trainer_ctx,
                                 work_stream);
  trainer_device->StreamSync(trainer_ctx, work_stream);

  task->input_feat = train_feat;
  task->output_label = train_label;
}

bool RunCpuSampleLoopOnce() {
  auto graph_pool = CpuEngine::Get()->GetGraphPool();
  if (graph_pool->ExceedThreshold()) {
    std::this_thread::sleep_for(std::chrono::nanoseconds(1000));
    return true;
  }

  Timer t0;
  auto task = DoPermuate();
  if (task) {
    DoCpuSample(task);
    DoFeatureExtract(task);
    DoGraphCopy(task);
    DoFeatureCopy(task);

    graph_pool->AddGraphBatch(task->key, task);

    double sam_time = t0.Passed();
    Profiler::Get()->sample_time[task->key] += sam_time;

    LOG(DEBUG) << "CpuSampleLoop: process task with key " << task->key;
  } else {
    std::this_thread::sleep_for(std::chrono::nanoseconds(1000));
  }

  return true;
}

void CpuSampleLoop() {
  while (RunCpuSampleLoopOnce() && !CpuEngine::Get()->ShouldShutdown()) {
  }
  CpuEngine::Get()->ReportThreadFinish();
}

}  // namespace cpu
}  // namespace common
}  // namespace samgraph