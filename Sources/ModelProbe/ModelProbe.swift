import Foundation
import Model

/// Reads a fitted model -- from the running service or from a file -- and
/// prints what came back: the artifact's own account of itself, every class's
/// verdict with the folds that produced it, and what the model actually
/// answers across a fixed depth ladder.
///
/// An argument with an `http` or `https` scheme is fetched over the wire;
/// anything else is a path on disk. Both reach the same decoder, which is why
/// the two print identical deterministic blocks -- the file case is the same
/// client with the network taken out.
///
/// The report is paired blocks, the RenderProbe pattern: the deterministic
/// blocks byte-reproduce across runs on one machine -- fixed class order,
/// sorted form names, fixed-format floats -- while the timing block is labeled
/// non-deterministic and is only meaningful from a release build.
///
/// `@main` on a struct rather than top-level code in `main.swift`: top-level
/// code is `MainActor`-isolated, and nothing here wants an actor.
@main
struct ModelProbe {
    /// The registered ladder -- `fit.DEPTH_LADDER`, registered in
    /// docs/DEVLOG.md under v0.8 commit 2 -- straddling both edges of the
    /// depth domain so a single run shows what answers and what refuses.
    ///
    /// This is the mirror, not the declaration: Swift cannot read a Python
    /// constant, so `Fit/test_fit.py` reads these eight numbers back out of
    /// this file and pins them equal to the ones the page renders.
    static let depths: [Double] = [0.4, 0.5, 1.0, 2.0, 3.0, 4.9, 5.0, 6.0]

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty else {
            FileHandle.standardError.write(Data(
                "usage: ModelProbe <http://host:port\(ModelClient.modelPath) | model.json> ...\n".utf8
            ))
            exit(64)
        }
        #if DEBUG
        print("warning: debug build -- the timing below is the optimizer's absence, not the decoder's bill")
        #endif
        var failed = false
        for source in arguments {
            do {
                try await report(on: source)
            } catch let refusal as ModelReadError {
                FileHandle.standardError.write(Data(
                    "error: \(source): \(name(of: refusal.kind)) -- \(refusal.message)\n".utf8
                ))
                failed = true
            } catch {
                FileHandle.standardError.write(Data("error: \(source): \(error)\n".utf8))
                failed = true
            }
        }
        if failed {
            exit(1)
        }
    }

    static func report(on source: String) async throws {
        let clock = ContinuousClock()
        let url = URL(string: source)
        let overTheWire = url?.scheme == "http" || url?.scheme == "https"

        let start = clock.now
        let model: FittedModel
        if overTheWire, let url {
            model = try await ModelClient.fetch(from: url)
        } else {
            model = try FittedModel(decoding: try Data(contentsOf: URL(filePath: source)))
        }
        let elapsed = start.duration(to: clock.now)

        // The transport is the only thing above the deterministic blocks,
        // because it is the only thing the two sources may differ about: a
        // fetched model and a read one print the same blocks below, which is
        // the claim worth being able to check with `diff`. No payload byte
        // count is printed -- the client hands back a model rather than a
        // body, and inventing a second fetch to count bytes would be a second
        // request for a number nothing needs.
        print("source \(source)")
        print(row("transport", overTheWire ? "\(ModelClient.apiVersion) over HTTP" : "file"))
        print("  --- artifact (deterministic) ---")
        print(row("schema", FittedModel.schemaTag))
        print(row("units", FittedModel.units))
        print(row("outside domain", FittedModel.outsideDomain))
        print(row("depth domain", bound(model.depthDomain.lowerBound) + " ..< " + bound(model.depthDomain.upperBound) + " m"))
        print(row("estimand", model.estimand))
        print(row("trained on", "\(model.trainedOn.count) sessions"))
        for entry in model.export {
            print("    \(entry.session)  decimation \(entry.decimation)")
        }

        print("  --- classes (deterministic) ---")
        for confidence in ConfidenceClass.allCases {
            let classModel = model.classes[confidence]
            switch classModel.verdict {
            case .adopted(let form):
                print(row(confidence.rawValue, "adopted \(form.name)  \(coefficients(of: form))"))
            case .refused(let table):
                print(row(confidence.rawValue, "refused -- keeps its banded table"))
                for band in table.medians.indices {
                    let median = table.medians[band].map(fixed) ?? "no samples"
                    print(row("  band [\(bound(table.edges[band])), \(bound(table.edges[band + 1])))", median))
                }
            }
            // Folds are printed without the padded label column: a session
            // UUID is longer than it, and a truncated holdout name is worse
            // than a ragged line. Form names are sorted, because a dictionary
            // has no order and this block claims to be deterministic.
            for fold in classModel.folds {
                let forms = fold.forms.keys.sorted().map { name -> String in
                    switch fold.forms[name] {
                    case .scored(let metric, let margin):
                        "\(name) \(fixed(metric)) (margin \(signed(margin)))"
                    case .disqualified:
                        "\(name) disqualified"
                    case nil:
                        "\(name) ?"
                    }
                }
                print("    holdout \(fold.holdout)  table \(fixed(fold.tableMetric))  "
                    + forms.joined(separator: "  "))
            }
        }

        print("  --- median pairwise disagreement, meters (deterministic) ---")
        for depth in depths {
            let answers = ConfidenceClass.allCases.map { confidence -> String in
                switch model.estimate(for: confidence, atDepthMeters: depth) {
                case .fromAdoptedForm(let meters): "\(confidence.rawValue) \(fixed(meters))"
                case .fromBandedTable(let meters): "\(confidence.rawValue) \(fixed(meters)) (table)"
                case .refusedBandWithoutSamples: "\(confidence.rawValue) refused: band without samples"
                case .refusedOutsideDepthDomain: "\(confidence.rawValue) refused: outside the domain"
                }
            }
            print(row("depth \(bound(depth)) m", answers.joined(separator: "  ")))
        }

        #if DEBUG
        let build = "debug build"
        #else
        let build = "release build"
        #endif
        print("  --- timing (\(build); not deterministic) ---")
        let seconds = elapsed / .seconds(1)
        print(row(overTheWire ? "fetch and decode" : "read and decode", String(format: "%.1f ms", seconds * 1000)))
        print("")
    }

    static func coefficients(of form: Form) -> String {
        switch form {
        case .affine(let a, let b), .quadratic(let a, let b):
            "a=\(fixed(a)) b=\(fixed(b))"
        case .power(let a, let p):
            "a=\(fixed(a)) p=\(fixed(p))"
        }
    }

    /// The refusal by name, so a failing run says which rejection it was
    /// rather than printing a struct.
    static func name(of kind: ModelReadError.Kind) -> String {
        switch kind {
        case .unreachable: "unreachable"
        case .service(let status, let code): "service \(status) \(code?.wire ?? "no error body")"
        case .notJSON: "not JSON"
        case .wrongSchema: "wrong schema"
        case .missingField: "missing field"
        case .wrongUnits: "wrong units"
        case .wrongOutsideDomain: "wrong outside-domain behavior"
        case .malformedDomain: "malformed depth domain"
        case .unknownClass: "unknown class"
        case .unknownVerdict: "unknown verdict"
        case .malformedForm: "malformed form"
        case .malformedFold: "malformed fold"
        case .malformedTable: "malformed table"
        }
    }

    /// Six decimals for a metric or a coefficient: the scale the fit's own
    /// transcript prints them at. Not a margin -- a margin carries its sign
    /// and goes through `signed`.
    private static func fixed(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    /// Two decimals for a depth or a band edge -- a fixed format, because a
    /// block that claims to be deterministic cannot print a float the way
    /// Swift feels like printing it.
    private static func bound(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// Six decimals with the sign always printed, for a margin -- the third
    /// format, and it exists because the sign is the finding: `+0.000003`
    /// beside `-0.000003` makes the flip across folds unmissable, where a
    /// magnitude alone would read as agreement.
    private static func signed(_ value: Double) -> String {
        String(format: "%+.6f", value)
    }

    private static func row(_ label: String, _ value: String) -> String {
        "  " + label.padding(toLength: 26, withPad: " ", startingAt: 0) + value
    }
}
