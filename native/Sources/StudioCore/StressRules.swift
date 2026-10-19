import Foundation

/// Fixed stress rules applied around the dictionary, Silero and the LLM check.
public enum StressRules {
  /// Homographs whose other reading is rare in prose: уже́ (не у́же), глаза́ (не гла́за). A rare
  /// reading is kept only when every vote, including a second independent LLM answer, agrees.
  public static let common: [String: String] = [
    "уже": "уже́", "глаза": "глаза́", "мало": "ма́ло", "потом": "пото́м", "чаю": "ча́ю", "мою": "мою́",
    "моя": "моя́", "совершенный": "соверше́нный", "совершенно": "соверше́нно", "пора": "пора́",
    "сорок": "со́рок", "иначе": "ина́че", "писать": "писа́ть",
  ]
  /// Ordinary words the stress model tends to read in the colloquial way (зво́нит, на́чалось).
  public static let orthoepy: [String: String] = {
    let marked = [
      "звони́т", "звони́шь", "звони́м", "звони́те", "звоня́т", "позвони́т", "позвони́шь", "позвони́м", "позвоня́т",
      "позвони́те", "перезвони́т", "перезвоня́т", "созвони́мся", "включи́т", "включи́шь", "включи́м", "включа́т",
      "начало́сь", "начался́", "начала́сь", "по́нял", "при́нял", "о́тдал", "за́нял", "на́нял", "по́днял",
      "приняла́", "отдала́", "заняла́", "наняла́", "подняла́", "создала́", "облегчи́ть", "облегчи́т", "углуби́ть",
      "краси́вее", "ку́хонный", "ку́хонная", "ку́хонное", "ку́хонные", "ку́хонной", "догово́р", "догово́ры",
      "догово́ра", "катало́г", "кварта́л", "щаве́ль", "то́рты", "ба́нты", "ша́рфы", "ту́фля", "све́кла",
      "ходата́йство", "опто́вый", "че́рпать", "балова́ть", "бало́ванный", "жалюзи́", "дефи́с", "досу́г",
      "портфе́ль", "угля́", "щаве́ля", "наме́рение", "обеспе́чение", "о́трочество", "зна́мение", "и́здавна",
      "алфави́т", "мусоропрово́д", "газопрово́д", "цепо́чка", "кладова́я", "прину́дить", "заку́порить",
      "нача́ть", "приня́ть", "поня́ть", "заня́ть", "подня́ть", "отня́ть", "наня́ть",
    ]
    return Dictionary(marked.map { (NativeStress.plain($0), $0) }, uniquingKeysWith: { a, _ in a })
  }()

  /// The user's own words, one per line, written as the model reads them: the stress mark
  /// above the vowel (за́мок) or the letter ё. Lines with other characters, no stress or several
  /// marks are ignored. Plain form → marked form.
  public static func userDictionary(_ text: String) -> [String: String] {
    var result: [String: String] = [:]
    for line in text.components(separatedBy: .newlines) {
      // Composed letters (й, ё stay whole); the stress mark has no composed form and stays apart.
      let word = line.trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping.lowercased()
      let marks = word.unicodeScalars.filter { $0.value == 0x301 }.count
      guard !word.isEmpty, NativeIO.regex("^[а-яё\\u0301-]+$", word).count == 1,
        marks == 1 || (marks == 0 && word.unicodeScalars.contains("ё")),
        NativeIO.regex("(?<![аеёиоуыэюя])\\u0301", word).isEmpty else { continue }
      result[NativeStress.plain(word)] = word
    }
    return result
  }

  /// все or всё from the neighbouring words of the same clause, when grammar decides it: a plural
  /// verb next to it (все пришли, вытянут все, все видели), «все до единого», «все готовы» — все;
  /// «всё же / равно / ещё / ясно», «всё было» — всё. nil leaves the choice to the model and the LLM.
  public static func allOrEverything(before: String, after: String) -> String? {
    let clause = CharacterSet(charactersIn: ",.!?;:—–()«»\"")
    func words(_ text: String, last: Bool) -> [String] {
      let part = last ? text.components(separatedBy: clause).last ?? "" : text.components(separatedBy: clause).first ?? ""
      let found = part.lowercased().components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "-")).inverted)
        .filter { !$0.isEmpty }
      return last ? Array(found.suffix(2)) : Array(found.prefix(2))
    }
    let next = words(after, last: false), previous = words(before, last: true)
    // «все, кто / кому…» are people; «всё, что / чего…» is everything.
    let relative = after.lowercased().trimmingCharacters(in: .whitespaces)
    if relative.hasPrefix(",") {
      let word = relative.dropFirst().trimmingCharacters(in: .whitespaces).components(separatedBy: CharacterSet.letters.inverted).first ?? ""
      if ["кто", "кому", "кого", "кем", "ком"].contains(word) { return "все" }
      if ["что", "чего", "чему", "чем"].contains(word) { return "всё" }
    }
    func pluralVerb(_ w: String) -> Bool {
      w.count >= 4 && !notVerbs.contains(w) && ["ли", "лись", "ют", "ут", "ят", "ются", "утся", "ятся"].contains { w.hasSuffix($0) }
    }
    if let n = next.first {
      if ["же", "равно", "ещё", "еще", "ясно", "кончено", "понятно", "правильно", "хорошо", "время"].contains(n) { return "всё" }
      if n == "до", next.dropFirst().first == "единого" { return "все" }
      if ["готовы", "согласны", "живы", "здоровы", "вместе"].contains(n) || pluralVerb(n) { return "все" }
      if n.count >= 4, n.hasSuffix("ло") || n.hasSuffix("лось") { return "всё" }
    }
    if let p = previous.last, pluralVerb(p) { return "все" }
    return nil
  }
  static let notVerbs: Set<String> = ["если", "или", "земли", "пыли", "вдали", "неужели", "минут", "салют", "приют",
    "маршрут", "институт", "абсолют", "уют", "тут", "прут", "валют", "жгут", "кнут", "чуть-чуть"]

  static let wordPattern = "[А-Яа-яЁё]+(?:\\u0301[А-Яа-яЁё]*)*"
  /// Keeps what Silero placed as the letter ё but none of its stress marks; marks printed in the
  /// book (present in `original`) stay. For the "no stress" mode.
  public static func onlyYo(_ annotated: String, original: String) -> String {
    let a = NativeIO.regex(wordPattern, annotated), o = NativeIO.regex(wordPattern, original)
    guard a.count == o.count else { return original }
    let ans = annotated as NSString, ons = original as NSString
    var result = annotated
    for (x, y) in zip(a, o).reversed() where !ons.substring(with: y.range).unicodeScalars.contains("\u{301}") {
      let word = ans.substring(with: x.range)
      let bare = String(String.UnicodeScalarView(word.unicodeScalars.filter { $0.value != 0x301 }))
      if bare != word { result = (result as NSString).replacingCharacters(in: x.range, with: bare) }
    }
    return result
  }
  /// Adds RUAccent's reading to Silero's as a second voice. Where both stressed a word and
  /// differ, the word becomes disputed between the two readings (the LLM or the arbitration
  /// decides); a homograph already disputed takes RUAccent's reading as a vote; a word Silero
  /// left unstressed takes RUAccent's stress.
  public static func secondVoice(_ silero: NativeDirector.StressItem, _ ruaccent: String) -> NativeDirector.StressItem {
    let s = NativeIO.regex(wordPattern, silero.text), r = NativeIO.regex(wordPattern, ruaccent)
    guard s.count == r.count else { return silero }
    let sns = silero.text as NSString, rns = ruaccent as NSString
    var text = silero.text, disputes = silero.disputes, votes: [Int: String] = [:]
    func stressed(_ w: String) -> Bool { w.unicodeScalars.contains("\u{301}") || w.lowercased().unicodeScalars.contains("ё") }
    for (i, (x, y)) in zip(s, r).enumerated().reversed() {
      let a = sns.substring(with: x.range), b = rns.substring(with: y.range)
      guard NativeStress.plain(a) == NativeStress.plain(b), !same(a, b), stressed(b) else { continue }
      if let readings = disputes[i] {
        if let reading = readings.first(where: { same($0, b) }) { votes[i] = reading }
      } else if !stressed(a) && NativeStress.vowelCount(a) > 1 {
        text = (text as NSString).replacingCharacters(in: x.range, with: b)
      } else {
        // Two stresses, or все/всё-type letters: a one-vowel word without ё is a decision too.
        disputes[i] = [a, b]
        votes[i] = b
      }
    }
    return NativeDirector.StressItem(text: text, context: silero.context, disputes: disputes, votes: votes)
  }
  static func same(_ a: String, _ b: String) -> Bool {
    a.lowercased().precomposedStringWithCanonicalMapping == b.lowercased().precomposedStringWithCanonicalMapping
  }
  /// The reading of a homograph to use from the votes cast for it (Silero, the LLM, a second
  /// LLM answer): the majority wins, a tie goes to the common reading, and a rare reading needs
  /// every vote and at least three of them. nil when no vote names one of the readings.
  public static func arbitrate(_ readings: [String], votes: [String?]) -> String? {
    let cast = votes.compactMap { vote in vote.flatMap { v in readings.first { same($0, v) } } }
    guard !cast.isEmpty else { return nil }
    var order: [String] = [], counts: [String: Int] = [:]
    for vote in cast {
      if counts[vote] == nil { order.append(vote) }
      counts[vote, default: 0] += 1
    }
    let top = counts.values.max()!
    let winners = order.filter { counts[$0] == top }
    let common = commonReading(readings)
    var choice = winners.count == 1 ? winners[0] : winners.first { r in common.map { same(r, $0) } ?? false } ?? winners[0]
    if let common, !same(choice, common), !(cast.count >= 3 && cast.allSatisfy { same($0, choice) }) {
      choice = common
    }
    return choice
  }
  /// The common reading among a homograph's prepared readings, with the book's letter case.
  public static func commonReading(_ readings: [String]) -> String? {
    guard let first = readings.first, let common = Self.common[NativeStress.plain(first)] else { return nil }
    return readings.first { same($0, common) }
  }
  /// Whether a rare reading is among the votes, so the word needs a second LLM answer.
  public static func needsSecondOpinion(_ readings: [String], votes: [String?]) -> Bool {
    let cast = votes.compactMap { $0 }
    if Set(cast.map { $0.lowercased().precomposedStringWithCanonicalMapping }).count > 1 { return true }
    guard let common = commonReading(readings) else { return false }
    return cast.contains { !same($0, common) }
  }
}
