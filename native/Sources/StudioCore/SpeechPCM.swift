import Foundation

/// Small per-utterance container for the resumable speech cache.
///
/// SPC2 (written): 16-bit PCM — CD quality, quantisation noise at −96 dBFS, far below the final
/// 96 kbit/s AAC — stored as second-order prediction residuals split into low/high byte planes and
/// compressed with LZMA. Lossless at 16 bits (Float32 beyond ±1 clips; measured model peaks stay below 0.8); measured on speech about 95 MB per hour against
/// 283 MB for the former exact Float32 container, so a 20-hour book keeps ~1.9 GB instead of
/// ~5.7 GB until it is packaged. SPC1 (exact Float32 + LZFSE) is still read.
public enum SpeechPCM {
  static let scale: Float = 32767

  public static func quantize(_ samples: [Float]) -> [Int16] {
    samples.map { Int16(max(-32767, min(32767, ($0 * scale).rounded()))) }
  }

  // SPC1 helper: groups matching byte positions of Float32 samples (byte permutation only).
  static func transpose(_ data: Data, inverse: Bool) -> Data {
    var result = Data(count: data.count)
    let frames = data.count / 4
    result.withUnsafeMutableBytes { destination in
      data.withUnsafeBytes { source in
        let a = source.bindMemory(to: UInt8.self), b = destination.bindMemory(to: UInt8.self)
        for plane in 0..<4 {
          for i in 0..<frames {
            if inverse { b[i * 4 + plane] = a[plane * frames + i] }
            else { b[plane * frames + i] = a[i * 4 + plane] }
          }
        }
      }
    }
    return result
  }

  /// Residual of x[k] against 2·x[k−1] − x[k−2], modulo 2¹⁶, as low then high byte planes.
  static func encode(_ pcm: [Int16]) -> Data {
    let n = pcm.count
    var planes = Data(count: n * 2)
    planes.withUnsafeMutableBytes { raw in
      let out = raw.bindMemory(to: UInt8.self)
      var a: Int32 = 0, b: Int32 = 0  // x[k−1], x[k−2]
      for k in 0..<n {
        let x = Int32(pcm[k])
        let r = UInt16(truncatingIfNeeded: x &- (2 &* a &- b))
        out[k] = UInt8(r & 0xFF); out[n + k] = UInt8(r >> 8)
        b = a; a = x
      }
    }
    return planes
  }
  static func decode(_ planes: Data, count n: Int) -> [Int16] {
    var pcm = [Int16](repeating: 0, count: n)
    planes.withUnsafeBytes { raw in
      let input = raw.bindMemory(to: UInt8.self)
      var a: Int32 = 0, b: Int32 = 0
      for k in 0..<n {
        let r = Int32(UInt16(input[k]) | UInt16(input[n + k]) << 8)
        let x = Int16(truncatingIfNeeded: (2 &* a &- b) &+ r)
        pcm[k] = x; b = a; a = Int32(x)
      }
    }
    return pcm
  }

  public static func write(_ file: URL, samples: [Float]) throws {
    guard !samples.isEmpty, samples.count <= 4096 * 1920,
      samples.allSatisfy({ $0.isFinite }), samples.contains(where: { abs($0) > 0.00001 }) else {
      throw StudioError("Некорректная реплика для сжатого кеша")
    }
    let pcm = quantize(samples)
    let planes = encode(pcm)
    let compressed = try (planes as NSData).compressed(using: .lzma) as Data
    let useCompressed = compressed.count < planes.count
    var data = Data("SPC2".utf8)
    data += NativeWAV.little(UInt32(24000))
    data += NativeWAV.little(UInt64(samples.count))
    data.append(useCompressed ? 3 : 1)
    data += useCompressed ? compressed : planes
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: file, options: .atomic)
  }

  public static func read(_ file: URL) throws -> [Float] {
    let data = try Data(contentsOf: file)
    guard data.count > 17, [Data("SPC1".utf8), Data("SPC2".utf8)].contains(data.prefix(4)) else {
      throw StudioError("Повреждён сжатый кеш реплики")
    }
    let (rate, count): (UInt32, UInt64) = data.withUnsafeBytes {
      (UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)),
       UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)))
    }
    let mode = data[16], payload = Data(data.dropFirst(17))
    guard rate == 24000, count > 0, count <= 4096 * 1920 else {
      throw StudioError("Некорректная длина или формат сжатой реплики")
    }
    if data.prefix(4) == Data("SPC2".utf8) {
      guard mode == 1 || mode == 3 else { throw StudioError("Неизвестный формат сжатой реплики") }
      let planes = mode == 3 ? try (payload as NSData).decompressed(using: .lzma) as Data : payload
      guard planes.count == Int(count) * 2 else { throw StudioError("Оборван сжатый кеш реплики") }
      return decode(planes, count: Int(count)).map { Float($0) / scale }
    }
    guard mode <= 2 else { throw StudioError("Неизвестный формат сжатой реплики") }
    let decoded = mode > 0 ? try (payload as NSData).decompressed(using: .lzfse) as Data : payload
    guard decoded.count == Int(count) * 4 else { throw StudioError("Оборван сжатый кеш реплики") }
    let raw = mode == 2 ? transpose(decoded, inverse: true) : decoded
    return try NativeWAV.samples(raw)
  }
}
