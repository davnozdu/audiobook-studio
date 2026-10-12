// Audiobook Studio batch ICL. Installed into the pinned MLXAudioTTS module by
// patch_qwen_native.py. Qwen's offline inputs, left padding and per-row EOS are
// preserved; the GPU processes a batch dimension instead of concurrent callers.
import Foundation
@preconcurrency import MLX
import MLXAudioCore
@preconcurrency import MLXLMCommon
import MLXNN

public struct StudioQwenBatchStops {
    public private(set) var finished: [Bool]
    public private(set) var lengths: [Int]
    public init(count: Int) {
        finished = [Bool](repeating: false, count: count)
        lengths = [Int](repeating: 0, count: count)
    }
    public mutating func advance(_ ids: [Int32], eos: Int) -> [Bool] {
        precondition(ids.count == finished.count)
        return ids.indices.map { lane in
            if finished[lane] { return false }
            if Int(ids[lane]) == eos { finished[lane] = true; return false }
            lengths[lane] += 1
            return true
        }
    }
}

public enum StudioQwenBatchLayout {
    public static func positions(lengths: [Int], step: Int = 0) -> MLXArray {
        let width = lengths.max()!
        let values: [Int32] = lengths.flatMap { length in
            step == 0 ? (0..<width).map { Int32(max(0, $0 - (width - length))) }
                : [Int32(length + step - 1)]
        }
        return MLXArray(values).reshaped(lengths.count, step == 0 ? width : 1)
    }

    public static func mask(lengths: [Int], step: Int = 0) -> MLXArray {
        let width = lengths.max()!
        let keyCount = width + step
        let queryCount = step == 0 ? width : 1
        let values: [Float] = lengths.flatMap { length in
            let pad = width - length
            return (0..<queryCount).flatMap { query -> [Float] in
                let position = step == 0 ? query : keyCount - 1
                return (0..<keyCount).map { key in
                    // Padded queries see their own diagonal to avoid an all -inf row
                    // (and NaNs). Real queries can never see these padded keys.
                    let allowed = key <= position && (key >= pad || (position < pad && key == position))
                    return allowed ? Float(0) : -Float.infinity
                }
            }
        }
        return MLXArray(values).reshaped(lengths.count, 1, queryCount, keyCount)
    }

    static func inputs(_ inputs: [MLXArray]) -> MLXArray {
        let width = inputs.map { $0.dim(1) }.max()!
        return concatenated(inputs.map { input in
            let pad = width - input.dim(1)
            if pad == 0 { return input }
            return concatenated([MLXArray.zeros([1, pad, input.dim(2)], dtype: input.dtype), input], axis: 1)
        }, axis: 0)
    }
}

extension Qwen3TTSModel {
    /// One shared conditioning object means one speaker in this batch. Each lane
    /// gets its own random key, repetition history, EOS flag and codec sequence.
    /// nil is an unfinished lane; completed neighbours can still be saved/reused.
    public func studioGenerateBatch(texts: [String], conditioning: Qwen3TTSReferenceConditioning,
        seeds: [UInt64], generationParameters: GenerateParameters,
        timing: ((String, Double) -> Void)? = nil) async throws -> [[Float]?] {
        guard (1...4).contains(texts.count), texts.count == seeds.count,
              texts.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              tokenizer != nil, let speechTokenizer, let talkerConfig = config.talkerConfig,
              conditioning.speakerEmbedding != nil else {
            throw AudioGenerationError.invalidInput("Invalid or unconditioned Qwen batch")
        }
        let maxTokens = generationParameters.maxTokens ?? 4096
        guard maxTokens > 0 else { throw AudioGenerationError.invalidInput("Invalid batch audio token limit") }
        let started = Date()
        let prepared = try texts.map { try prepareICLGenerationInputs(text: $0, conditioning: conditioning) }
        let lengths = prepared.map { $0.0.dim(1) }
        let pad = concatenated(prepared.map { $0.2 }, axis: 0)
        var input = StudioQwenBatchLayout.inputs(prepared.map { $0.0 })
        eval(input, pad)
        timing?("input", Date().timeIntervalSince(started))
        let generationStart = Date()
        var firstStepTime: Double = 0
        let cache = talker.makeCache(), codeCache = talker.codePredictor.makeCache()
        var keys = seeds.map { MLX.key($0) }
        var histories = [[Int]](repeating: [], count: texts.count)
        var codes = [[MLXArray]](repeating: [], count: texts.count)
        var stops = StudioQwenBatchStops(count: texts.count)
        let eos = talkerConfig.codecEosTokenId
        let special = (talkerConfig.vocabSize - 1024..<talkerConfig.vocabSize).filter { $0 != eos }

        func sample(_ logits: MLXArray, lane: Int, primary: Bool, step: Int) -> MLXArray {
            if stops.finished[lane] {
                return MLXArray([Int32(primary ? talkerConfig.codecPadId : 0)]).reshaped(1, 1)
            }
            let (nextKey, drawKey) = MLX.split(key: keys[lane])
            keys[lane] = nextKey
            // Official Qwen min_new_tokens=2: EOS is unavailable for the first 2 frames.
            let blocked = primary ? special + (step < 2 ? [eos] : []) : nil
            return sampleToken(logits[lane..<(lane + 1)],
                temperature: generationParameters.temperature,
                topP: generationParameters.topP, topK: generationParameters.topK,
                repetitionPenalty: primary ? (generationParameters.repetitionPenalty ?? 1.05) : 1,
                generatedTokens: primary ? histories[lane] : nil,
                suppressTokens: blocked, eosTokenId: primary ? eos : nil,
                minP: generationParameters.minP, randomKey: drawKey)
        }

        for step in 0..<maxTokens {
            try Task.checkCancellation()
            let (logits, hidden) = talker(input,
                positionIds: StudioQwenBatchLayout.positions(lengths: lengths, step: step),
                mask: StudioQwenBatchLayout.mask(lengths: lengths, step: step).asType(input.dtype), cache: cache)
            let nextToken = concatenated(texts.indices.map { sample(logits, lane: $0, primary: true, step: step) }, axis: 0)
            var codeTokens = [nextToken]
            let codeHidden = hidden[0..., (-1)..., 0...]
            for item in codeCache { _ = item.trim(item.offset) }
            for group in 0..<(talkerConfig.numCodeGroups - 1) {
                let codeInput = group == 0
                    ? concatenated([codeHidden, talker.getInputEmbeddings()(nextToken)], axis: 1)
                    : talker.codePredictor.codecEmbedding[group - 1](codeTokens.last!)
                let (predicted, _, _) = talker.codePredictor(codeInput, cache: codeCache, generationStep: group)
                codeTokens.append(concatenated(texts.indices.map {
                    sample(predicted, lane: $0, primary: false, step: step)
                }, axis: 0))
            }
            let frame = concatenated(codeTokens, axis: 1)
            var embedding = talker.getInputEmbeddings()(nextToken)
            for (i, token) in codeTokens.dropFirst().enumerated() {
                embedding = embedding + talker.codePredictor.codecEmbedding[i](token)
            }
            input = pad + embedding
            eval(input, frame, nextToken)
            if step == 0 { firstStepTime = Date().timeIntervalSince(generationStart) }
            let ids = nextToken.asArray(Int32.self)
            let accept = stops.advance(ids, eos: eos)
            for lane in texts.indices where accept[lane] {
                histories[lane].append(Int(ids[lane]))
                codes[lane].append(frame[lane..<(lane + 1)])
            }
            if stops.finished.allSatisfy({ $0 }) { break }
        }
        timing?("first_step", firstStepTime)
        timing?("remaining_tokens", max(0, Date().timeIntervalSince(generationStart) - firstStepTime))
        try Task.checkCancellation()
        let decodeStart = Date()
        let reference = conditioning.referenceSpeechCodes.transposed(0, 2, 1)
        let referenceFrames = reference.dim(1) * speechTokenizer.decodeUpsampleRate
        var output = [[Float]?](repeating: nil, count: texts.count)
        for lane in texts.indices where stops.finished[lane] && !codes[lane].isEmpty {
            try Task.checkCancellation()
            let target = stacked(codes[lane], axis: 1)
            let joined = concatenated([reference, target], axis: 1)
            let audio = decodeChunk(joined)
            let expected = joined.dim(1) * speechTokenizer.decodeUpsampleRate
            guard audio.dim(0) == expected, referenceFrames < expected else {
                throw AudioGenerationError.invalidInput("Qwen batch decoder lost codec frames in lane \(lane)")
            }
            let spoken = audio[referenceFrames...]
            eval(spoken)
            output[lane] = spoken.asArray(Float.self)
        }
        timing?("decode", Date().timeIntervalSince(decodeStart))
        return output
    }

    /// Numerical checks only: tiny randomly initialized transformer components,
    /// no checkpoint loading, no speech generation. Exercise B=4, unequal lengths,
    /// cached continuation positions, all codebooks and independent random keys.
    public static func studioBatchSelfCheck() throws -> Float {
        var stops = StudioQwenBatchStops(count: 4)
        for ids: [Int32] in [[31, 0, 2, 3], [31, 31, 0, 4], [31, 31, 31, 0], [31, 31, 31, 31]] {
            _ = stops.advance(ids, eos: 31)
        }
        guard stops.lengths == [0, 1, 2, 3], stops.finished.allSatisfy({ $0 }) else {
            throw AudioGenerationError.invalidInput("Batch EOS discarded or appended another lane's frames")
        }
        let json = """
        {"hidden_size":32,"intermediate_size":64,"num_hidden_layers":2,
         "num_attention_heads":2,"num_key_value_heads":1,"head_dim":16,
         "vocab_size":32,"text_hidden_size":32,"text_vocab_size":32,
         "num_code_groups":4,"codec_eos_token_id":31,
         "code_predictor_config":{"hidden_size":32,"intermediate_size":64,
           "num_hidden_layers":2,"num_attention_heads":2,"num_key_value_heads":1,
           "head_dim":16,"vocab_size":32,"num_code_groups":4}}
        """
        let config = try JSONDecoder().decode(Qwen3TTSTalkerConfig.self, from: Data(json.utf8))
        let model = Qwen3TTSTalkerForConditionalGeneration(config: config)
        let lengths = [2, 5, 3, 4]
        let inputs = lengths.enumerated().map { lane, count in
            MLXArray((0..<(count * 32)).map { Float(sin(Double($0 + lane * 19) * 0.07)) })
                .reshaped(1, count, 32)
        }
        let batchCache = model.makeCache()
        let singleCaches = lengths.map { _ in model.makeCache() }
        let initial = model(StudioQwenBatchLayout.inputs(inputs),
            positionIds: StudioQwenBatchLayout.positions(lengths: lengths),
            mask: StudioQwenBatchLayout.mask(lengths: lengths), cache: batchCache).0
        var maxError: Float = 0
        func compare(_ a: MLXArray, _ b: MLXArray) throws {
            let lhs = a.asArray(Float.self), rhs = b.asArray(Float.self)
            guard lhs.count == rhs.count, lhs.allSatisfy({ $0.isFinite }), rhs.allSatisfy({ $0.isFinite }) else {
                throw AudioGenerationError.invalidInput("Batch self-check has wrong shapes or nonfinite output")
            }
            for (x, y) in zip(lhs, rhs) { maxError = max(maxError, abs(x - y)) }
        }
        for lane in lengths.indices {
            let single = model(inputs[lane], cache: singleCaches[lane]).0
            try compare(initial[lane, (-1), 0...], single[0, (-1), 0...])
        }
        for step in 1...3 {
            let next = lengths.indices.map { lane in inputs[lane][0..., 0..<1, 0...] * Float(step + 1) }
            let actual = model(concatenated(next, axis: 0),
                positionIds: StudioQwenBatchLayout.positions(lengths: lengths, step: step),
                mask: StudioQwenBatchLayout.mask(lengths: lengths, step: step), cache: batchCache).0
            for lane in lengths.indices {
                try compare(actual[lane..<(lane + 1)], model(next[lane], cache: singleCaches[lane]).0)
            }
        }
        let cp = model.codePredictor
        let cpBatchCache = cp.makeCache(), cpSingleCaches = lengths.map { _ in cp.makeCache() }
        for group in 0..<3 {
            let next = inputs.map { $0[0..., 0..<(group == 0 ? 2 : 1), 0...] }
            let actual = cp(concatenated(next, axis: 0), cache: cpBatchCache, generationStep: group).0
            for lane in lengths.indices {
                try compare(actual[lane..<(lane + 1)], cp(next[lane], cache: cpSingleCaches[lane], generationStep: group).0)
            }
        }
        // Compare separate draws with the same lane keys in a different scheduling order.
        let logits = MLXArray([Float(0.2), 0.7, -0.1, 0.4])
        let a = lengths.indices.map { MLX.categorical(logits, key: MLX.key(UInt64(100 + $0))).item(Int32.self) }
        let b = lengths.indices.reversed().map { MLX.categorical(logits, key: MLX.key(UInt64(100 + $0))).item(Int32.self) }.reversed()
        guard a == Array(b), maxError < 0.002 else {
            throw AudioGenerationError.invalidInput("Qwen batch differs from independent numerical execution: \(maxError)")
        }
        return maxError
    }
}
