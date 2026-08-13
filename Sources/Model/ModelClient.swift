import Foundation

/// The error codes `/v1` answers with, plus the case that keeps a later one
/// from being a crash: a service that grows a code this client has never heard
/// of is still a service, and the status beside it already says what happened.
public enum ServiceErrorCode: Sendable, Equatable {
    /// 503: the endpoint exists and the service has nothing to serve yet.
    case noModel
    /// 500: the artifact on the service's disk is foreign or corrupt.
    case badArtifact
    /// 405: a method that could carry a body. Nothing goes up this wire.
    case methodNotAllowed
    /// 404: not the one endpoint, which includes the one endpoint with a query
    /// string on it.
    case noSuchEndpoint
    case unknown(String)

    public init(wire: String) {
        switch wire {
        case "no-model": self = .noModel
        case "bad-artifact": self = .badArtifact
        case "method-not-allowed": self = .methodNotAllowed
        case "no-such-endpoint": self = .noSuchEndpoint
        default: self = .unknown(wire)
        }
    }

    public var wire: String {
        switch self {
        case .noModel: "no-model"
        case .badArtifact: "bad-artifact"
        case .methodNotAllowed: "method-not-allowed"
        case .noSuchEndpoint: "no-such-endpoint"
        case .unknown(let code): code
        }
    }
}

/// Reads a fitted model from the service that serves one.
///
/// The socket lives in exactly one function. Every decision -- what a status
/// means, what a body means -- is a pure function beside it, which is the
/// split the other side of this seam already made: `serve.py`'s router is one
/// function with no socket in it, and its tests drive that function rather
/// than a port. So the tests here stay network-free by construction rather
/// than by convention, and the repository still has one fetch instead of one
/// per consumer.
///
/// Two versions, of two different things: `skewline-fit/1` tags the payload
/// and `/v1` versions the endpoint set and the error shape. Both are read; the
/// payload's version is never inferred from the path.
public enum ModelClient {
    public static let apiVersion = "v1"

    /// The one endpoint, matching `serve.py`'s `MODEL_PATH`. Exact: the same
    /// path with a query string is not this endpoint, which is what makes
    /// "not a query surface" mechanically true rather than promised.
    public static let modelPath = "/v1/model"

    /// A status and a body to a model, or to the refusal that explains it. No
    /// socket in it.
    public static func outcome(status: Int, body: Data) throws -> FittedModel {
        guard status == 200 else {
            let envelope = try? JSONDecoder().decode(ServiceErrorBody.self, from: body)
            throw ModelReadError(
                kind: .service(status: status, code: envelope.map { ServiceErrorCode(wire: $0.error) }),
                // The code is already in the kind, so the message carries the
                // service's own detail and does not repeat it.
                message: envelope.map(\.detail)
                    ?? "\(status) with no \(apiVersion) error body (\(body.count) bytes)"
            )
        }
        return try FittedModel(decoding: body)
    }

    /// Fetches the model. The only function in this module that touches a
    /// network, and nothing in the test suite calls it.
    ///
    /// Nonisolated: no global actor, so a `MainActor` caller does not drag the
    /// request onto the main thread, and `FittedModel` is `Sendable` so the
    /// result crosses back without a hop.
    public static func fetch(from url: URL, using session: URLSession = .shared) async throws -> FittedModel {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw ModelReadError(
                kind: .unreachable,
                message: "\(url.absoluteString): \(error.localizedDescription)"
            )
        }
        guard let http = response as? HTTPURLResponse else {
            throw ModelReadError(
                kind: .unreachable,
                message: "\(url.absoluteString): the response was not HTTP"
            )
        }
        return try outcome(status: http.statusCode, body: data)
    }

    /// The `/v1` error shape. A 200 carries the payload's own schema tag; an
    /// error carries none, which is why the envelope is versioned by the path.
    private struct ServiceErrorBody: Decodable {
        let error: String
        let detail: String
    }
}
