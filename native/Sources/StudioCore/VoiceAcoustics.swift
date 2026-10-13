import Foundation

/// Coarse prosody of a voice sample, enough to tell whether a manner sample really sounds
/// different from the character's calm sample: pitch, pitch range, level, tempo and how much of
/// the speech is voiced (a whisper has almost none).
public struct VoiceAcoustics: Equatable {
  public var pitch: Double, range: Double, level: Double, rate: Double, voiced: Double

  /// 24 kHz mono samples and the text they say. Frames of 40 ms every 20 ms; speech frames are
  /// those within 35 dB of the loud ones, pitch by normalised autocorrelation in 70–500 Hz.
  public static func measure(_ samples: [Float], text: String) -> VoiceAcoustics? {
    let rate = 24000, window = 960, hop = 480, minLag = rate / 500, maxLag = rate / 70
    guard samples.count >= window + maxLag else { return nil }
    var energies: [Double] = []
    var start = 0
    while start + window + maxLag <= samples.count {
      var e = 0.0
      for k in start..<(start + window) { e += Double(samples[k] * samples[k]) }
      energies.append(e / Double(window)); start += hop
    }
    let loud = energies.sorted()[Int(Double(energies.count - 1) * 0.95)]
    let gate = max(1e-7, loud * pow(10, -3.5))
    var pitches: [Double] = [], active = 0, power = 0.0
    for (frame, energy) in energies.enumerated() where energy >= gate {
      active += 1; power += energy
      let offset = frame * hop
      var r = [Double](repeating: 0, count: maxLag + 2)
      for l in minLag...maxLag {
        var c = 0.0, e2 = 0.0
        for k in stride(from: offset, to: offset + window, by: 2) {
          c += Double(samples[k] * samples[k + l]); e2 += Double(samples[k + l] * samples[k + l])
        }
        r[l] = c / ((energy * Double(window) / 2 * e2).squareRoot() + 1e-12)
      }
      // Two or three periods correlate as well as one: take the shortest lag whose peak is
      // nearly the best, not the longest (350 Hz is not 175 Hz).
      let best = r[minLag...maxLag].max() ?? 0
      if best > 0.6, let lag = (minLag...maxLag).first(where: { l in
        r[l] >= 0.9 * best && r[l] >= r[l - 1] && r[l] >= r[l + 1] }) {
        pitches.append(Double(rate) / Double(lag))
      }
    }
    guard active > 0 else { return nil }
    let seconds = Double(active * hop) / Double(rate)
    let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
    pitches.sort()
    func quantile(_ p: Double) -> Double { pitches[min(pitches.count - 1, Int(Double(pitches.count) * p))] }
    return VoiceAcoustics(
      pitch: pitches.isEmpty ? 0 : quantile(0.5),
      range: pitches.count < 5 ? 0 : 12 * log2(quantile(0.9) / quantile(0.1)),
      level: 10 * log10(power / Double(active)),
      rate: Double(letters) / seconds,
      voiced: Double(pitches.count) / Double(active))
  }

  /// Level of the speech itself in dB: mean power of the frames within 35 dB of the loud ones,
  /// so pauses and breath do not lower it. nil for silence.
  public static func speechLevel(_ samples: [Float]) -> Double? {
    let window = 960
    guard samples.count >= window else { return nil }
    var energies: [Double] = []
    var start = 0
    while start + window <= samples.count {
      var e = 0.0
      for k in start..<(start + window) { e += Double(samples[k] * samples[k]) }
      energies.append(e / Double(window)); start += window / 2
    }
    let loud = energies.sorted()[Int(Double(energies.count - 1) * 0.95)]
    guard loud > 1e-9 else { return nil }
    let speech = energies.filter { $0 >= loud * pow(10, -3.5) }
    return 10 * log10(speech.reduce(0, +) / Double(speech.count))
  }

  /// Two main voices that sound alike: within a semitone of pitch, 1.5 semitones of pitch range
  /// and 10 % of tempo. (The speaker-embedding similarity is 0.97–0.99 for nearly every pair of
  /// one gender, even clearly different ones, so it cannot tell twins.)
  public static func twins(_ a: VoiceAcoustics, _ b: VoiceAcoustics) -> Bool {
    guard a.pitch > 0, b.pitch > 0, a.rate > 0, b.rate > 0 else { return false }
    let tempo = a.rate / b.rate
    return abs(12 * log2(a.pitch / b.pitch)) < 1 && abs(a.range - b.range) < 1.5 && tempo > 0.9 && tempo < 1.11
  }
  /// How far apart two voices are by ear, roughly: semitones of pitch plus half the range gap.
  public static func distance(_ a: VoiceAcoustics, _ b: VoiceAcoustics) -> Double {
    guard a.pitch > 0, b.pitch > 0 else { return 0 }
    return abs(12 * log2(a.pitch / b.pitch)) + abs(a.range - b.range) / 2
  }

  /// Differences from the calm sample: pitch and range in semitones, level in dB, tempo ratio,
  /// voiced share.
  public struct Change {
    public var pitch: Double, range: Double, level: Double, tempo: Double, voiced: Double
  }
  public func change(from calm: VoiceAcoustics) -> Change {
    Change(pitch: pitch > 0 && calm.pitch > 0 ? 12 * log2(pitch / calm.pitch) : 0,
      range: range - calm.range, level: level - calm.level,
      tempo: calm.rate > 0 ? rate / calm.rate : 1, voiced: voiced - calm.voiced)
  }

  /// How far a manner sample moved in its manner's direction (higher is stronger), and whether
  /// that is clearly audible: compatible signs alone are not enough, at least one must move
  /// past a noticeable step. Manners without a reliable acoustic sign always pass.
  public static func strength(_ manner: String, _ d: Change) -> (score: Double, audible: Bool) {
    // Pitch, pitch range, tempo and voicing only: VoiceDesign returns samples at an arbitrary
    // level (a shout came out 2.4 dB below the calm sample at +8.8 semitones), so loudness says
    // nothing about the emotion here.
    let tempo = 10 * log2(max(d.tempo, 0.01))   // +1 ≈ 7 % faster
    switch manner {
    case "joyful": return (d.pitch + d.range, d.pitch >= 2 && d.range >= 0)
    case "laughing": return (d.pitch - 10 * d.voiced, d.pitch >= 2)
    case "excited": return (d.pitch + tempo, d.pitch >= 2 && d.tempo >= 0.85)
    case "surprised": return (d.pitch + d.range, d.range >= 2 || d.pitch >= 3)
    case "angry": return (d.pitch + d.range, d.pitch >= 2 || d.range >= 2)
    case "shouting": return (d.pitch + tempo, d.pitch >= 4 && d.tempo >= 0.8)
    case "calling": return (d.pitch + d.range, d.pitch >= 3 || d.range >= 2)
    case "hysterical": return (d.pitch + d.range, d.pitch >= 3 && d.range >= 2)
    case "desperate": return (d.pitch + d.range, d.pitch >= 2)
    case "triumphant": return (d.pitch + d.range, d.pitch >= 1.5 || d.range >= 1.5)
    case "threatening": return (-d.pitch - tempo, d.pitch <= 0.5 && d.tempo <= 1 && (d.pitch <= -1 || d.tempo <= 0.9))
    case "cold": return (-d.range - d.pitch, d.range <= 0 && d.pitch <= 1 && (d.range <= -1 || d.pitch <= -1))
    case "stern": return (-d.pitch - tempo - d.range, d.pitch <= 1 && (d.pitch <= -1 || d.tempo <= 0.95 || d.range <= -1))
    case "solemn": return (-tempo - d.pitch, d.tempo <= 0.97 && d.pitch <= 1.5)
    case "frightened": return (d.pitch - 10 * d.voiced, d.pitch >= 2)
    case "anxious": return (d.pitch + tempo, d.tempo >= 1.05 || d.pitch >= 1.5)
    case "hesitant": return (d.range - tempo, d.tempo <= 0.95 || d.range >= 1)
    case "embarrassed": return (tempo - d.range - d.pitch, d.tempo >= 1.05 || d.range <= -1 || d.pitch <= -1)
    case "guilty": return (-d.pitch - tempo, d.pitch <= 0.5 && d.tempo <= 1 && (d.pitch <= -1 || d.tempo <= 0.92))
    case "breathless": return (tempo - 10 * d.voiced, d.voiced <= -0.1 || d.tempo >= 1.05)
    case "sad": return (-d.pitch - tempo - d.range, d.pitch <= 0.5 && (d.tempo <= 0.95 || d.range <= -1))
    case "crying": return (d.pitch - 10 * d.voiced, d.pitch >= 1 || d.voiced <= -0.15)
    case "tender": return (-tempo + d.range, d.tempo <= 0.97 || d.range >= 1)
    case "flirtatious": return (d.range, d.range >= 1)
    case "dreamy": return (-tempo, d.tempo <= 0.95)
    case "thoughtful": return (-tempo, d.tempo <= 0.95)
    case "relieved": return (-tempo, d.tempo <= 0.95)
    case "indifferent": return (-d.range, d.range <= -1)
    case "weak": return (-10 * d.voiced - d.range, d.voiced <= -0.1 || d.range <= -1)
    case "sleepy": return (-tempo, d.tempo <= 0.9)
    case "drunk": return (d.range - tempo, d.tempo <= 0.9 || d.range >= 2)
    case "mocking": return (d.range, d.range >= 1)
    case "contemptuous": return (-d.pitch - tempo, d.tempo <= 1 && d.pitch <= 1 && (d.tempo <= 0.92 || d.pitch <= -1))
    case "pleading": return (d.pitch, d.pitch >= 1)
    // VoiceDesign gives a hushed, flattened voice rather than a true whisper.
    case "whisper": return (-10 * d.voiced - d.range, d.voiced <= -0.3 || d.range <= -3)
    case "muttering": return (-d.range, d.range <= -1)
    default: return (0, true)
    }
  }
}
