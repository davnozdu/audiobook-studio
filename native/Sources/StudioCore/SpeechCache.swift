import Foundation

public enum SpeechCache {
  public static func segmentURL(_ project: URL, id: String) -> URL {
    let compressed = project.appendingPathComponent("audio/segments/" + id + ".spcm")
    return FileManager.default.fileExists(atPath: compressed.path) ? compressed
      : project.appendingPathComponent("audio/segments/" + id + ".wav")
  }
  public static func readAudio(_ file: URL) throws -> [Float] {
    try file.pathExtension == "spcm" ? SpeechPCM.read(file) : NativeWAV.read(file)
  }
  public static func signature(text: String, referenceHash: String, referenceText: String,
    seed: Int) throws -> String {
    NativeIO.hash(try NativeIO.json([
      "version": 7, "inference": "batch-mixed-voices-lane-gumbel-decoder-context25-v1",
      "model": "Qwen3-TTS-12Hz-1.7B-Ru-Stress-CF-source",
      "text": text, "reference_hash": referenceHash, "reference_text": referenceText,
      "seed": seed, "language": "Russian", "max_tokens": 4096,
      "temperature": 0.9, "top_p": 1, "top_k": 50, "repetition_penalty": 1.05,
    ]))
  }
  public static func load(_ file: URL, signature: String) -> [Float]? {
    let meta = file.deletingPathExtension().appendingPathExtension("json")
    guard let saved = try? NativeIO.load(meta),
      NativeIO.string(saved["signature"]) == signature,
      let hash = try? NativeIO.hashFile(file), hash == NativeIO.string(saved["sha256"]),
      let samples = try? readAudio(file), !samples.isEmpty,
      samples.allSatisfy({ $0.isFinite }), samples.contains(where: { abs($0) > 0.00001 })
    else { return nil }
    return samples
  }
  public static func save(_ file: URL, samples: [Float], signature: String) throws {
    if file.pathExtension == "spcm" { try SpeechPCM.write(file, samples: samples) }
    else { try NativeWAV.write(file, samples) }
    try NativeIO.write(file.deletingPathExtension().appendingPathExtension("json"),
      ["signature": signature, "sha256": try NativeIO.hashFile(file)])
  }
}
