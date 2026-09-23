import CryptoKit
import Foundation

/// The HTTP upgrade that precedes every mobile-gateway WebSocket.
///
/// Parsing and answering the handshake is separated from the socket so the security
/// decisions — which credentials are acceptable, which hosts may connect, which
/// status code a refusal returns — are ordinary functions with unit tests, not
/// behaviour that only exists while a real phone is on the network.

/// A parsed upgrade request.
public struct WebSocketHandshakeRequest: Equatable, Sendable {
  public var method: String
  /// Request path with the query stripped, e.g. `/ws/mobile`.
  public var path: String
  public var query: [String: String]
  /// Header names lowercased, because HTTP header names are case-insensitive and the
  /// iOS client's casing is not something this server should depend on.
  public var headers: [String: String]
  public var subprotocols: [String]

  public var host: String? { headers["host"] }
  public var clientDeviceID: String? { headers["x-dsh-device-id"] }
  public var userAgent: String? { headers["user-agent"] }
  public var origin: String? { headers["origin"] }

  /// `Authorization: Bearer <token>`, the client's preferred credential transport.
  public var bearerToken: String? {
    guard let value = headers["authorization"] else { return nil }
    let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
    guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
    let token = parts[1].trimmingCharacters(in: .whitespaces)
    return token.isEmpty ? nil : token
  }

  /// The `dsh-pair.<code>` subprotocol, if the client offered one.
  ///
  /// The pairing code rides in the subprotocol rather than the URL because a
  /// subprotocol header does not land in the access logs a reverse proxy writes.
  public var pairingSubprotocol: String? { Self.value(of: "dsh-pair.", in: subprotocols) }
  /// The `dsh-auth.<token>` subprotocol, if the client offered one.
  public var authSubprotocol: String? { Self.value(of: "dsh-auth.", in: subprotocols) }

  public var supportsProtocol: Bool { subprotocols.contains("dsh-mobile-v1") }

  private static func value(of prefix: String, in values: [String]) -> String? {
    for value in values where value.hasPrefix(prefix) {
      let trimmed = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
      if !trimmed.isEmpty { return trimmed }
    }
    return nil
  }
}

/// Outcome of feeding bytes to the handshake parser.
public enum WebSocketHandshakeParseResult: Equatable, Sendable {
  case incomplete
  case request(WebSocketHandshakeRequest, headerLength: Int)
  /// The bytes cannot start a valid HTTP request. The caller answers 400 and hangs up.
  case malformed(String)
}

public enum WebSocketHandshake {
  /// The RFC 6455 magic value appended to the client key before hashing.
  public static let acceptGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  /// A request whose header block never ends would otherwise buffer forever.
  public static let maxHeaderBytes = 16 * 1024

  public static func parse(_ data: Data) -> WebSocketHandshakeParseResult {
    // The header block ends at the first empty line. Look for it in the raw bytes so a
    // split multi-byte UTF-8 sequence in a header value cannot confuse the search.
    guard let terminator = findHeaderEnd(data) else {
      return data.count > maxHeaderBytes ? .malformed("header block too large") : .incomplete
    }
    guard let text = String(data: data.prefix(terminator), encoding: .utf8) else {
      return .malformed("header block is not valid UTF-8")
    }
    var lines = text.components(separatedBy: "\r\n")
    guard !lines.isEmpty else { return .malformed("empty request") }
    let requestLine = lines.removeFirst()
    let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard parts.count >= 2 else { return .malformed("malformed request line") }
    let method = parts[0].uppercased()
    guard method == "GET" else { return .malformed("upgrade requires GET") }

    let target = parts[1]
    // Compare the version loosely: the request line's HTTP version is not part of any
    // decision this server makes, but a non-HTTP request line must still be rejected.
    guard parts.count < 3 || parts[2].uppercased().hasPrefix("HTTP/") else {
      return .malformed("not an HTTP request")
    }

    var path = target
    var query: [String: String] = [:]
    if let mark = target.firstIndex(of: "?") {
      path = String(target[target.startIndex..<mark])
      query = parseQuery(String(target[target.index(after: mark)...]))
    } else if let mark = target.firstIndex(of: "#") {
      path = String(target[target.startIndex..<mark])
    }
    guard path.hasPrefix("/") else { return .malformed("request target is not a path") }
    // An absolute-form target (`GET http://host/path HTTP/1.1`) is legal HTTP but never
    // how a WebSocket client connects; treat it as malformed rather than guess a path.
    if path.hasPrefix("//") { return .malformed("absolute request target") }

    var headers: [String: String] = [:]
    for line in lines where !line.isEmpty {
      guard let colon = line.firstIndex(of: ":") else { return .malformed("malformed header line") }
      let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
      let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty else { return .malformed("empty header name") }
      // Repeated identical headers are legal; joining them with a comma preserves the
      // list semantics the subprotocol parser relies on.
      if let existing = headers[name], !existing.isEmpty {
        headers[name] = "\(existing), \(value)"
      } else {
        headers[name] = value
      }
    }

    let subprotocols = (headers["sec-websocket-protocol"] ?? "")
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }

    let request = WebSocketHandshakeRequest(
      method: method,
      path: path,
      query: query,
      headers: headers,
      subprotocols: subprotocols
    )
    return .request(request, headerLength: terminator)
  }

  /// `Sec-WebSocket-Accept` for a client's `Sec-WebSocket-Key`.
  public static func accept(for key: String) -> String {
    let digest = Insecure.SHA1.hash(data: Data((key + acceptGUID).utf8))
    return Data(digest).base64EncodedString()
  }

  /// A 101 response. `Sec-WebSocket-Protocol` is echoed only when a subprotocol was
  /// actually agreed, since announcing one the client did not offer aborts the
  /// connection on well-behaved clients.
  public static func upgradeResponse(accept: String, subprotocol: String?) -> Data {
    var head = "HTTP/1.1 101 Switching Protocols\r\n"
    head += "Upgrade: websocket\r\n"
    head += "Connection: Upgrade\r\n"
    head += "Sec-WebSocket-Accept: \(accept)\r\n"
    if let subprotocol, !subprotocol.isEmpty {
      head += "Sec-WebSocket-Protocol: \(subprotocol)\r\n"
    }
    head += "\r\n"
    return Data(head.utf8)
  }

  /// A refusal. The body is a small JSON object so a client (or a human with `curl`)
  /// sees the reason instead of an empty connection reset.
  public static func refusalResponse(status: Int, code: String, message: String) -> Data {
    let reason = httpReason(status)
    let body = "{\"error\":\"\(jsonEscape(code))\",\"message\":\"\(jsonEscape(message))\"}\n"
    let bodyData = Data(body.utf8)
    var head = "HTTP/1.1 \(status) \(reason)\r\n"
    head += "Content-Type: application/json; charset=utf-8\r\n"
    head += "Content-Length: \(bodyData.count)\r\n"
    head += "Connection: close\r\n"
    // The gateway answers cross-origin and non-loopback peers, so it must not be
    // framed or sniffed, and must not leak a referrer.
    head += "X-Content-Type-Options: nosniff\r\n"
    head += "Referrer-Policy: no-referrer\r\n"
    head += "Cache-Control: no-store\r\n"
    head += "\r\n"
    var response = Data(head.utf8)
    response.append(bodyData)
    return response
  }

  private static func httpReason(_ status: Int) -> String {
    switch status {
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 403: return "Forbidden"
    case 404: return "Not Found"
    case 405: return "Method Not Allowed"
    case 426: return "Upgrade Required"
    case 503: return "Service Unavailable"
    default: return "Error"
    }
  }

  private static func jsonEscape(_ value: String) -> String {
    var out = ""
    for character in value.unicodeScalars {
      switch character {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      default:
        if character.value < 0x20 {
          out += String(format: "\\u%04x", character.value)
        } else {
          out.unicodeScalars.append(character)
        }
      }
    }
    return out
  }

  /// Index just past the `\r\n\r\n` that terminates the header block.
  private static func findHeaderEnd(_ data: Data) -> Int? {
    let pattern: [UInt8] = [13, 10, 13, 10]
    guard data.count >= pattern.count else { return nil }
    let bytes = [UInt8](data)
    var index = 0
    let limit = bytes.count - pattern.count
    while index <= limit {
      if bytes[index] == pattern[0], bytes[index + 1] == pattern[1],
         bytes[index + 2] == pattern[2], bytes[index + 3] == pattern[3] {
        return index + pattern.count
      }
      index += 1
    }
    return nil
  }

  private static func parseQuery(_ raw: String) -> [String: String] {
    var result: [String: String] = [:]
    for pair in raw.split(separator: "&", omittingEmptySubsequences: true) {
      let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      let name = decodeQueryComponent(String(parts[0]))
      guard !name.isEmpty else { continue }
      let value = parts.count > 1 ? decodeQueryComponent(String(parts[1])) : ""
      // First occurrence wins, matching how the Node implementation reads query keys.
      if result[name] == nil { result[name] = value }
    }
    return result
  }

  private static func decodeQueryComponent(_ value: String) -> String {
    value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? value
  }
}
