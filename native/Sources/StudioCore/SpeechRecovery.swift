import Foundation

public enum SpeechRecovery {
  public static func text(_ value: String) -> String {
    value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "—–-")))
  }
  public static func generate(text: String, seed: Int, label: String,
    operation: (String, Int) async throws -> [Float]) async throws -> [Float] {
    let spoken = self.text(text)
    for attempt in 0..<3 {
      try Task.checkCancellation()
      let raw = try await operation(spoken, max(0, seed) + attempt * 104729)
      if raw.allSatisfy({ $0.isFinite }) {
        let samples = NativeWAV.trim(raw)
        if !samples.isEmpty { return samples }
      }
      NativeIO.emit("log", ["message": "Пустой результат модели · " + label + " · попытка \(attempt+1)/3"])
      if attempt < 2 { NativeIO.stage("Повтор генерации · " + label + " · попытка \(attempt+2)/3") }
    }
    throw StudioError("Модель трижды вернула тишину · " + label + " · «" + String(spoken.prefix(160)) + "». Готовые реплики сохранены в кеше.")
  }
}
