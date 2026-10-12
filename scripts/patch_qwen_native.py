"""Apply the audited offline-input fix to the pinned Qwen Swift implementation.

Build tool only; never shipped. Reject changed upstream source instead of silently
patching a different model. See native/patches/README.md for the reference algorithm.
"""
import hashlib
import sys
from pathlib import Path

UPSTREAM_SHA = "e0e4ac8efdfb5f63a9e0afc8339b7b2b2a3ac3afe6d749979342f178a70a5df4"
MARKER = "// Audiobook Studio: official non_streaming_mode=True prefill."
# Earlier audited patch results a cached checkout may still contain.
PREVIOUS_PATCH_SHAS = {
    "0ce467d5d27d75d1f54579f3e2abbb7a792f2bf38d55365a6052700e0585d92c",
    "ccdc11d446514162c90ecef73c8d9a0100eb287d22f066ab72b5626fab486a4f",
    "a3b3a56865590533a010762797129d7f69cc7526f41faec639a36ca26bb09f80",
}


def patched(source):
    def replace(old, new):
        nonlocal source
        if source.count(old) != 1:
            raise ValueError("Pinned Qwen patch anchor changed")
        source = source.replace(old, new)

    replace("    // MARK: - Decode chunk helper\n", """    // Audiobook Studio: zero is a real codec ID; only negative padding is invalid.
    public static func studioDecodedFrameCount(_ firstCodebook: MLXArray, upsampleRate: Int) -> Int {
        Int((firstCodebook .>= 0).sum().item(Int32.self)) * upsampleRate
    }

    // MARK: - Decode chunk helper
""")
    replace("""        let validLen = Int((codes[0..., 0..., 0] .> 0).sum().item(Int32.self))
            * speechTokenizer.decodeUpsampleRate
        if validLen > 0, validLen < audio.dim(0) {
""", """        let validLen = Self.studioDecodedFrameCount(codes[0..., 0..., 0],
            upsampleRate: speechTokenizer.decodeUpsampleRate)
        if validLen < audio.dim(0) {
""")
    replace("                speaker: speaker\n", "                speaker: speaker,\n                nonStreaming: onAudioChunk == nil\n")
    replace("        speaker: String? = nil\n", "        speaker: String? = nil,\n        nonStreaming: Bool = false\n")
    replace("        // Add first text token (index 3) + last codec embed\n", """        // Audiobook Studio: official non_streaming_mode=True prefill.
        // Include every text token + EOS before codec BOS, preserving instruction
        // embeddings and the role/language prefix. Streaming keeps its old layout.
        if nonStreaming {
            let allText = concatenated(
                [textEmbed[0..., 3 ..< (textEmbed.dim(1) - 5), 0...], ttsEosEmbed],
                axis: 1
            )
            let codecPad = talker.getInputEmbeddings()(
                MLXArray([Int32(talkerConfig.codecPadId)]).reshaped(1, 1)
            )
            let textWithPad = allText + broadcast(codecPad, to: allText.shape)
            let codecStart = ttsPadEmbed + codecEmbed[0..., (-1)..., 0...]
            return (concatenated([inputEmbeds, textWithPad, codecStart], axis: 1),
                ttsPadEmbed, ttsPadEmbed)
        }

        // Add first text token (index 3) + last codec embed
""")
    replace("""        // Cap max tokens based on text length
        let targetTokenCount = tokenizer.encode(text: text).count
        let effectiveMaxTokens = min(maxTokens, max(75, targetTokenCount * 6))
""", """        // Honour the caller limit. Slow or expressive speech must not be clipped
        // by a text-token heuristic absent from the official implementation.
        let effectiveMaxTokens = maxTokens
""")
    replace("        var generatedCodebookTokens = [Int]()\n", "        var generatedCodebookTokens = [Int]()\n        var reachedEOS = false\n")
    replace("            if isEOS.item(Bool.self) {\n                break\n", "            if isEOS.item(Bool.self) {\n                reachedEOS = true\n                break\n")
    replace("        // Emit generation info\n", """        guard reachedEOS else {
            throw AudioGenerationError.invalidInput("Qwen reached the audio token limit before finishing the utterance")
        }

        // Emit generation info
""")
    replace("        let refContext = referenceAudioContext(for: refAudio)\n", """        let refContext = referenceAudioContext(for: refAudio)
        guard refContext.speakerEmbedding != nil else {
            throw AudioGenerationError.modelNotInitialized("Voice cloning requires a loaded speaker encoder and speaker embedding")
        }
""")
    replace("            if !speakerWeights.isEmpty {\n", """            guard !speakerWeights.isEmpty else {
                throw AudioGenerationError.modelNotInitialized("Base checkpoint is missing speaker encoder weights")
            }
            if !speakerWeights.isEmpty {
""")
    replace("""            let mel = computeMelSpectrogram(
                audio: waveform,
                sampleRate: speakerEncoder.config.sampleRate,
                nFft: 1024,
                hopLength: 256,
                nMels: 128
            )
""", """            let mel = Self.studioSpeakerMel(audio: waveform,
                sampleRate: speakerEncoder.config.sampleRate)
""")
    replace("    func extractSpeakerEmbedding(_ refAudio: MLXArray) -> MLXArray? {\n", """    // Matches Qwen's mel_spectrogram, not Whisper's log-power normalization.
    public static func studioSpeakerMel(audio: MLXArray, sampleRate: Int = 24000) -> MLXArray {
        precondition(audio.ndim == 1 && audio.dim(0) > 384 && sampleRate == 24000)
        let nFft = 1024, hop = 256, padding = 384
        let count = audio.dim(0)
        let left = audio[MLXArray((1...padding).reversed().map { Int32($0) })]
        let right = audio[MLXArray((count-padding-1 ..< count-1).reversed().map { Int32($0) })]
        let padded = concatenated([left, audio, right])
        let frames = asStrided(padded, [1 + (padded.dim(0) - nFft) / hop, nFft],
            strides: [hop, 1], offset: 0)
        let fft = MLXFFT.rfft(frames * hanningWindow(size: nFft, periodic: true), axis: 1)
        let magnitude = MLX.sqrt(MLX.abs(fft).square() + Float(1e-9))
        let filters = melFilters(sampleRate: sampleRate, nFft: nFft, nMels: 128,
            fMin: 0, fMax: 12000, norm: "slaney", melScale: .slaney)
        return MLX.log(MLX.maximum(MLX.matmul(magnitude, filters), Float(1e-5)))
    }

    func extractSpeakerEmbedding(_ refAudio: MLXArray) -> MLXArray? {
""")
    # The engine keeps a bounded MLX buffer pool and clears it between models; emptying it
    # every 50 tokens forces Metal reallocation (absent from the Python ICL loop).
    replace("""            if step > 0, step % 50 == 0 {
                Memory.clearCache()
            }
""", "")
    replace("        print(\"Got audio ID: '\\(audioID)'\")\n", "")
    replace("            print(\"Returning cached context\")\n", "")
    replace("        let stackedMels = stacked(mels, axis: 0)\n",
        "        let stackedMels = stacked(mels, axis: 0).asType(speakerEncoder.fc.weight.dtype)\n")
    replace("            let speakerEmbed = speakerEmbedding.reshaped(1, 1, -1)\n",
        "            let speakerEmbed = speakerEmbedding.asType(codecPrefixEmbed.dtype).reshaped(1, 1, -1)\n")
    return source


def apply(path):
    source = path.read_text()
    receipt = path.with_suffix(".studio-original")
    if MARKER in source:
        original = receipt.read_text() if receipt.exists() else ""
        if hashlib.sha256(original.encode()).hexdigest() != UPSTREAM_SHA:
            raise ValueError("Previously patched Qwen source failed verification")
        result = patched(original)
        if result != source:
            if hashlib.sha256(source.encode()).hexdigest() not in PREVIOUS_PATCH_SHAS:
                raise ValueError("Previously patched Qwen source failed verification")
            path.chmod(path.stat().st_mode | 0o200)
            path.write_text(result)
        return
    if hashlib.sha256(source.encode()).hexdigest() != UPSTREAM_SHA:
        raise ValueError("Unexpected Qwen Swift source; audit the new revision before building")
    result = patched(source)
    path.chmod(path.stat().st_mode | 0o200)
    receipt.write_text(source)
    path.write_text(result)


if __name__ == "__main__":
    directory = Path(sys.argv[1]) / "Sources/MLXAudioTTS/Models/Qwen3TTS"
    apply(directory / "Qwen3TTS.swift")
    tokenizer = directory / "Qwen3TTSSpeechTokenizer.swift"
    source = tokenizer.read_text()
    original_sha = "e4569db0be3c6c41eb7a4a5a9feb3b73ce89a8d8b7bb704d9a5cb1c3aca4d695"
    old = "(audioCodes[0..., 0..., 0] .> 0)"
    new = "(audioCodes[0..., 0..., 0] .>= 0)"
    original = source.replace(new, old)
    if hashlib.sha256(original.encode()).hexdigest() != original_sha or original.count(old) != 1:
        raise ValueError("Unexpected Qwen speech tokenizer source; audit the new revision before building")
    result = original.replace(old, new)
    if source != result:
        tokenizer.chmod(tokenizer.stat().st_mode | 0o200)
        tokenizer.write_text(result)
    print("Qwen Swift: verified offline input, speaker identity, codec-zero length and audio limit fixes")
