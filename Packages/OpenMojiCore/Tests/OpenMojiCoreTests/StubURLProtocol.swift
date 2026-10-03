import Foundation
import Synchronization
@testable import OpenMojiCore

/// A `URLProtocol` that answers every request from a canned behaviour and
/// records what it was asked.
///
/// `URLProtocol` is class-registered, so the class itself is process-wide, but
/// its state is not: each test makes its own `Stub` and builds its client with
/// `stub.makeClient`, which tags every request from that client's session with
/// the stub's ID. `startLoading` and `stopLoading` look the state up by that
/// ID, so a callback that lands late (URLSession starts a cancelled load, and
/// stops a finished one, on its own queue, after the test has moved on) only
/// ever touches the stub of the test that made the request.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Behavior: Sendable {
        /// Answer with an HTTP response.
        case respond(status: Int, headers: [String: String] = [:], body: Data = Data())
        /// Fail the load with a `URLError`.
        case fail(URLError.Code)
        /// Never answer; only `stopLoading` (cancellation) ends the load.
        case hang
    }

    struct Recorded: Sendable {
        let request: URLRequest
        let body: Data?
    }

    /// One test's behaviour and recordings.
    final class Stub: Sendable {
        private struct State {
            var behavior: Behavior
            var recorded: [Recorded] = []
            var stopLoadingCount = 0
        }

        let id = UUID().uuidString
        private let state: Mutex<State>

        init(_ behavior: Behavior = .hang) {
            state = Mutex(State(behavior: behavior))
            StubURLProtocol.registry.withLock { $0[id] = self }
        }

        /// A client whose session's requests are answered by this stub.
        func makeClient(config: GenerationConfig = GenerationConfig(infoDictionary: [:])) -> OpenAIClient {
            OpenAIClient(
                config: config,
                protocolClasses: [StubURLProtocol.self],
                httpAdditionalHeaders: [StubURLProtocol.idHeader: id]
            )
        }

        /// Clears recordings and sets the behaviour for the next requests.
        func reset(_ behavior: Behavior) {
            state.withLock { $0 = State(behavior: behavior) }
        }

        var recorded: [Recorded] { state.withLock { $0.recorded } }
        var stopLoadingCount: Int { state.withLock { $0.stopLoadingCount } }

        fileprivate func record(_ entry: Recorded) -> Behavior {
            state.withLock { state in
                state.recorded.append(entry)
                return state.behavior
            }
        }

        fileprivate func recordStop() {
            state.withLock { $0.stopLoadingCount += 1 }
        }
    }

    /// The header that carries a `Stub`'s ID on every request it should answer.
    fileprivate static let idHeader = "X-Stub-ID"

    /// Every `Stub` ever made, by ID. Never pruned: a late callback from a
    /// finished test must still find its own stub, and the test process is
    /// short-lived.
    fileprivate static let registry = Mutex<[String: Stub]>([:])

    private static func stub(for request: URLRequest) -> Stub? {
        guard let id = request.value(forHTTPHeaderField: idHeader) else { return nil }
        return registry.withLock { $0[id] }
    }

    // MARK: URLProtocol

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let stub = Self.stub(for: request) else {
            // Every client the tests build is tagged, so this is a test bug.
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let body = Self.readBody(of: request)
        switch stub.record(Recorded(request: request, body: body)) {
        case .respond(let status, let headers, let body):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .hang:
            break
        }
    }

    override func stopLoading() {
        Self.stub(for: request)?.recordStop()
    }

    /// URLSession moves `httpBody` into `httpBodyStream` before the protocol
    /// sees the request, so read whichever is present.
    private static func readBody(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
