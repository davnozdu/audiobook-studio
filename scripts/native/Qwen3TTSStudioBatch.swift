// Audiobook Studio batch ICL. Installed into the pinned MLXAudioTTS module by
// patch_qwen_native.py. Qwen's offline inputs, left padding and per-row EOS are
// preserved; the GPU processes a batch dimension instead of concurrent callers.
import Foundation
@preconcurrency import MLX
import MLXAudioCore
@preconcurrency import MLXLMCommon
import MLXNN

/// Gentle mode of the app: after every generation step the GPU rests for this share of the
/// step, so the screen and other apps get it in between. Set while running by the engine.
public enum StudioPace {
    nonisolated(unsafe) public static var gentle = false
    public static let share = 0.35
    /// Least EOS probability that ends a line before its generous length estimate is reached.
    public static let eosConfidence = 0.5
}

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

/// Per-voice ICL pieces that do not depend on the target text. Built once per
/// character; each line then only embeds its own text tokens.
public final class StudioQwenSpeaker: @unchecked Sendable {
    public let conditioning: Qwen3TTSModel.Qwen3TTSReferenceConditioning
    let referenceText: MLXArray, referenceCodec: MLXArray, prefix: MLXArray
    let ttsEos: MLXArray, ttsPad: MLXArray, codecPad: MLXArray
    /// Last reference frames used as decoder context, [1, frames, codebooks].
    let decoderContext: MLXArray
    init(conditioning: Qwen3TTSModel.Qwen3TTSReferenceConditioning, referenceText: MLXArray,
         referenceCodec: MLXArray, prefix: MLXArray, ttsEos: MLXArray, ttsPad: MLXArray,
         codecPad: MLXArray, decoderContext: MLXArray) {
        self.conditioning = conditioning; self.referenceText = referenceText
        self.referenceCodec = referenceCodec; self.prefix = prefix
        self.ttsEos = ttsEos; self.ttsPad = ttsPad; self.codecPad = codecPad
        self.decoderContext = decoderContext
    }
}

/// Vectorised token choice for all lanes at once: same steps as Qwen3TTSModel.sampleToken
/// (suppression, repetition penalty, EOS-preserving top-k, temperature) on [batch, vocab].
public enum StudioQwenSampler {
    /// [1, vocab] additive mask: 0 for allowed tokens, -inf for suppressed ones.
    public static func suppression(vocab: Int, tokens: [Int]) -> MLXArray {
        var values = [Float](repeating: 0, count: vocab)
        for token in tokens where (0..<vocab).contains(token) { values[token] = -Float.infinity }
        return MLXArray(values).reshaped(1, vocab)
    }

    /// Gumbel noise [batch, vocab] from each lane's own seed, the step and the code group
    /// (lowbias32 hash, computed on the GPU for all lanes at once): a lane draws the same numbers
    /// whatever its batch neighbours are, so a line's result does not depend on batch composition.
    public static func gumbel(seeds: MLXArray, step: Int, group: Int, vocab: Int) -> MLXArray {
        let index = MLXArray(UInt32(0) ..< UInt32(vocab)).reshaped(1, vocab)
        let salt = UInt32(truncatingIfNeeded: step &* 0x85EB_CA77) &+ UInt32(truncatingIfNeeded: (group + 1) &* 0xC2B2_AE3D)
        var x = seeds * UInt32(0x9E37_79B1) + index + MLXArray(salt)
        x = x ^ (x >> UInt32(16)); x = x * UInt32(0x7FEB_352D)
        x = x ^ (x >> UInt32(15)); x = x * UInt32(0x846C_A68B)
        x = x ^ (x >> UInt32(16))
        // The top 24-bit value lands on 1 - 2^-25, which Float32 rounds to exactly 1.0 (noise +inf,
        // and NaN on a filtered -inf score). Clamp to the largest Float below 1: only that one value
        // changes, every other draw stays identical to the cached results.
        let uniform = MLX.minimum((x >> UInt32(8)).asType(.float32) * Float(1.0 / 16_777_216) + Float(1.0 / 33_554_432),
                                  MLXArray(Float(1) - Float(1.0 / 16_777_216)))
        return -MLX.log(-MLX.log(uniform))
    }
    /// Per-lane seeds as a [batch, 1] UInt32 array for `gumbel`.
    public static func laneSeeds(_ seeds: [UInt64]) -> MLXArray {
        MLXArray(seeds.map { UInt32(truncatingIfNeeded: $0 ^ ($0 >> 32)) }).reshaped(seeds.count, 1)
    }

    /// logits [batch, time, vocab] -> tokens [batch, 1] (Int32). Finished lanes get `fill`.
    /// Sampling is Gumbel-max over the filtered scores, i.e. categorical(scores / temperature).
    public static func sample(_ logits: MLXArray, finished: MLXArray, fill: Int32,
        temperature: Float, topK: Int, suppress: MLXArray? = nil,
        seen: MLXArray? = nil, repetitionPenalty: Float = 1, eos: Int? = nil,
        eosGate: MLXArray? = nil,
        seeds: MLXArray, step: Int, group: Int) -> MLXArray {
        var scores = logits[0..., (-1)..., 0...].squeezed(axis: 1).asType(.float32)
        let batch = scores.dim(0), vocab = scores.dim(1)
        if let suppress { scores = scores + suppress }
        if let seen, repetitionPenalty != 1 {
            let penalised = which(scores .< 0, scores * repetitionPenalty, scores / repetitionPenalty)
            scores = which(seen .> 0, penalised, scores)
        }
        var tokens: MLXArray
        if temperature <= 0 {
            tokens = argMax(scores, axis: -1)
        } else {
            // Keep the EOS logit out of top-k so the utterance can always finish.
            var eosLogit = eos.map { scores[0..., $0 ..< ($0 + 1)] }
            // Gated lanes may end only when the model is sure (EOS above half the probability):
            // a chance EOS while the last word is still being said would swallow its ending.
            if let gate = eosGate, let eos, let current = eosLogit {
                let probability = softmax(scores / temperature, axis: -1)[0..., eos ..< (eos + 1)]
                let block = gate.reshaped(batch, 1) .&& (probability .< Float(StudioPace.eosConfidence))
                eosLogit = which(block, MLXArray(-Float.infinity), current)
            }
            if topK > 0, topK < vocab {
                let dropped = argPartition(-scores, kth: topK - 1, axis: -1)[0..., topK...]
                scores = putAlong(scores, dropped, values: MLXArray.full(dropped.shape,
                    values: MLXArray(-Float.infinity), dtype: .float32), axis: -1)
            }
            if let eos, let eosLogit {
                let isEOS = MLXArray(0 ..< Int32(vocab)).reshaped(1, vocab) .== Int32(eos)
                scores = which(isEOS, eosLogit, scores)
            }
            tokens = argMax(scores / temperature + gumbel(seeds: seeds, step: step, group: group, vocab: vocab), axis: -1)
        }
        tokens = which(finished, MLXArray(fill), tokens.asType(.int32))
        return tokens.reshaped(batch, 1)
    }

    /// Mark accepted primary tokens (not EOS, lane still open) for the repetition penalty.
    public static func remember(_ seen: MLXArray, tokens: MLXArray, finished: MLXArray, eos: Int) -> MLXArray {
        let vocab = seen.dim(1)
        let accepted = logicalNot(finished) .&& (tokens.reshaped(-1) .!= Int32(eos))
        let hit = (MLXArray(0 ..< Int32(vocab)).reshaped(1, vocab) .== tokens.reshaped(-1, 1))
            .&& accepted.reshaped(-1, 1)
        return maximum(seen, hit.asType(.float32))
    }
}

extension Qwen3TTSModel {
    /// Official decoder chunk overlap (chunked_decode left_context_size=25 frames).
    public static let studioDecoderContextFrames = 25

    public func studioSpeaker(_ conditioning: Qwen3TTSReferenceConditioning) throws -> StudioQwenSpeaker {
        guard let talkerConfig = config.talkerConfig, conditioning.speakerEmbedding != nil else {
            throw AudioGenerationError.invalidInput("Unconditioned Qwen voice")
        }
        let ttsTokens = MLXArray([Int32(config.ttsBosTokenId), Int32(config.ttsEosTokenId),
            Int32(config.ttsPadTokenId)]).reshaped(1, 3)
        let ttsEmbeds = talker.textProjection(talker.getTextEmbeddings()(ttsTokens))
        let ttsBos = ttsEmbeds[0..., 0 ..< 1, 0...], ttsEos = ttsEmbeds[0..., 1 ..< 2, 0...]
        let ttsPad = ttsEmbeds[0..., 2 ..< 3, 0...]
        let referenceText = talker.textProjection(talker.getTextEmbeddings()(conditioning.referenceTextTokenIDs))
        // Same as the upstream private codecEmbedIcl.
        let refCodes = conditioning.referenceSpeechCodes
        var refCodec = talker.getInputEmbeddings()(refCodes[0..., 0, 0...])
        for i in 0 ..< max(0, talkerConfig.numCodeGroups - 1) where i + 1 < refCodes.dim(1) {
            refCodec = refCodec + talker.codePredictor.codecEmbedding[i](refCodes[0..., i + 1, 0...])
        }
        let codecBos = talker.getInputEmbeddings()(MLXArray([Int32(talkerConfig.codecBosId)]).reshaped(1, 1))
        refCodec = concatenated([codecBos, refCodec], axis: 1)
        let referenceCodec = refCodec + broadcast(ttsPad, to: [1, refCodec.dim(1), ttsPad.dim(-1)])
        let codecPad = talker.getInputEmbeddings()(MLXArray([Int32(talkerConfig.codecPadId)]).reshaped(1, 1))
        let prefill: [Int32] = if let language = conditioning.codecLanguageID {
            [Int32(talkerConfig.codecThinkId), Int32(talkerConfig.codecThinkBosId), Int32(language), Int32(talkerConfig.codecThinkEosId)]
        } else {
            [Int32(talkerConfig.codecNothinkId), Int32(talkerConfig.codecThinkBosId), Int32(talkerConfig.codecThinkEosId)]
        }
        var codecPrefix = talker.getInputEmbeddings()(MLXArray(prefill).reshaped(1, -1))
        let codecSuffix = talker.getInputEmbeddings()(
            MLXArray([Int32(talkerConfig.codecPadId), Int32(talkerConfig.codecBosId)]).reshaped(1, 2))
        let speaker = conditioning.speakerEmbedding!.asType(codecPrefix.dtype).reshaped(1, 1, -1)
        codecPrefix = concatenated([codecPrefix, speaker, codecSuffix], axis: 1)
        let padCount = codecPrefix.dim(1) - 2
        var prefix = concatenated([broadcast(ttsPad, to: [1, padCount, ttsPad.dim(-1)]), ttsBos], axis: 1)
        prefix = prefix + codecPrefix[0..., 0 ..< (codecPrefix.dim(1) - 1), 0...]
        let reference = refCodes.transposed(0, 2, 1)
        let context = min(Self.studioDecoderContextFrames, reference.dim(1))
        let decoderContext = reference[0..., (reference.dim(1) - context)..., 0...]
        eval(referenceText, referenceCodec, prefix, ttsEos, ttsPad, codecPad, decoderContext)
        return StudioQwenSpeaker(conditioning: conditioning, referenceText: referenceText,
            referenceCodec: referenceCodec, prefix: prefix, ttsEos: ttsEos, ttsPad: ttsPad,
            codecPad: codecPad, decoderContext: decoderContext)
    }

    /// Cosine of a take's speaker embedding with its voice sample's (the encoder the model reads
    /// the sample with); nil under 1.5 s, where the fingerprint is unreliable.
    public func studioSpeakerSimilarity(_ audio: [Float], to speaker: StudioQwenSpeaker) -> Double? {
        guard audio.count >= 36_000, let reference = speaker.conditioning.speakerEmbedding,
              let take = extractSpeakerEmbedding(MLXArray(audio)) else { return nil }
        let a = take.asType(.float32).reshaped(-1).asArray(Float.self)
        let b = reference.asType(.float32).reshaped(-1).asArray(Float.self)
        guard a.count == b.count, !a.isEmpty else { return nil }
        var dot = 0.0, na = 0.0, nb = 0.0
        for (x, y) in zip(a, b) { dot += Double(x) * Double(y); na += Double(x) * Double(x); nb += Double(y) * Double(y) }
        return dot / max((na * nb).squareRoot(), 1e-12)
    }

    /// Offline ICL layout identical to prepareICLGenerationInputs, reusing cached voice pieces.
    func studioInput(text: String, speaker: StudioQwenSpeaker) throws -> MLXArray {
        guard let tokenizer else { throw AudioGenerationError.modelNotInitialized("Text tokenizer not loaded") }
        let chat = "<|im_start|>assistant\n\(text)<|im_end|>\n<|im_start|>assistant\n"
        let ids = MLXArray(tokenizer.encode(text: chat).map { Int32($0) }).reshaped(1, -1)
        let count = ids.dim(1), start = min(3, count), end = max(start, count - 5)
        let embed = { (tokens: MLXArray) in self.talker.textProjection(self.talker.getTextEmbeddings()(tokens)) }
        let textEmbed = concatenated([speaker.referenceText, embed(ids[0..., start ..< end]), speaker.ttsEos], axis: 1)
        let textWithPad = textEmbed + broadcast(speaker.codecPad, to: [1, textEmbed.dim(1), speaker.codecPad.dim(-1)])
        return concatenated([embed(ids[0..., 0 ..< 3]), speaker.prefix, textWithPad, speaker.referenceCodec], axis: 1)
    }

    /// Each lane has its own voice, text, EOS flag and codec sequence; the GPU runs one
    /// batch dimension. nil is an unfinished lane; completed neighbours stay usable.
    public func studioGenerateBatch(texts: [String], speakers: [StudioQwenSpeaker],
        seeds: [UInt64], generationParameters: GenerateParameters,
        timing: ((String, Double) -> Void)? = nil,
        uncertainEnd: ((Int) -> Void)? = nil) async throws -> [[Float]?] {
        guard (1...4).contains(texts.count), texts.count == seeds.count, texts.count == speakers.count,
              texts.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              tokenizer != nil, speechTokenizer != nil, let talkerConfig = config.talkerConfig else {
            throw AudioGenerationError.invalidInput("Invalid or unconditioned Qwen batch")
        }
        let parameters = generationParameters
        guard parameters.topP >= 1, parameters.minP <= 0 else {
            throw AudioGenerationError.invalidInput("Batch sampler supports top-k and temperature only")
        }
        let maxTokens = parameters.maxTokens ?? 4096
        guard maxTokens > 0 else { throw AudioGenerationError.invalidInput("Invalid batch audio token limit") }
        let started = Date()
        let prepared = try zip(texts, speakers).map { try studioInput(text: $0, speaker: $1) }
        let lengths = prepared.map { $0.dim(1) }
        let pad = concatenated(speakers.map { $0.ttsPad }, axis: 0)
        var input = StudioQwenBatchLayout.inputs(prepared)
        eval(input, pad)
        timing?("input", Date().timeIntervalSince(started))

        let lanes = texts.count, eos = talkerConfig.codecEosTokenId
        let vocab = talkerConfig.vocabSize
        let special = (vocab - 1024 ..< vocab).filter { $0 != eos }
        let suppressMain = StudioQwenSampler.suppression(vocab: vocab, tokens: special)
        let suppressEarly = StudioQwenSampler.suppression(vocab: vocab, tokens: special + [eos])
        let cache = talker.makeCache(), codeCache = talker.codePredictor.makeCache()
        let laneSeeds = StudioQwenSampler.laneSeeds(seeds)
        var finished = MLXArray.zeros([lanes], type: Bool.self)
        var seen = MLXArray.zeros([lanes, vocab], type: Float.self)
        var codes = [[MLXArray]](repeating: [], count: lanes)
        var stops = StudioQwenBatchStops(count: lanes)
        // A generous length per lane (2.5 frames per character, slow voices included): before it,
        // a line may end only on a confident EOS; past it, as before, so nothing runs on forever.
        let eosCaps = texts.map { $0.count * 5 / 2 + 24 }
        let generationStart = Date()
        var firstStepTime: Double = 0

        // Read one step's tokens on the CPU; true when every lane has finished.
        func collect(_ token: MLXArray, _ frame: MLXArray, step: Int) -> Bool {
            let ids = token.asArray(Int32.self)
            if step == 0 { firstStepTime = Date().timeIntervalSince(generationStart) }
            let accept = stops.advance(ids, eos: eos)
            for lane in 0 ..< lanes where accept[lane] {
                codes[lane].append(frame[lane ..< (lane + 1)])
            }
            return stops.finished.allSatisfy { $0 }
        }

        // The next step is queued on the GPU before the previous step's tokens are read,
        // so CPU bookkeeping overlaps model work. Lane state lives on the GPU.
        var waiting: (token: MLXArray, frame: MLXArray, step: Int)?
        var done = false
        var stepClock = Date()
        for step in 0 ..< maxTokens {
            try Task.checkCancellation()
            let (logits, hidden) = talker(input,
                positionIds: StudioQwenBatchLayout.positions(lengths: lengths, step: step),
                mask: StudioQwenBatchLayout.mask(lengths: lengths, step: step).asType(input.dtype), cache: cache)
            let nextToken = StudioQwenSampler.sample(logits, finished: finished, fill: Int32(talkerConfig.codecPadId),
                temperature: parameters.temperature, topK: parameters.topK,
                suppress: step < 2 ? suppressEarly : suppressMain, seen: seen,
                repetitionPenalty: parameters.repetitionPenalty ?? 1.05, eos: eos,
                eosGate: MLXArray(eosCaps.map { step < $0 }), seeds: laneSeeds, step: step, group: 0)
            var codeTokens = [nextToken]
            let codeHidden = hidden[0..., (-1)..., 0...]
            for item in codeCache { _ = item.trim(item.offset) }
            for group in 0 ..< (talkerConfig.numCodeGroups - 1) {
                let codeInput = group == 0
                    ? concatenated([codeHidden, talker.getInputEmbeddings()(nextToken)], axis: 1)
                    : talker.codePredictor.codecEmbedding[group - 1](codeTokens.last!)
                let (predicted, _, _) = talker.codePredictor(codeInput, cache: codeCache, generationStep: group)
                codeTokens.append(StudioQwenSampler.sample(predicted, finished: finished, fill: 0,
                    temperature: parameters.temperature, topK: parameters.topK, seeds: laneSeeds, step: step, group: group + 1))
            }
            let frame = concatenated(codeTokens, axis: 1)
            var embedding = talker.getInputEmbeddings()(nextToken)
            for (i, token) in codeTokens.dropFirst().enumerated() {
                embedding = embedding + talker.codePredictor.codecEmbedding[i](token)
            }
            input = pad + embedding
            seen = StudioQwenSampler.remember(seen, tokens: nextToken, finished: finished, eos: eos)
            finished = finished .|| (nextToken.reshaped(-1) .== Int32(eos))
            asyncEval(input, frame, nextToken, seen, finished)
            if let previous = waiting, collect(previous.token, previous.frame, step: previous.step) {
                done = true; break
            }
            waiting = (nextToken, frame, step)
            if StudioPace.gentle {
                // The queued step must finish first, or the GPU would keep working through the pause.
                eval(nextToken)
                try await Task.sleep(nanoseconds: UInt64(min(0.25, Date().timeIntervalSince(stepClock) * StudioPace.share) * 1_000_000_000))
            }
            stepClock = Date()
        }
        if !done, let previous = waiting { _ = collect(previous.token, previous.frame, step: previous.step) }
        // Lines that reached the generous length without a confident end are worth a listen.
        for lane in 0 ..< lanes where stops.lengths[lane] >= eosCaps[lane] { uncertainEnd?(lane) }
        timing?("first_step", firstStepTime)
        timing?("remaining_tokens", max(0, Date().timeIntervalSince(generationStart) - firstStepTime))
        try Task.checkCancellation()

        let decodeStart = Date()
        let upsample = speechTokenizer!.decodeUpsampleRate
        var output = [[Float]?](repeating: nil, count: lanes)
        for lane in 0 ..< lanes where stops.finished[lane] && !codes[lane].isEmpty {
            try Task.checkCancellation()
            // Decode with a short reference tail as left context, then drop it.
            let context = speakers[lane].decoderContext
            let joined = concatenated([context, stacked(codes[lane], axis: 1)], axis: 1)
            let audio = decodeChunk(joined)
            let contextFrames = context.dim(1) * upsample, expected = joined.dim(1) * upsample
            guard audio.dim(0) == expected, contextFrames < expected else {
                throw AudioGenerationError.invalidInput("Qwen batch decoder lost codec frames in lane \(lane)")
            }
            let spoken = audio[contextFrames...]
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
        // Vectorised sampler: suppression, repetition penalty and finished lanes per row.
        let rows = MLXArray([Float(0.1), 3.0, 0.2, 2.9, 0.0, 0.0,
                             Float(2.0), 0.1, 1.95, 0.0, 0.0, 0.0,
                             Float(0.0), 0.0, 0.0, 0.0, 5.0, 0.0]).reshaped(3, 1, 6)
        let seenRows = MLXArray([Float](repeating: 0, count: 6) + [1, 0, 0, 0, 0, 0] + [Float](repeating: 0, count: 6)).reshaped(3, 6)
        let picked = StudioQwenSampler.sample(rows, finished: MLXArray([false, false, true]), fill: 9,
            temperature: 0, topK: 0, suppress: StudioQwenSampler.suppression(vocab: 6, tokens: [1]),
            seen: seenRows, repetitionPenalty: 1.05, seeds: StudioQwenSampler.laneSeeds([1, 2, 3]), step: 0, group: 0).asArray(Int32.self)
        let sampled = StudioQwenSampler.sample(rows, finished: MLXArray([false, false, false]), fill: 9,
            temperature: 0.01, topK: 1, seeds: StudioQwenSampler.laneSeeds([1, 2, 3]), step: 0, group: 0).asArray(Int32.self)
        // A lane's draw depends only on its own seed: swapping or dropping neighbours changes nothing.
        let flat = MLXArray.zeros([2, 1, 64], type: Float.self)
        let ab = StudioQwenSampler.sample(flat, finished: MLXArray([false, false]), fill: 0, temperature: 1, topK: 0,
            seeds: StudioQwenSampler.laneSeeds([11, 22]), step: 5, group: 3).asArray(Int32.self)
        let ba = StudioQwenSampler.sample(flat, finished: MLXArray([false, false]), fill: 0, temperature: 1, topK: 0,
            seeds: StudioQwenSampler.laneSeeds([22, 11]), step: 5, group: 3).asArray(Int32.self)
        let alone = StudioQwenSampler.sample(flat[0 ..< 1], finished: MLXArray([false]), fill: 0, temperature: 1, topK: 0,
            seeds: StudioQwenSampler.laneSeeds([11]), step: 5, group: 3).asArray(Int32.self)
        let noise = StudioQwenSampler.gumbel(seeds: StudioQwenSampler.laneSeeds([7]), step: 1, group: 0, vocab: 4096).asArray(Float.self)
        // Seed 17001, step 257, group 13 hashes to 0xffffff2b at index 1365: the uniform's upper edge.
        let edge = StudioQwenSampler.gumbel(seeds: StudioQwenSampler.laneSeeds([17001]), step: 257, group: 13, vocab: 2048).asArray(Float.self)
        guard ab == [ba[1], ba[0]], alone == [ab[0]], noise.allSatisfy({ $0.isFinite }), edge.allSatisfy({ $0.isFinite }),
              Set(noise.map { Int($0 * 4) }).count > 8 else {
            throw AudioGenerationError.invalidInput("Qwen batch noise depends on neighbours or is degenerate")
        }
        // An uncertain EOS (about a quarter of the probability) never ends a gated lane; ungated it may.
        let unsure = MLXArray([Float(1.2), 0.2, 0.1, 0.0, 0.0, 1.0]).reshaped(1, 1, 6)
        var gatedEOS = 0, freeEOS = 0
        for seed in 1...32 {
            let laneSeed = StudioQwenSampler.laneSeeds([UInt64(seed)])
            if StudioQwenSampler.sample(unsure, finished: MLXArray([false]), fill: 0, temperature: 1, topK: 0, eos: 5,
                eosGate: MLXArray([true]), seeds: laneSeed, step: 3, group: 0).asArray(Int32.self) == [5] { gatedEOS += 1 }
            if StudioQwenSampler.sample(unsure, finished: MLXArray([false]), fill: 0, temperature: 1, topK: 0, eos: 5,
                eosGate: MLXArray([false]), seeds: laneSeed, step: 3, group: 0).asArray(Int32.self) == [5] { freeEOS += 1 }
        }
        guard gatedEOS == 0, freeEOS > 0 else {
            throw AudioGenerationError.invalidInput("Qwen batch EOS gate: gated \(gatedEOS), free \(freeEOS)")
        }
        let remembered = StudioQwenSampler.remember(MLXArray.zeros([3, 6], type: Float.self),
            tokens: MLXArray([Int32(2), 5, 4]).reshaped(3, 1), finished: MLXArray([false, false, true]), eos: 5)
        guard picked == [3, 2, 9], sampled == [1, 0, 4],
              remembered.asArray(Float.self) == [0, 0, 1, 0, 0, 0] + [Float](repeating: 0, count: 12) else {
            throw AudioGenerationError.invalidInput("Qwen batch sampler chose a suppressed, penalised or finished-lane token")
        }
        guard a == Array(b), maxError < 0.002 else {
            throw AudioGenerationError.invalidInput("Qwen batch differs from independent numerical execution: \(maxError)")
        }
        return maxError
    }
}
