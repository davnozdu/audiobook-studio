import Foundation

public enum VoiceSample {
  public static func signature(text: String, instruction: String, profile: String,
    reference: String = "", seed: Int) throws -> String {
    NativeIO.hash(try NativeIO.json([
      "version": 2, "inference": "qwen-offline-full-text-speaker-required-v1",
      "text": text, "instruction": reference.isEmpty ? instruction : "",
      "profile": profile, "reference": reference, "seed": seed,
    ]))
  }
}
