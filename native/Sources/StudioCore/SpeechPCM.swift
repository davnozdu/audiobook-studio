import Foundation

/// Small per-utterance container: exact Float32 PCM, compressed with the macOS
/// lossless LZFSE codec. No encoder priming, quantisation or child process.
public enum SpeechPCM {
  // Group matching byte positions of Float32 samples to help the lossless
  // compressor. This only permutes bytes; every mantissa/sign bit is preserved.
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
  public static func write(_ file: URL, samples: [Float]) throws {
    guard !samples.isEmpty, samples.count <= 4096 * 1920,
      samples.allSatisfy({ $0.isFinite }), samples.contains(where: { abs($0) > 0.00001 }) else {
      throw StudioError("Некорректная реплика для сжатого кеша")
    }
    let raw = NativeWAV.bytes(samples)
    let compressed = try (transpose(raw, inverse: false) as NSData).compressed(using: .lzfse) as Data
    let useCompressed = compressed.count < raw.count
    var data = Data("SPC1".utf8)
    data += NativeWAV.little(UInt32(24000))
    data += NativeWAV.little(UInt64(samples.count))
    data.append(useCompressed ? 2 : 0)
    data += useCompressed ? compressed : raw
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: file, options: .atomic)
  }
  public static func read(_ file: URL) throws -> [Float] {
    let data = try Data(contentsOf: file)
    guard data.count > 17, data.prefix(4) == Data("SPC1".utf8) else {
      throw StudioError("Повреждён сжатый кеш реплики")
    }
    let (rate, count): (UInt32, UInt64) = data.withUnsafeBytes {
      (UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)),
       UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)))
    }
    guard rate == 24000, count > 0, count <= 4096 * 1920, data[16] <= 2 else {
      throw StudioError("Некорректная длина или формат сжатой реплики")
    }
    let payload = Data(data.dropFirst(17))
    let decoded = data[16] > 0 ? try (payload as NSData).decompressed(using: .lzfse) as Data : payload
    guard decoded.count == Int(count) * 4 else { throw StudioError("Оборван сжатый кеш реплики") }
    let raw = data[16] == 2 ? transpose(decoded, inverse: true) : decoded
    return try NativeWAV.samples(raw)
  }
}
