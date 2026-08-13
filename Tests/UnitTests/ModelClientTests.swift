import Testing
import Foundation
import Model

// Every case here goes through `outcome`, which has no socket in it -- the
// same split `serve.py` made when it put the whole router in `resolve`. No
// test in this suite opens a connection, and none needs a service running.

private func refusal(status: Int, body: String) throws -> ModelReadError? {
    do {
        _ = try ModelClient.outcome(status: status, body: Data(body.utf8))
        return nil
    } catch let error as ModelReadError {
        return error
    }
}

private func serviceError(_ code: String, _ detail: String = "a detail") -> String {
    #"{"error": "\#(code)", "detail": "\#(detail)"}"#
}

@Test func theEndpointMatchesTheOneTheServiceServes() {
    // Spelled out rather than derived: if `serve.py`'s MODEL_PATH moves, this
    // is the line that goes red.
    #expect(ModelClient.apiVersion == "v1")
    #expect(ModelClient.modelPath == "/v1/model")
}

@Test func aTwoHundredCarriesTheModel() throws {
    let model = try ModelClient.outcome(status: 200, body: Data(ModelFixture.artifact().utf8))
    #expect(model.depthDomain == 0.5..<5.0)
}

@Test func aTwoHundredWhoseBodyIsNotAnArtifactIsStillRefused() throws {
    #expect(try refusal(status: 200, body: "{}")?.kind == .wrongSchema)
    #expect(try refusal(status: 200, body: "<html>")?.kind == .notJSON)
}

@Test func theServiceHasNoModelYet() throws {
    let refused = try #require(try refusal(
        status: 503,
        body: serviceError("no-model", "no artifact at Fit/model.json yet")
    ))
    #expect(refused.kind == .service(status: 503, code: .noModel))
    #expect(refused.message.contains("no artifact"))
}

@Test func eachRegisteredServiceCodeArrivesNamed() throws {
    #expect(try refusal(status: 500, body: serviceError("bad-artifact"))?.kind
        == .service(status: 500, code: .badArtifact))
    #expect(try refusal(status: 405, body: serviceError("method-not-allowed"))?.kind
        == .service(status: 405, code: .methodNotAllowed))
    #expect(try refusal(status: 404, body: serviceError("no-such-endpoint"))?.kind
        == .service(status: 404, code: .noSuchEndpoint))
}

/// A service that grows a code this client has never heard of is still a
/// service, and the status beside it already says what happened.
@Test func anUnheardOfServiceCodeIsCarriedRatherThanCrashed() throws {
    #expect(try refusal(status: 418, body: serviceError("brewing"))?.kind
        == .service(status: 418, code: .unknown("brewing")))
}

@Test func aNonTwoHundredWithoutTheErrorShapeSaysSoRatherThanGuessing() throws {
    let refused = try #require(try refusal(status: 502, body: "<html>gateway</html>"))
    #expect(refused.kind == .service(status: 502, code: nil))
    #expect(refused.message.contains("502"))
}

@Test func theWireSpellingRoundTrips() {
    for code: ServiceErrorCode in [.noModel, .badArtifact, .methodNotAllowed, .noSuchEndpoint] {
        #expect(ServiceErrorCode(wire: code.wire) == code)
    }
    #expect(ServiceErrorCode(wire: "brewing") == .unknown("brewing"))
    #expect(ServiceErrorCode.unknown("brewing").wire == "brewing")
}
