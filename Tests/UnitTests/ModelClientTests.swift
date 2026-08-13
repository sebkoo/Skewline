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

// MARK: - Naming a refusal

// The names moved out of `SightProbe` when a second reader appeared, and
// arrive with the tests they never had there. A name is what a reader is
// shown when the read fails, so an unnamed case is a screen with nothing on
// it.

/// Every case names itself, and no two share a name: a refusal a reader
/// cannot tell from another refusal is the collapse this module spends four
/// `Estimate` cases and thirteen `Kind` cases refusing.
@Test func everyRefusalHasItsOwnName() {
    let kinds: [ModelReadError.Kind] = [
        .unreachable,
        .service(status: 503, code: .noModel),
        .notJSON,
        .wrongSchema,
        .missingField,
        .wrongUnits,
        .wrongOutsideDomain,
        .malformedDomain,
        .unknownClass,
        .unknownVerdict,
        .malformedForm,
        .malformedFold,
        .malformedTable,
    ]
    let names = kinds.map(\.name)
    #expect(names.allSatisfy { !$0.isEmpty })
    #expect(Set(names).count == kinds.count)
}

/// The status stays beside the code, because a service that grows a code this
/// client has never heard of still answered, and the number says what happened
/// when the name cannot.
@Test func aServiceRefusalCarriesItsStatusIntoTheName() {
    #expect(ModelReadError.Kind.service(status: 503, code: .noModel).name
        == "service 503 no-model")
    #expect(ModelReadError.Kind.service(status: 418, code: .unknown("brewing")).name
        == "service 418 brewing")
    #expect(ModelReadError.Kind.service(status: 502, code: nil).name
        == "service 502 no error body")
}

/// The one a phone reaching a laptop meets first, so it is pinned by itself.
@Test func theTransportFailureIsNamedUnreachable() {
    #expect(ModelReadError.Kind.unreachable.name == "unreachable")
}
