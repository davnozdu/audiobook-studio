#import <Foundation/Foundation.h>
#include <torch/script.h>
#include <ATen/Parallel.h>

#include <iostream>
#include <string>
#include <vector>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        try {
            at::set_num_threads(1); torch::NoGradGuard no_grad;
            std::string root(argv[1]);
            auto accentor = torch::jit::load(root + "/accentor.jit", torch::kCPU);
            auto homo = torch::jit::load(root + "/homosolver.jit", torch::kCPU);
            std::string line;
            while (std::getline(std::cin, line)) {
                @autoreleasepool {
                    NSData *data = [NSData dataWithBytes:line.data() length:line.size()];
                    NSError *error = nil;
                    NSDictionary *request = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
                    if (!request) throw std::runtime_error("Invalid stress request");
                    NSArray *words = request[@"words"];
                    c10::List<std::string> input;
                    for (NSString *word in words) input.push_back(std::string([word UTF8String]));
                    NSMutableArray *stress = [NSMutableArray array];
                    if (input.size()) {
                        auto outputs = accentor.forward({input}).toTuple()->elements();
                        auto probs = outputs[0].toTensor().softmax(1);
                        auto indices = probs.argmax(1);
                        // Second output: which 'е' (1-based, 0 = none) is really 'ё'.
                        bool hasYo = outputs.size() > 1;
                        torch::Tensor yoProbs, yoIndices;
                        if (hasYo) { yoProbs = outputs[1].toTensor().softmax(1); yoIndices = yoProbs.argmax(1); }
                        for (int64_t i=0; i<indices.size(0); ++i) {
                            auto index = indices[i].item<int64_t>();
                            NSMutableDictionary *row = [@{@"vowel": @(index), @"probability": @(probs[i][index].item<double>())} mutableCopy];
                            if (hasYo) {
                                auto yo = yoIndices[i].item<int64_t>();
                                row[@"yo"] = @(yo);
                                row[@"yo_probability"] = @(yoProbs[i][yo].item<double>());
                            }
                            [stress addObject:row];
                        }
                    }
                    NSMutableArray *predictions = [NSMutableArray array];
                    NSMutableArray *confidence = [NSMutableArray array];
                    // Each homograph has its own context window; no padding influences its prediction.
                    for (NSDictionary *item in request[@"homographs"]) {
                        std::vector<int64_t> ids;
                        for (NSNumber *idValue in item[@"tokens"]) ids.push_back([idValue longLongValue]);
                        auto tensor = torch::tensor(ids, torch::TensorOptions().dtype(torch::kInt64)).unsqueeze(0);
                        auto start = torch::tensor({[item[@"start"] longLongValue]}, torch::TensorOptions().dtype(torch::kInt64));
                        auto end = torch::tensor({[item[@"end"] longLongValue]}, torch::TensorOptions().dtype(torch::kInt64));
                        auto logits = homo.forward({tensor, start, end}).toTensor();
                        auto probability = torch::sigmoid(logits).flatten()[0];
                        auto index = torch::round(probability).item<int64_t>();
                        [predictions addObject:@(index)];
                        [confidence addObject:@(probability.item<double>())];
                    }
                    NSDictionary *response = @{@"stress": stress, @"homographs": predictions, @"homograph_probabilities": confidence};
                    NSData *encoded = [NSJSONSerialization dataWithJSONObject:response options:0 error:&error];
                    std::cout.write((const char *)encoded.bytes, encoded.length); std::cout << "\n" << std::flush;
                }
            }
        } catch (const std::exception &error) { std::cerr << error.what() << std::endl; return 1; }
    }
    return 0;
}
