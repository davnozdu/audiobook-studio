import Foundation

public enum VoiceSample {
  public static func signature(text: String, instruction: String, profile: String,
    reference: String = "", seed: Int) throws -> String {
    NativeIO.hash(try NativeIO.json([
      "version": 4, "inference": "qwen-offline-codec-zero-full-length-v3",
      "text": text, "instruction": reference.isEmpty ? instruction : "",
      "profile": profile, "reference": reference, "seed": seed,
    ]))
  }
}
