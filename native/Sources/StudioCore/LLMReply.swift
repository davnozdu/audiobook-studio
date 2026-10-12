import Foundation

public enum LLMReply {
  public static func parse(_ data: Data) throws -> Object {
    guard let reply = (try? JSONSerialization.jsonObject(with: data)) as? Object else {
      throw StudioError("LLM: сервер вернул ответ не в формате JSON")
    }
    if let error = reply["error"] as? String {
      throw StudioError("LLM: " + String(error.prefix(300)))
    }
    let reason = NativeIO.string(reply["done_reason"])
    guard reason.isEmpty || ["stop", "eos"].contains(reason) else {
      throw StudioError("LLM: ответ не завершён (" + reason + "). Требуется повтор запроса")
    }
    guard reply["done"] as? Bool != false else {
      throw StudioError("LLM: получен незавершённый ответ")
    }
    guard let content = NativeIO.object(reply["message"])["content"] as? String,
      !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw StudioError("LLM: модель вернула пустой ответ")
    }
    return try object(content)
  }
  /// OpenAI-style chat completion (DeepSeek).
  public static func parseChatCompletion(_ data: Data) throws -> Object {
    guard let reply = (try? JSONSerialization.jsonObject(with: data)) as? Object else {
      throw StudioError("LLM: сервер вернул ответ не в формате JSON")
    }
    if let error = reply["error"] as? Object {
      throw StudioError("LLM: " + String(NativeIO.string(error["message"]).prefix(300)))
    }
    let choice = NativeIO.objects(reply["choices"]).first ?? [:]
    let reason = NativeIO.string(choice["finish_reason"])
    guard reason.isEmpty || reason == "stop" else {
      throw StudioError("LLM: ответ не завершён (" + reason + "). Требуется повтор запроса")
    }
    // JSON mode may occasionally return empty content; that is retried like malformed JSON.
    guard let content = NativeIO.object(choice["message"])["content"] as? String,
      !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw StudioError("LLM: модель вернула пустой ответ")
    }
    return try object(content)
  }
  public static func object(_ content: String) throws -> Object {
    var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("\u{FEFF}") { text.removeFirst(); text = text.trimmingCharacters(in: .whitespacesAndNewlines) }
    if text.hasPrefix("```") {
      guard let newline = text.firstIndex(of: "\n"), text.hasSuffix("```") else {
        throw StudioError("LLM: оборванная JSON-обёртка ответа")
      }
      let language = String(text[text.index(text.startIndex, offsetBy: 3)..<newline]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard language.isEmpty || language == "json" else {
        throw StudioError("LLM: ожидался JSON, получен блок " + language)
      }
      text = String(text[text.index(after: newline)..<text.index(text.endIndex, offsetBy: -3)]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let result = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? Object else {
      throw StudioError("LLM: содержимое ответа не является корректным JSON-объектом")
    }
    return result
  }
}
