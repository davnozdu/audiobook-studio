import Foundation
import CryptoKit
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let directory = root.appendingPathComponent(".private")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let path = directory.appendingPathComponent("sparkle.key")
let key: Curve25519.Signing.PrivateKey
if FileManager.default.fileExists(atPath: path.path) {
    let raw = Data(base64Encoded: try String(contentsOf: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
    key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
} else {
    key = Curve25519.Signing.PrivateKey()
    try (key.rawRepresentation.base64EncodedString() + "\n").write(to: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
}
try (key.publicKey.rawRepresentation.base64EncodedString() + "\n").write(to: root.appendingPathComponent("sparkle-public-key.txt"), atomically: true, encoding: .utf8)
print("Permanent update key ready; public key saved, private key excluded from Git.")
