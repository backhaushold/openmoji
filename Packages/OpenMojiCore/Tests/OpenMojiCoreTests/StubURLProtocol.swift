import Foundation
import Synchronization

/// A `URLProtocol` that answers every request from a canned behaviour and
/// records what it was asked. State is process-wide (URLProtocol is
/// class-registered), so suites that use it must be `.serialized`.
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

    private struct State {
        var behavior: Behavior = .hang
        var recorded: [Recorded] = []
        var stopLoadingCount = 0
    }

    private static let state = Mutex(State())

    /// Clears recordings and sets the behaviour for the next requests.
    static func reset(_ behavior: Behavior) {
        state.withLock { $0 = State(behavior: behavior) }
    }

    static var recorded: [Recorded] { state.withLock { $0.recorded } }
    static var stopLoadingCount: Int { state.withLock { $0.stopLoadingCount } }

    // MARK: URLProtocol

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.readBody(of: request)
        let behavior = Self.state.withLock { state -> Behavior in
            state.recorded.append(Recorded(request: request, body: body))
            return state.behavior
        }
        switch behavior {
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
        Self.state.withLock { $0.stopLoadingCount += 1 }
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
