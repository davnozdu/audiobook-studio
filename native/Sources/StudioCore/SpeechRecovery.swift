import Foundation

public enum SpeechRecovery {
  /// Retry only failed lanes. Persist accepted lanes immediately so a later failure
  /// cannot discard completed speech. nil means the model did not reach that lane's EOS.
  public static func batch(texts: [String], seeds: [Int], labels: [String],
    operation: ([Int], [Int]) async throws -> [[Float]?],
    accepted: (Int, [Float]) throws -> Void) async throws -> [[Float]] {
    guard !texts.isEmpty, texts.count == seeds.count, texts.count == labels.count else {
      throw StudioError("Несовпадение реплик, голосов и seed в пакете")
    }
    var output = [[Float]?](repeating: nil, count: texts.count)
    var pending = Array(texts.indices)
    var issues: [Int: String] = [:]
    for attempt in 0..<3 {
      try Task.checkCancellation()
      let waves = try await operation(pending, pending.map { max(0, seeds[$0]) + attempt * 104729 })
      guard waves.count == pending.count else { throw StudioError("Модель потеряла реплики внутри пакета") }
      var retry: [Int] = []
      for (i, raw) in zip(pending, waves) {
        var samples: [Float] = []
        let issue: String
        if let raw {
          if !raw.allSatisfy({ $0.isFinite }) { issue = "Повреждённые аудиоданные" }
          else if activeTail(raw) { issue = "Сильный сигнал на конце WAV · возможный обрыв" }
          else {
            samples = NativeWAV.trim(raw)
            issue = "Пустой результат модели"
          }
        } else { issue = "Реплика не завершилась EOS" }
        if !samples.isEmpty {
          try accepted(i, samples)
          output[i] = samples
        } else {
          issues[i] = issue; retry.append(i)
          NativeIO.emit("log", ["message": issue + " · " + labels[i] + " · попытка \(attempt+1)/3"])
        }
      }
      pending = retry
      if pending.isEmpty { return output.map { $0! } }
      if attempt < 2 { NativeIO.stage("Повтор генерации · \(pending.count) реплик из пакета · попытка \(attempt+2)/3") }
    }
    let i = pending[0]
    throw StudioError((issues[i] ?? "Не завершена реплика") + " после трёх попыток · " + labels[i]
      + " · «" + String(texts[i].prefix(160)) + "». Готовые реплики сохранены в кеше.")
  }
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
      let raw: [Float]
      do { raw = try await operation(spoken, max(0, seed) + attempt * 104729) }
      catch is CancellationError { throw CancellationError() }
      catch {
        // The model throws when it reaches the token limit without EOS: another seed may finish.
        issue = error.localizedDescription
        NativeIO.emit("log", ["message": issue + " · " + label + " · попытка \(attempt+1)/3"])
        if attempt < 2 { NativeIO.stage("Повтор генерации · " + label + " · попытка \(attempt+2)/3") }
        continue
      }
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
