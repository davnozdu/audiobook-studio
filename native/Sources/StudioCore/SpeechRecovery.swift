import Foundation

public enum SpeechRecovery {
  /// A strong signal continuing to the file boundary is suspicious, not proof of omitted words.
  /// Inspect raw output before trimming. Tiny component fixtures are not real utterances.
  public static func activeTail(_ samples: [Float]) -> Bool {
    guard samples.count >= 2400 else { return false }
    let window = 480 // 20 ms at 24 kHz
    func rms(_ values: ArraySlice<Float>) -> Float {
      sqrt(values.reduce(0) { $0 + $1 * $1 } / Float(values.count))
    }
    let tail = rms(samples.suffix(window))
    guard tail > 0.015 else { return false }
    var peak: Float = 0
    for start in stride(from: 0, to: samples.count, by: window) {
      peak = max(peak, rms(samples[start..<min(start + window, samples.count)]))
    }
    return tail > peak * 0.25
  }
  public static func text(_ value: String) -> String {
    value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "—–-")))
  }
  public static func generate(text: String, seed: Int, label: String,
    operation: (String, Int) async throws -> [Float]) async throws -> [Float] {
    let spoken = self.text(text)
    var issue = "Пустой результат модели"
    for attempt in 0..<3 {
      try Task.checkCancellation()
      let raw = try await operation(spoken, max(0, seed) + attempt * 104729)
      if !raw.allSatisfy({ $0.isFinite }) {
        issue = "Повреждённые аудиоданные модели"
      } else if activeTail(raw) {
        issue = "Сильный сигнал на конце WAV · возможный обрыв"
      } else {
        let samples = NativeWAV.trim(raw)
        if !samples.isEmpty { return samples }
        issue = "Пустой результат модели"
      }
      NativeIO.emit("log", ["message": issue + " · " + label + " · попытка \(attempt+1)/3"])
      if attempt < 2 { NativeIO.stage("Повтор генерации · " + label + " · попытка \(attempt+2)/3") }
    }
    throw StudioError(issue + " после трёх попыток · " + label + " · «" + String(spoken.prefix(160)) + "». Готовые реплики сохранены в кеше.")
  }
}
