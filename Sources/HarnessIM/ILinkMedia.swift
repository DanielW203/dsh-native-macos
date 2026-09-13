import CommonCrypto
import Foundation
import HarnessKit

/// Downloading and decrypting the media attached to an inbound message.
///
/// The provider hands out either an opaque encrypted query parameter or a full URL, and the
/// bytes behind both are AES-128-ECB ciphertext with PKCS#7 padding. Both encodings are
/// handled here, in one place, because the image and file items disagree about how the key
/// travels (`aeskey` hex vs `media.aes_key` base64).
public enum ILinkMedia {
  /// Parse the 16-byte AES key from an image or file item.
  public static func aesKey(from descriptor: JSONValue) throws -> Data {
    if let hex = descriptor["aeskey"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
       !hex.isEmpty {
      guard hex.count == 32, let data = Data(hexString: hex) else {
        throw ILinkError(.decryptionFailed, "微信媒体的加密密钥无效")
      }
      return data
    }
    if let encoded = descriptor["media"]?["aes_key"]?.stringValue,
       let decoded = Data(base64Encoded: encoded) {
      if decoded.count == 16 { return decoded }
      // Some messages base64 a 32-character hex string instead of the raw key.
      if decoded.count == 32, let text = String(data: decoded, encoding: .utf8),
         let hex = Data(hexString: text) {
        return hex
      }
    }
    throw ILinkError(.decryptionFailed, "微信媒体的加密密钥无效")
  }

  /// The HTTPS location of the encrypted bytes.
  ///
  /// A `full_url` is accepted only when it points at the media CDN over TLS: the URL arrives
  /// inside a message, so this is the fence that stops a crafted message from turning the
  /// channel into a request forwarder.
  public static func downloadURL(for descriptor: JSONValue) throws -> URL {
    let media = descriptor["media"] ?? descriptor
    if let query = media["encrypt_query_param"]?.stringValue, !query.isEmpty,
       let url = URL(string: "\(ILinkProtocol.cdnBaseURL)/download?encrypted_query_param=\(ILinkProtocol.queryEncoded(query))") {
      return url
    }
    guard let full = media["full_url"]?.stringValue, let url = URL(string: full) else {
      throw ILinkError(.untrustedEndpoint, "微信媒体没有可用的下载地址")
    }
    guard url.scheme == "https", url.host == ILinkProtocol.cdnHost, url.path.hasPrefix("/c2c/") else {
      throw ILinkError(.untrustedEndpoint, "微信媒体下载地址不受信任")
    }
    return url
  }

  /// Decrypt AES-128-ECB ciphertext with PKCS#7 padding.
  ///
  /// The padding option is explicit: `kCCOptionECBMode` alone means "ECB, no padding", and
  /// the provider's `aes-128-ecb` output *is* PKCS#7 padded (measured — without the flag the
  /// plaintext comes back with a trailing pad block).
  public static func decrypt(_ ciphertext: Data, key: Data) throws -> Data {
    guard key.count == 16 else {
      throw ILinkError(.decryptionFailed, "微信媒体的加密密钥长度无效")
    }
    guard !ciphertext.isEmpty, ciphertext.count % kCCBlockSizeAES128 == 0 else {
      throw ILinkError(.decryptionFailed, "微信媒体的加密数据无效")
    }
    // The capacity is captured up front: referring to `output.count` inside its own mutable
    // byte access is an overlapping access, which Swift rejects outright.
    let capacity = ciphertext.count + kCCBlockSizeAES128
    var output = Data(count: capacity)
    var moved = 0
    let status = output.withUnsafeMutableBytes { outBytes -> CCCryptorStatus in
      ciphertext.withUnsafeBytes { inBytes -> CCCryptorStatus in
        key.withUnsafeBytes { keyBytes -> CCCryptorStatus in
          CCCrypt(
            CCOperation(kCCDecrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
            keyBytes.baseAddress, key.count,
            nil,
            inBytes.baseAddress, ciphertext.count,
            outBytes.baseAddress, capacity,
            &moved
          )
        }
      }
    }
    guard status == kCCSuccess else {
      throw ILinkError(.decryptionFailed, "微信媒体解密失败（CCCrypt \(status)）")
    }
    output.removeSubrange(moved..<output.count)
    return output
  }

  /// Download and decrypt one attachment, enforcing the size ceiling before allocating.
  public static func load(
    descriptor: JSONValue,
    transport: ILinkHTTPTransport,
    maxBytes: Int = ILinkProtocol.maxImageBytes
  ) async throws -> Data {
    let url = try downloadURL(for: descriptor)
    let response = try await transport.send(ILinkHTTPRequest(method: "GET", url: url, timeout: 30))
    guard (200..<300).contains(response.status) else {
      throw ILinkError(.http, "微信媒体下载失败（HTTP \(response.status)）", status: response.status)
    }
    // Ciphertext is padded, so allow for one extra block before rejecting.
    guard response.body.count <= maxBytes + kCCBlockSizeAES128 else {
      throw ILinkError(.mediaTooLarge, "微信附件超过大小上限")
    }
    return try decrypt(response.body, key: try aesKey(from: descriptor))
  }
}

extension Data {
  /// Parse a hex string of even length; `nil` when it is not hex at all.
  init?(hexString: String) {
    let cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard cleaned.count % 2 == 0, !cleaned.isEmpty else { return nil }
    var bytes = [UInt8]()
    bytes.reserveCapacity(cleaned.count / 2)
    var index = cleaned.startIndex
    while index < cleaned.endIndex {
      let next = cleaned.index(index, offsetBy: 2)
      guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
      bytes.append(byte)
      index = next
    }
    self = Data(bytes)
  }
}
