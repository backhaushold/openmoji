// Local stand-in for the App Store Connect API, used ONLY by scripts/test-asc.sh
// (bead openmoji-2pq). It listens on 127.0.0.1, answers from a scripted scenario,
// verifies every request's ES256 JWT against a throwaway public key, and logs
// what it saw. It never talks to Apple and holds no real credentials.
//
//   asc-stub keygen <dir>
//       writes <dir>/AuthKey.p8 (PKCS#8 PEM, like Apple's) and <dir>/public.pem
//   asc-stub serve --public-key <pem> --scenario <json> --log <dir> --port-file <file>
//       serves until killed; writes the port number to <port-file> once listening
//
// Scenario JSON: {"routes": [{"method": "GET", "path": "/v1/builds",
//   "query": ["filter[version]=42"], "responses": [{"status": 200, "body": {...}}]}]}
// A route matches when the method and path are equal and every "query" entry is a
// substring of the decoded query string. The first match wins; its responses are
// used in order and the last one repeats. No match answers 599.
//
// <dir>/requests.log gets one line per request:
//   REQ n=1 method=GET path=/v1/apps alg=ES256 kid=K typ=JWT iss=I aud=A lifetime=300
//       iat_ok=yes life_ok=yes sig=valid matched=yes status=200 query=<decoded query>
// and <dir>/<n>.body holds the request body, if any.

import CryptoKit
import Foundation

struct ScriptedResponse: Sendable {
    let status: Int
    let body: Data
}

struct Route: Sendable {
    let method: String
    let path: String
    let query: [String]
    let responses: [ScriptedResponse]
}

struct Request: Sendable {
    let method: String
    let path: String
    let query: String
    let authorization: String
    let body: Data
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("asc-stub: \(message)\n".utf8))
    exit(1)
}

func base64URLDecode(_ text: String) -> Data? {
    var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while base64.count % 4 != 0 { base64 += "=" }
    return Data(base64Encoded: base64)
}

/// What the stub learned about a request's token, as log fields.
func inspectToken(_ authorization: String, publicKey: P256.Signing.PublicKey) -> String {
    let token = authorization.hasPrefix("Bearer ") ? String(authorization.dropFirst(7)) : ""
    let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 3,
          let headerData = base64URLDecode(parts[0]), let claimData = base64URLDecode(parts[1]),
          let signatureData = base64URLDecode(parts[2]),
          let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
          let claims = try? JSONSerialization.jsonObject(with: claimData) as? [String: Any]
    else { return "alg=- kid=- typ=- iss=- aud=- lifetime=0 iat_ok=no life_ok=no sig=malformed" }
    let issued = (claims["iat"] as? Int) ?? 0
    let expires = (claims["exp"] as? Int) ?? 0
    let lifetime = expires - issued
    let iatOK = abs(Int(Date().timeIntervalSince1970) - issued) <= 60
    var signature = "invalid"
    if signatureData.count == 64, let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: signatureData),
       publicKey.isValidSignature(ecdsa, for: Data("\(parts[0]).\(parts[1])".utf8)) {
        signature = "valid"
    }
    return "alg=\(header["alg"] ?? "-") kid=\(header["kid"] ?? "-") typ=\(header["typ"] ?? "-") iss=\(claims["iss"] ?? "-") aud=\(claims["aud"] ?? "-") "
        + "lifetime=\(lifetime) iat_ok=\(iatOK ? "yes" : "no") life_ok=\(lifetime > 0 && lifetime <= 1200 ? "yes" : "no") sig=\(signature)"
}

final class Server: @unchecked Sendable {
    private let routes: [Route]
    private let publicKey: P256.Signing.PublicKey
    private let logDirectory: URL
    private let lock = NSLock()
    private var hits: [Int: Int] = [:]
    private var counter = 0

    init(routes: [Route], publicKey: P256.Signing.PublicKey, logDirectory: URL) {
        self.routes = routes
        self.publicKey = publicKey
        self.logDirectory = logDirectory
    }

    private func respond(to request: Request) -> (response: ScriptedResponse, matched: Bool, number: Int) {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        for (index, route) in routes.enumerated()
            where route.method == request.method && route.path == request.path && route.query.allSatisfy({ request.query.contains($0) }) {
            let seen = hits[index, default: 0]
            hits[index] = seen + 1
            return (route.responses[min(seen, route.responses.count - 1)], true, counter)
        }
        return (ScriptedResponse(status: 599, body: Data(#"{"errors":[{"code":"STUB_NO_ROUTE","title":"no scripted route"}]}"#.utf8)), false, counter)
    }

    private func record(_ request: Request, number: Int, matched: Bool, status: Int) {
        let line = "REQ n=\(number) method=\(request.method) path=\(request.path) "
            + inspectToken(request.authorization, publicKey: publicKey)
            + " matched=\(matched ? "yes" : "no") status=\(status) query=\(request.query)\n"
        lock.lock()
        defer { lock.unlock() }
        if let handle = try? FileHandle(forWritingTo: logDirectory.appendingPathComponent("requests.log")) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        }
        if !request.body.isEmpty {
            try? request.body.write(to: logDirectory.appendingPathComponent("\(number).body"))
        }
    }

    func handle(_ descriptor: Int32) {
        defer { close(descriptor) }
        guard let request = Server.readRequest(descriptor) else { return }
        let (response, matched, number) = respond(to: request)
        record(request, number: number, matched: matched, status: response.status)
        var head = "HTTP/1.1 \(response.status) Stub\r\nContent-Type: application/json\r\n"
        head += "Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        Server.writeAll(descriptor, Data(head.utf8) + response.body)
    }

    static func writeAll(_ descriptor: Int32, _ data: Data) {
        var sent = 0
        data.withUnsafeBytes { raw in
            while sent < data.count {
                let count = send(descriptor, raw.baseAddress! + sent, data.count - sent, 0)
                if count <= 0 { return }
                sent += count
            }
        }
    }

    static func readRequest(_ descriptor: Int32) -> Request? {
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let separator = Data("\r\n\r\n".utf8)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count <= 0 { return nil }
            received.append(buffer, count: count)
            headerEnd = received.range(of: separator)
        }
        guard let end = headerEnd, let head = String(data: received[..<end.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ").map(String.init)
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            if let colon = line.firstIndex(of: ":") {
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        var body = received[end.upperBound...]
        while body.count < length {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count <= 0 { break }
            body.append(buffer, count: count)
        }
        let parts = requestLine[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let query = parts.count > 1 ? (parts[1].removingPercentEncoding ?? parts[1]) : ""
        return Request(method: requestLine[0], path: parts[0], query: query,
                       authorization: headers["authorization"] ?? "", body: Data(body))
    }
}

func loadRoutes(_ path: String) -> [Route] {
    guard let data = FileManager.default.contents(atPath: path),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let list = root["routes"] as? [[String: Any]]
    else { fail("cannot read scenario \(path)") }
    return list.map { entry in
        let responses = (entry["responses"] as? [[String: Any]] ?? []).map { item -> ScriptedResponse in
            let body = item["body"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]) } ?? Data()
            return ScriptedResponse(status: item["status"] as? Int ?? 200, body: body)
        }
        return Route(method: entry["method"] as? String ?? "GET", path: entry["path"] as? String ?? "/",
                     query: entry["query"] as? [String] ?? [],
                     responses: responses.isEmpty ? [ScriptedResponse(status: 200, body: Data())] : responses)
    }
}

func option(_ name: String, in arguments: [String]) -> String {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { fail("missing \(name)") }
    return arguments[index + 1]
}

func keygen(_ directory: String) {
    let key = P256.Signing.PrivateKey()
    do {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try key.pemRepresentation.write(toFile: directory + "/AuthKey.p8", atomically: true, encoding: .utf8)
        try key.publicKey.pemRepresentation.write(toFile: directory + "/public.pem", atomically: true, encoding: .utf8)
    } catch {
        fail("keygen: \(error)")
    }
}

func serve(_ arguments: [String]) {
    let pem = (try? String(contentsOfFile: option("--public-key", in: arguments), encoding: .utf8)) ?? ""
    guard let publicKey = try? P256.Signing.PublicKey(pemRepresentation: pem) else { fail("bad public key") }
    let logDirectory = URL(fileURLWithPath: option("--log", in: arguments), isDirectory: true)
    try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: logDirectory.appendingPathComponent("requests.log").path, contents: nil)
    let server = Server(routes: loadRoutes(option("--scenario", in: arguments)), publicKey: publicKey, logDirectory: logDirectory)

    signal(SIGPIPE, SIG_IGN)
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    var reuse: Int32 = 1
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0, listen(listener, 16) == 0 else { fail("cannot listen on 127.0.0.1") }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
    }
    let port = UInt16(bigEndian: address.sin_port)
    let portFile = option("--port-file", in: arguments)
    try? "\(port)\n".write(toFile: portFile + ".tmp", atomically: false, encoding: .utf8)
    try? FileManager.default.moveItem(atPath: portFile + ".tmp", toPath: portFile)

    while true {
        let connection = accept(listener, nil, nil)
        if connection < 0 { continue }
        DispatchQueue.global().async { server.handle(connection) }
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "keygen" where arguments.count == 2: keygen(arguments[1])
case "serve": serve(arguments)
default: fail("usage: asc-stub keygen <dir> | serve --public-key <pem> --scenario <json> --log <dir> --port-file <file>")
}
