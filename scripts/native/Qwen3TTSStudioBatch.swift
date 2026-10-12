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
        let completed = texts.indices.filter { stops.finished[$0] && !codes[$0].isEmpty }
        let joinedStreams = completed.map { lane in
            concatenated([reference, stacked(codes[lane], axis: 1)], axis: 1)
        }
        let decoded = try speechTokenizer.studioDecodeBatch(joinedStreams)
        for (lane, audio) in zip(completed, decoded) {
            try Task.checkCancellation()
            guard referenceFrames < audio.dim(0) else {
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

    /// Real tokenizer components with small synthetic parameters/codes: verify
    /// batching, causal right padding, reference removal, final samples and reset
    /// across B=4/B=1/B=2 and several chunk boundaries. No voice weights or speech.
    public static func studioDecoderBatchSelfCheck() throws -> Float {
        let json = """
        {"decode_upsample_rate":8,"decoder_config":{
          "latent_dim":16,"codebook_dim":16,"codebook_size":16,"decoder_dim":32,
          "hidden_size":32,"intermediate_size":64,"num_hidden_layers":2,
          "num_attention_heads":2,"num_key_value_heads":1,"head_dim":16,
          "num_quantizers":4,"num_semantic_quantizers":1,"semantic_codebook_size":16,
          "upsample_rates":[2,2],"upsampling_ratios":[2],"sliding_window":72}}
        """
        let config = try JSONDecoder().decode(Qwen3TTSTokenizerConfig.self, from: Data(json.utf8))
        let tokenizer = Qwen3TTSSpeechTokenizer(config: config)
        let quantizer = tokenizer.decoder.quantizer
        let layers = quantizer.rvqFirst.vq.layers + quantizer.rvqRest.vq.layers
        for (index, layer) in layers.enumerated() {
            let book = layer.codebook, shape = book.embedding_sum.shape
            book.cluster_usage = MLXArray.ones(book.cluster_usage.shape)
            book.embedding_sum = MLXArray((0..<(shape[0] * shape[1])).map {
                Float(0.1 * sin(Double($0 + index * 31) * 0.09))
            }).reshaped(shape)
            book.updateInPlace()
        }
        let lengths = [5, 10, 7, 13] // includes two common reference frames
        let streams = lengths.enumerated().map { lane, length in
            MLXArray((0..<(length * 4)).map { Int32(($0 + lane * 3) % 16) }).reshaped(1, length, 4)
        }
        var maxError: Float = 0, maximumSignal: Float = 0
        for chunk in [3, 5, 300] {
            let batch = try tokenizer.studioDecodeBatch(streams, chunkTokens: chunk)
            for lane in streams.indices {
                // Independent original streaming path, not a second call to the batch helper.
                let single = concatenated(tokenizer.streamingDecode(streams[lane], chunkTokens: chunk), axis: -1)[0]
                eval(single)
                let a = batch[lane].asArray(Float.self), b = single.asArray(Float.self)
                guard a.count == lengths[lane] * 8, a.count == b.count,
                      a.allSatisfy({ $0.isFinite }), b.allSatisfy({ $0.isFinite }) else {
                    throw AudioGenerationError.invalidInput("Batch decoder changed length or produced nonfinite output")
                }
                for (x, y) in zip(a, b) { maxError = max(maxError, abs(x - y)); maximumSignal = max(maximumSignal, abs(y)) }
                let spoken = batch[lane][16...].asArray(Float.self)
                guard spoken.count == (lengths[lane] - 2) * 8, spoken.last == a.last else {
                    throw AudioGenerationError.invalidInput("Batch decoder cut the final sample with the reference")
                }
            }
            let reset = try tokenizer.studioDecodeBatch([streams[2]], chunkTokens: chunk)
            let pair = try tokenizer.studioDecodeBatch([streams[3], streams[0]], chunkTokens: chunk)
            for (a, b) in [(reset[0], batch[2]), (pair[0], batch[3]), (pair[1], batch[0])] {
                let x = a.asArray(Float.self), y = b.asArray(Float.self)
                guard x.count == y.count else { throw AudioGenerationError.invalidInput("Decoder reset lost samples") }
                for (v, w) in zip(x, y) { maxError = max(maxError, abs(v - w)) }
            }
        }
        guard maximumSignal > 0.000001, maxError < 0.0001 else {
            throw AudioGenerationError.invalidInput("Causal batched decoder differs from original streaming path: \(maxError)")
        }
        return maxError
    }
}

extension Qwen3TTSSpeechTokenizer {
    /// One shared decoder execution, never concurrent mutable decoder callers.
    /// Padding codec ID 0 is valid and is appended only AFTER each lane's real
    /// codes. All decoder layers are causal; true lengths, not IDs, crop padding.
    func studioDecodeBatch(_ streams: [MLXArray], chunkTokens: Int = 300) throws -> [MLXArray] {
        if streams.isEmpty { return [] }
        guard (1...4).contains(streams.count), chunkTokens > 0,
              streams.allSatisfy({ $0.ndim == 3 && $0.dim(0) == 1 && $0.dim(1) > 0 && $0.dim(2) == streams[0].dim(2) }) else {
            throw AudioGenerationError.invalidInput("Invalid codec batch shape")
        }
        let lengths = streams.map { $0.dim(1) }, width = lengths.max()!
        let packed = concatenated(streams.map { stream in
            let remaining = width - stream.dim(1)
            if remaining == 0 { return stream }
            return concatenated([stream, MLXArray.zeros([1, remaining, stream.dim(2)], dtype: stream.dtype)], axis: 1)
        }, axis: 0)
        let audio = concatenated(streamingDecode(packed, chunkTokens: chunkTokens), axis: -1)
        eval(audio)
        guard audio.ndim == 2, audio.dim(0) == streams.count, audio.dim(1) == width * decodeUpsampleRate else {
            throw AudioGenerationError.invalidInput("Batch decoder lost codec frames")
        }
        return lengths.enumerated().map { lane, frames in audio[lane, 0..<(frames * decodeUpsampleRate)] }
    }
}
