// RUAccent's ONNX models for the engine: one JSON request per line on stdin, one answer per line
// on stdout. Request: {"model": "/path/model.onnx", "inputs": {"input_ids": [[…]], …}} with
// rectangular int64 batches; inputs the model does not declare are ignored. Answer: the "logits"
// output (or the first one) as {"shape": […], "data": […]}, or {"error": "…"}. Tokenizing and
// every decision stay in Swift; this program only runs the networks.
#import <Foundation/Foundation.h>
#include <onnxruntime_cxx_api.h>

#include <iostream>
#include <map>
#include <memory>
#include <string>
#include <vector>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        Ort::Env env(ORT_LOGGING_LEVEL_ERROR, "StudioAccent");
        Ort::SessionOptions options;
        options.SetIntraOpNumThreads(4);
        options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
        std::map<std::string, std::unique_ptr<Ort::Session>> sessions;
        Ort::AllocatorWithDefaultOptions allocator;
        Ort::MemoryInfo memory = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
        std::string line;
        while (std::getline(std::cin, line)) {
            @autoreleasepool {
                NSDictionary *answer = nil;
                try {
                    NSData *data = [NSData dataWithBytes:line.data() length:line.size()];
                    NSDictionary *request = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    if (![request isKindOfClass:[NSDictionary class]]) throw std::runtime_error("invalid request");
                    std::string path([request[@"model"] UTF8String] ?: "");
                    auto found = sessions.find(path);
                    if (found == sessions.end()) {
                        found = sessions.emplace(path, std::make_unique<Ort::Session>(env, path.c_str(), options)).first;
                    }
                    Ort::Session &session = *found->second;
                    NSDictionary *inputs = request[@"inputs"];
                    std::vector<std::string> names;
                    std::vector<std::vector<int64_t>> buffers;
                    std::vector<Ort::Value> values;
                    size_t count = session.GetInputCount();
                    buffers.reserve(count);
                    for (size_t i = 0; i < count; ++i) {
                        auto name = session.GetInputNameAllocated(i, allocator);
                        NSArray *rows = inputs[[NSString stringWithUTF8String:name.get()]];
                        if (![rows isKindOfClass:[NSArray class]] || rows.count == 0) {
                            throw std::runtime_error(std::string("missing input ") + name.get());
                        }
                        int64_t width = (int64_t)[rows[0] count];
                        buffers.emplace_back();
                        for (NSArray *row in rows) {
                            if ((int64_t)row.count != width) throw std::runtime_error("ragged input");
                            for (NSNumber *value in row) buffers.back().push_back(value.longLongValue);
                        }
                        std::vector<int64_t> shape = {(int64_t)rows.count, width};
                        values.push_back(Ort::Value::CreateTensor<int64_t>(memory, buffers.back().data(),
                            buffers.back().size(), shape.data(), shape.size()));
                        names.push_back(name.get());
                    }
                    size_t outputs = session.GetOutputCount();
                    size_t chosen = 0;
                    for (size_t i = 0; i < outputs; ++i) {
                        if (std::string(session.GetOutputNameAllocated(i, allocator).get()) == "logits") chosen = i;
                    }
                    std::string outputName = session.GetOutputNameAllocated(chosen, allocator).get();
                    std::vector<const char *> inputNames;
                    for (auto &n : names) inputNames.push_back(n.c_str());
                    const char *outputNames[] = {outputName.c_str()};
                    auto result = session.Run(Ort::RunOptions{nullptr}, inputNames.data(), values.data(),
                        values.size(), outputNames, 1);
                    auto info = result[0].GetTensorTypeAndShapeInfo();
                    auto shape = info.GetShape();
                    const float *raw = result[0].GetTensorData<float>();
                    size_t total = info.GetElementCount();
                    NSMutableArray *flat = [NSMutableArray arrayWithCapacity:total];
                    for (size_t i = 0; i < total; ++i) [flat addObject:@(raw[i])];
                    NSMutableArray *dims = [NSMutableArray array];
                    for (auto d : shape) [dims addObject:@(d)];
                    answer = @{@"shape": dims, @"data": flat};
                } catch (const std::exception &error) {
                    answer = @{@"error": [NSString stringWithUTF8String:error.what()] ?: @"error"};
                }
                NSData *json = [NSJSONSerialization dataWithJSONObject:answer options:0 error:nil];
                std::cout.write((const char *)json.bytes, json.length);
                std::cout << '\n' << std::flush;
            }
        }
    }
    return 0;
}
