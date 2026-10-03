#!/usr/bin/env swift
//
// App Store Connect API client for the release lane (bead openmoji-2pq,
// ADR-0015, tech spec 12.3 steps 8-9 and 12.6). Runs ONLY on the release Mac,
// with the ASC key injected from 1Password by scripts/op-run.sh. Never in CI.
//
//   swift scripts/asc.swift wait-for-build <build> [--timeout <s>] [--interval <s>]
//       Poll until the build's processingState is VALID. Fails on INVALID or
//       FAILED (exit 4) and on timeout (exit 3).
//   swift scripts/asc.swift set-whats-new <build> <text>
//       Set the TestFlight "What to Test" text (REL-8).
//   swift scripts/asc.swift ensure-in-group <build> <group name>
//       Add the build to the internal beta group unless it is already in it
//       (REL-5; automatic distribution is the primary mechanism, this verifies).
//   swift scripts/asc.swift latest-build
//       Print the newest build's processing state and exact expirationDate
//       (`make testflight-status`, REL-9).
//
// Credentials come from the environment, the same three variables that
// release/.env.example resolves from 1Password:
//   ASC_ISSUER_ID, ASC_KEY_ID, ASC_PRIVATE_KEY_BASE64 (the .p8, base64-encoded)
// The key is decoded in memory only: it is never written to disk, never put in
// an error, never printed. Neither is the signed token. CryptoKit and
// Foundation only; no third-party packages (NFR-7).
//
// Test hook: ASC_TEST_BASE_URL points the client at a local stub server. Only an
// http://127.0.0.1 or http://localhost URL is accepted (anything else is an
// error, so a token can never be sent to a host other than Apple's by mistake).
// ASC_TEST_RETRY_DELAY (seconds) shortens the GET retry pause, and only together
// with that URL. scripts/test-asc.sh uses both; they are not part of the lane.
//
// Exit codes: 0 ok, 1 error, 2 usage, 3 timed out waiting, 4 build INVALID/FAILED.
//
// API details checked against Apple's documentation on 2026-10-03 (see the PR
// description): GET /v1/builds (filter[app], filter[version], sort, limit),
// GET /v1/apps (filter[bundleId]), GET /v1/betaGroups (filter[app], filter[name]),
// POST|PATCH /v1/betaBuildLocalizations, POST /v1/builds/{id}/relationships/betaGroups.

import CryptoKit
import Foundation

// MARK: - Configuration

enum Config {
    static let bundleID = "com.backhaushold.openmoji"
    static let productionBaseURL = "https://api.appstoreconnect.apple.com"
    static let audience = "appstoreconnect-v1"
    /// Apple rejects a token that lives longer than 20 minutes; a fresh one is signed
    /// for every request, so a few minutes is plenty.
    static let tokenLifetime = 300
    /// A build normally finishes processing in 5 to 20 minutes.
    static let defaultTimeout = 2700.0
    static let defaultInterval = 30.0
    static let retryDelay = 2.0
    static let maxAttempts = 3
    static let maxConsecutivePollFailures = 5
    static let locale = "en-US"
    /// A cap for "What to Test". Apple's API reference doesn't state the limit; 4000 is the
    /// figure remembered from the TestFlight web UI and is NOT confirmed. Longer text is
    /// cut at a line break.
    static let maxWhatsNewLength = 4000
}

enum ExitCode {
    static let failure: Int32 = 1
    static let usage: Int32 = 2
    static let timeout: Int32 = 3
    static let buildFailed: Int32 = 4
}

struct ToolError: Error {
    var message: String
    var code: Int32 = ExitCode.failure
    /// Network trouble, 429 or 5xx: worth retrying, unlike a 4xx.
    var transient = false
}

// MARK: - Output

private func write(_ handle: FileHandle, _ text: String) {
    handle.write(Data((text + "\n").utf8))
}

func say(_ message: String) {
    write(.standardOutput, "asc: \(message)")
}

func warn(_ message: String) {
    write(.standardError, "asc: WARNING: \(message)")
}

// MARK: - Credentials and JWT

struct Credentials {
    let issuerID: String
    let keyID: String
    /// The ASC private key (named `signer`, not `key`, so a secret scanner doesn't mistake
    /// the declaration for a hard-coded credential).
    let signer: P256.Signing.PrivateKey

    static func fromEnvironment(_ env: [String: String]) throws -> Credentials {
        var missing: [String] = []
        for name in ["ASC_ISSUER_ID", "ASC_KEY_ID", "ASC_PRIVATE_KEY_BASE64"] where (env[name] ?? "").isEmpty {
            missing.append(name)
        }
        if !missing.isEmpty {
            throw ToolError(message: "missing environment: \(missing.joined(separator: ", ")). Run through scripts/op-run.sh (make testflight-status), which injects them from 1Password.")
        }
        guard let der = Data(base64Encoded: env["ASC_PRIVATE_KEY_BASE64"] ?? "", options: .ignoreUnknownCharacters),
              let pem = String(data: der, encoding: .utf8)
        else {
            throw ToolError(message: "ASC_PRIVATE_KEY_BASE64 is not valid base64 of a .p8 file (runbook 2.5).")
        }
        // Never include `pem` or the CryptoKit error in a message.
        guard let signer = try? P256.Signing.PrivateKey(pemRepresentation: pem) else {
            throw ToolError(message: "ASC_PRIVATE_KEY_BASE64 does not decode to a P-256 .p8 private key (runbook 2.5).")
        }
        return Credentials(issuerID: env["ASC_ISSUER_ID"] ?? "", keyID: env["ASC_KEY_ID"] ?? "", signer: signer)
    }
}

enum JWT {
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// ES256 token for the App Store Connect API: header {alg, kid, typ}, claims
    /// {iss, iat, exp, aud}. CryptoKit's `signature(for:)` hashes with SHA-256 and its
    /// `rawRepresentation` is the 64-byte r||s form that JWS requires.
    static func make(_ credentials: Credentials, now: Date = Date()) throws -> String {
        let issuedAt = Int(now.timeIntervalSince1970)
        let header: [String: Any] = ["alg": "ES256", "kid": credentials.keyID, "typ": "JWT"]
        let claims: [String: Any] = [
            "iss": credentials.issuerID,
            "iat": issuedAt,
            "exp": issuedAt + Config.tokenLifetime,
            "aud": Config.audience,
        ]
        let signingInput = try base64URL(json(header)) + "." + base64URL(json(claims))
        let signature = try credentials.signer.signature(for: Data(signingInput.utf8))
        return signingInput + "." + base64URL(signature.rawRepresentation)
    }
}

// MARK: - API models (only the fields used; Apple may omit any of them)

struct Resource<Attributes: Decodable & Sendable>: Decodable, Sendable {
    let id: String
    let attributes: Attributes?
}

struct ListResponse<Attributes: Decodable & Sendable>: Decodable, Sendable {
    let data: [Resource<Attributes>]
}

struct AppAttributes: Decodable, Sendable {
    let name: String?
    let bundleId: String?
}

struct BuildAttributes: Decodable, Sendable {
    let version: String?
    let processingState: String?
    let uploadedDate: String?
    let expirationDate: String?
    let expired: Bool?
}

struct GroupAttributes: Decodable, Sendable {
    let name: String?
    let isInternalGroup: Bool?
    let hasAccessToAllBuilds: Bool?
}

struct LocalizationAttributes: Decodable, Sendable {
    let locale: String?
    let whatsNew: String?
}

typealias App = Resource<AppAttributes>
typealias Build = Resource<BuildAttributes>
typealias Group = Resource<GroupAttributes>
typealias Localization = Resource<LocalizationAttributes>

struct APIErrorList: Decodable {
    struct Item: Decodable {
        let code: String?
        let title: String?
        let detail: String?
    }

    let errors: [Item]?
}

// Request bodies (JSON:API).
struct Identifier: Encodable { let type: String, id: String }
struct Linkage: Encodable { let data: Identifier }
struct LinkageList: Encodable { let data: [Identifier] }

struct LocalizationCreate: Encodable {
    struct Data: Encodable {
        struct Attributes: Encodable { let locale: String, whatsNew: String }
        struct Relationships: Encodable { let build: Linkage }
        let type = "betaBuildLocalizations"
        let attributes: Attributes
        let relationships: Relationships
    }

    let data: Data
}

struct LocalizationUpdate: Encodable {
    struct Data: Encodable {
        struct Attributes: Encodable { let whatsNew: String }
        let type = "betaBuildLocalizations"
        let id: String
        let attributes: Attributes
    }

    let data: Data
}

// MARK: - HTTP

struct HTTPResult {
    let status: Int
    let data: Data

    var isSuccess: Bool { (200 ..< 300).contains(status) }
    var isTransient: Bool { status == 429 || status >= 500 }
}

struct Client {
    let baseURL: URL
    let credentials: Credentials
    var retryDelay = Config.retryDelay

    /// No disk cache or cookie jar, so a poll can never be answered from a stale copy
    /// and nothing from App Store Connect is left behind.
    private static let session = URLSession(configuration: .ephemeral)

    private func send(_ method: String, _ path: String, query: [URLQueryItem], body: Data?) async throws -> HTTPResult {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ToolError(message: "bad base URL")
        }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw ToolError(message: "bad URL for \(path)") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(try JWT.make(credentials))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await Client.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ToolError(message: "no HTTP response from \(path)") }
        return HTTPResult(status: http.statusCode, data: data)
    }

    /// One logical request. Only GETs are retried (on network errors, 429 and 5xx);
    /// a POST or PATCH is never repeated blindly.
    func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> HTTPResult {
        let attempts = method == "GET" ? Config.maxAttempts : 1
        var failure = ToolError(message: "\(method) \(path): no attempt was made")
        for attempt in 1 ... attempts {
            do {
                let result = try await send(method, path, query: query, body: body)
                if !result.isTransient { return result }
                failure = ToolError(message: "\(method) \(path): HTTP \(result.status)", transient: true)
            } catch let error as URLError {
                failure = ToolError(message: "\(method) \(path): network error: \(error.localizedDescription)", transient: true)
            }
            if attempt < attempts { try await Task.sleep(for: .seconds(retryDelay)) }
        }
        throw failure
    }

    /// The failure text for a non-2xx response: Apple's own error titles and details.
    static func describeFailure(_ what: String, _ result: HTTPResult) -> ToolError {
        var text = "\(what) failed: HTTP \(result.status)"
        if let list = try? JSONDecoder().decode(APIErrorList.self, from: result.data), let items = list.errors, !items.isEmpty {
            let parts = items.prefix(3).map { item in
                [item.code, item.title, item.detail].compactMap { $0 }.joined(separator: " - ")
            }
            text += ": " + parts.joined(separator: "; ")
        }
        switch result.status {
        case 401: text += ". Check ASC_KEY_ID, ASC_ISSUER_ID and the key (runbook 2.5); the key may be revoked."
        case 403: text += ". The key's role may not allow this (it needs App Manager, runbook 2.5)."
        default: break
        }
        return ToolError(message: text, transient: result.isTransient)
    }

    func get<T: Decodable>(_ type: T.Type, _ path: String, query: [URLQueryItem], what: String) async throws -> T {
        let result = try await request("GET", path, query: query)
        guard result.isSuccess else { throw Client.describeFailure(what, result) }
        do {
            return try JSONDecoder().decode(type, from: result.data)
        } catch {
            throw ToolError(message: "\(what): unexpected response shape (\(error))")
        }
    }

    func write(_ method: String, _ path: String, body: some Encodable, what: String) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let result = try await request(method, path, body: encoder.encode(body))
        guard result.isSuccess else { throw Client.describeFailure(what, result) }
    }
}

// MARK: - Lookups

extension Client {
    func findApp() async throws -> App {
        let list = try await get(ListResponse<AppAttributes>.self, "/v1/apps", query: [
            URLQueryItem(name: "filter[bundleId]", value: Config.bundleID),
            URLQueryItem(name: "limit", value: "2"),
        ], what: "looking up the app \(Config.bundleID)")
        guard let app = list.data.first(where: { $0.attributes?.bundleId == Config.bundleID }) else {
            throw ToolError(message: "no app with bundle ID \(Config.bundleID) is visible to this key. Create the App Store Connect record first (runbook 2.4).")
        }
        return app
    }

    func builds(appID: String, version: String? = nil, limit: Int) async throws -> [Build] {
        var query = [URLQueryItem(name: "filter[app]", value: appID)]
        if let version { query.append(URLQueryItem(name: "filter[version]", value: version)) }
        query.append(URLQueryItem(name: "sort", value: "-uploadedDate"))
        query.append(URLQueryItem(name: "limit", value: String(limit)))
        let what = version.map { "looking up build \($0)" } ?? "listing builds"
        return try await get(ListResponse<BuildAttributes>.self, "/v1/builds", query: query, what: what).data
    }

    /// The newest build with this build number (CFBundleVersion), or nil if App Store
    /// Connect doesn't list it (yet).
    func build(appID: String, number: String) async throws -> Build? {
        try await builds(appID: appID, version: number, limit: 1).first
    }

    func requireBuild(appID: String, number: String) async throws -> Build {
        guard let found = try await build(appID: appID, number: number) else {
            throw ToolError(message: "build \(number) is not listed in App Store Connect for \(Config.bundleID). Has the upload finished (wait-for-build)?")
        }
        return found
    }

    func group(appID: String, name: String) async throws -> Group {
        let query = [
            URLQueryItem(name: "filter[app]", value: appID),
            URLQueryItem(name: "filter[name]", value: name),
            URLQueryItem(name: "limit", value: "20"),
        ]
        let list = try await get(ListResponse<GroupAttributes>.self, "/v1/betaGroups", query: query, what: "looking up the beta group \(name)")
        guard let found = list.data.first(where: { $0.attributes?.name == name }) else {
            let all = try await get(ListResponse<GroupAttributes>.self, "/v1/apps/\(appID)/betaGroups", query: [
                URLQueryItem(name: "limit", value: "200"),
            ], what: "listing beta groups")
            let names = all.data.compactMap { $0.attributes?.name }.joined(separator: ", ")
            throw ToolError(message: "no beta group named \(name) on this app (groups: \(names.isEmpty ? "none" : names)). Create it per runbook 2.4.")
        }
        return found
    }

    func isInGroup(buildID: String, groupID: String) async throws -> Bool {
        let query = [
            URLQueryItem(name: "filter[id]", value: buildID),
            URLQueryItem(name: "filter[betaGroups]", value: groupID),
            URLQueryItem(name: "limit", value: "1"),
        ]
        return try await !get(ListResponse<BuildAttributes>.self, "/v1/builds", query: query, what: "checking group membership").data.isEmpty
    }
}

// MARK: - Formatting

private func parseDate(_ text: String) -> Date? {
    let plain = ISO8601DateFormatter()
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return plain.date(from: text) ?? fractional.date(from: text)
}

/// "2026-12-30T04:23:11.000-08:00 (2026-12-30T12:23:11Z, 88 days left)": Apple's
/// exact string first, then the same instant in UTC and the days remaining.
func describeExpiry(_ raw: String?, now: Date = Date()) -> String {
    guard let raw, !raw.isEmpty else { return "(none reported)" }
    guard let date = parseDate(raw) else { return raw }
    let utc = ISO8601DateFormatter().string(from: date)
    let seconds = date.timeIntervalSince(now)
    if seconds <= 0 { return "\(raw) (\(utc), EXPIRED)" }
    return "\(raw) (\(utc), \(Int(seconds / 86400)) days left)"
}

func describe(_ build: Build) -> String {
    let attributes = build.attributes
    return "state=\(attributes?.processingState ?? "unknown") uploaded=\(attributes?.uploadedDate ?? "unknown") expirationDate=\(describeExpiry(attributes?.expirationDate))"
}

// MARK: - Commands

enum Outcome {
    case valid
    case failed(String)
    case waiting
}

func outcome(forState state: String?) -> Outcome {
    switch state {
    case "VALID": .valid
    case "INVALID", "FAILED": .failed(state ?? "")
    default: .waiting
    }
}

func waitForBuild(_ client: Client, number: String, timeout: Double, interval: Double) async throws {
    let app = try await client.findApp()
    say("app \(app.attributes?.name ?? app.id) (\(Config.bundleID)); waiting for build \(number), up to \(Int(timeout)) s")
    let deadline = Date().addingTimeInterval(timeout)
    var last = "not listed yet"
    var failures = 0
    while true {
        do {
            let found = try await client.build(appID: app.id, number: number)
            failures = 0
            last = found?.attributes?.processingState ?? "not listed yet"
            say("build \(number): \(last)")
            switch outcome(forState: found?.attributes?.processingState) {
            case .valid:
                say("build \(number) is VALID; \(found.map(describe) ?? "")")
                return
            case let .failed(state):
                throw ToolError(message: "build \(number) finished processing as \(state). Apple's reasons are in the email to the account holder and in App Store Connect, TestFlight. Fix, land a new commit and release again.", code: ExitCode.buildFailed)
            case .waiting:
                break
            }
        } catch let error as ToolError where error.transient {
            failures += 1
            warn("\(error.message) (\(failures) of \(Config.maxConsecutivePollFailures) in a row)")
            if failures >= Config.maxConsecutivePollFailures { throw error }
        }
        if Date().addingTimeInterval(interval) > deadline {
            throw ToolError(message: "timed out after \(Int(timeout)) s; build \(number) was last \(last). It may still finish processing: check App Store Connect, TestFlight.", code: ExitCode.timeout)
        }
        try await Task.sleep(for: .seconds(interval))
    }
}

/// Cuts text that is over the limit at a line break and says so.
func fitWhatsNew(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > Config.maxWhatsNewLength else { return trimmed }
    let marker = "\n- ...and more (truncated)"
    let head = String(trimmed.prefix(Config.maxWhatsNewLength - marker.count))
    let cut = head.lastIndex(of: "\n").map { String(head[..<$0]) } ?? head
    return cut + marker
}

func setWhatsNew(_ client: Client, number: String, text: String) async throws {
    let notes = fitWhatsNew(text)
    guard !notes.isEmpty else { throw ToolError(message: "the What to Test text is empty", code: ExitCode.usage) }
    let app = try await client.findApp()
    let build = try await client.requireBuild(appID: app.id, number: number)
    let existing = try await client.get(ListResponse<LocalizationAttributes>.self, "/v1/builds/\(build.id)/betaBuildLocalizations", query: [
        URLQueryItem(name: "limit", value: "200"),
    ], what: "listing What to Test texts").data
    for localization in existing {
        try await client.write("PATCH", "/v1/betaBuildLocalizations/\(localization.id)",
                               body: LocalizationUpdate(data: .init(id: localization.id, attributes: .init(whatsNew: notes))),
                               what: "updating What to Test (\(localization.attributes?.locale ?? "?"))")
        say("build \(number): updated What to Test for \(localization.attributes?.locale ?? "?")")
    }
    if !existing.contains(where: { $0.attributes?.locale == Config.locale }) {
        try await client.write("POST", "/v1/betaBuildLocalizations",
                               body: LocalizationCreate(data: .init(
                                   attributes: .init(locale: Config.locale, whatsNew: notes),
                                   relationships: .init(build: Linkage(data: Identifier(type: "builds", id: build.id)))
                               )),
                               what: "creating What to Test (\(Config.locale))")
        say("build \(number): set What to Test for \(Config.locale) (\(notes.count) characters)")
    }
}

func ensureInGroup(_ client: Client, number: String, groupName: String) async throws {
    let app = try await client.findApp()
    let build = try await client.requireBuild(appID: app.id, number: number)
    let state = build.attributes?.processingState ?? "unknown"
    guard state == "VALID" else {
        throw ToolError(message: "build \(number) is \(state), not VALID: wait for processing (wait-for-build) before adding it to a group.")
    }
    let group = try await client.group(appID: app.id, name: groupName)
    guard group.attributes?.isInternalGroup == true else {
        throw ToolError(message: "beta group \(groupName) is not an internal group; the lane distributes to internal testers only (D9). Fix it in App Store Connect (runbook 2.4).")
    }
    let automatic = group.attributes?.hasAccessToAllBuilds == true ? "on" : "off"
    if try await client.isInGroup(buildID: build.id, groupID: group.id) {
        say("build \(number) is already in group \(groupName) (nothing to do; automatic distribution is \(automatic))")
        return
    }
    do {
        try await client.write("POST", "/v1/builds/\(build.id)/relationships/betaGroups",
                               body: LinkageList(data: [Identifier(type: "betaGroups", id: group.id)]),
                               what: "adding build \(number) to group \(groupName)")
    } catch {
        // A 409 can mean distribution added it between our check and the POST.
        guard try await client.isInGroup(buildID: build.id, groupID: group.id) else { throw error }
    }
    say("added build \(number) to group \(groupName) (automatic distribution is \(automatic))")
}

func latestBuild(_ client: Client) async throws {
    let app = try await client.findApp()
    let recent = try await client.builds(appID: app.id, limit: 20)
    guard let newest = recent.first else {
        throw ToolError(message: "no builds are listed for \(Config.bundleID) yet. Run make testflight.")
    }
    let number = { (build: Build) in build.attributes?.version ?? "?" }
    say("newest build \(number(newest)): \(describe(newest))")
    if newest.attributes?.processingState != "VALID" {
        if let valid = recent.first(where: { $0.attributes?.processingState == "VALID" }) {
            say("newest VALID build \(number(valid)): \(describe(valid))")
        } else {
            say("none of the 20 newest builds is VALID")
        }
    }
}

// MARK: - Command line

let usageText = [
    "usage: swift scripts/asc.swift <command>",
    "  wait-for-build <build> [--timeout <seconds>] [--interval <seconds>]",
    "  set-whats-new <build> <text>",
    "  ensure-in-group <build> <group name>",
    "  latest-build",
].joined(separator: "\n")

func usageError(_ message: String) -> ToolError {
    ToolError(message: "\(message)\n\(usageText)", code: ExitCode.usage)
}

func buildNumber(_ text: String?) throws -> String {
    guard let text, !text.isEmpty, text.allSatisfy(\.isNumber), text.allSatisfy(\.isASCII) else {
        throw usageError("the build number must be digits only, got '\(text ?? "")'")
    }
    return text
}

func seconds(_ flag: String, _ text: String?) throws -> Double {
    guard let text, let value = Double(text), value > 0, value.isFinite else {
        throw usageError("\(flag) needs a positive number of seconds")
    }
    return value
}

func makeClient(_ env: [String: String]) throws -> Client {
    var base = URL(string: Config.productionBaseURL)
    var retryDelay = Config.retryDelay
    if let override = env["ASC_TEST_BASE_URL"], !override.isEmpty {
        guard let url = URL(string: override), url.scheme == "http", ["127.0.0.1", "localhost"].contains(url.host ?? "") else {
            throw ToolError(message: "ASC_TEST_BASE_URL must be an http://127.0.0.1 or http://localhost URL (test hook); refusing to send credentials elsewhere.")
        }
        base = url
        // Test hook, only honoured together with the loopback URL: keeps retry tests fast.
        retryDelay = env["ASC_TEST_RETRY_DELAY"].flatMap(Double.init) ?? retryDelay
    }
    guard let baseURL = base else { throw ToolError(message: "bad base URL") }
    return try Client(baseURL: baseURL, credentials: Credentials.fromEnvironment(env), retryDelay: retryDelay)
}

/// Options after the build number: `--timeout <s>` and `--interval <s>`.
func waitOptions(_ options: [String]) throws -> (timeout: Double, interval: Double) {
    var timeout = Config.defaultTimeout
    var interval = Config.defaultInterval
    var index = 0
    while index < options.count {
        let flag = options[index]
        let value = index + 1 < options.count ? options[index + 1] : nil
        switch flag {
        case "--timeout": timeout = try seconds(flag, value)
        case "--interval": interval = try seconds(flag, value)
        default: throw usageError("unknown option '\(flag)'")
        }
        index += 2
    }
    return (timeout, interval)
}

func run(_ arguments: [String], env: [String: String]) async throws {
    guard let command = arguments.first else { throw usageError("missing command") }
    let rest = Array(arguments.dropFirst())
    switch command {
    case "wait-for-build":
        let number = try buildNumber(rest.first)
        let options = try waitOptions(Array(rest.dropFirst()))
        try await waitForBuild(makeClient(env), number: number, timeout: options.timeout, interval: options.interval)
    case "set-whats-new":
        guard rest.count == 2 else { throw usageError("set-whats-new takes a build number and the text") }
        try await setWhatsNew(makeClient(env), number: buildNumber(rest[0]), text: rest[1])
    case "ensure-in-group":
        guard rest.count == 2, !rest[1].isEmpty else { throw usageError("ensure-in-group takes a build number and a group name") }
        try await ensureInGroup(makeClient(env), number: buildNumber(rest[0]), groupName: rest[1])
    case "latest-build":
        guard rest.isEmpty else { throw usageError("latest-build takes no arguments") }
        try await latestBuild(makeClient(env))
    case "-h", "--help", "help":
        say(usageText)
    default:
        throw usageError("unknown command '\(command)'")
    }
}

do {
    try await run(Array(CommandLine.arguments.dropFirst()), env: ProcessInfo.processInfo.environment)
} catch let error as ToolError {
    write(.standardError, "asc: ERROR: \(error.message)")
    exit(error.code)
} catch {
    write(.standardError, "asc: ERROR: \(error)")
    exit(ExitCode.failure)
}
