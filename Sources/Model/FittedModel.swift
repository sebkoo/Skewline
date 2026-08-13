import Foundation

/// Why a read was refused, one case per rejection this module can make, so a
/// test can pin the exact refusal and a caller can tell a service that has no
/// model yet from an artifact whose shape it cannot believe. The message
/// carries the offending field, form or status.
public struct ModelReadError: Error, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The transport never produced an HTTP response.
        case unreachable
        /// A non-200 in the `/v1` error shape. `code` is `nil` when the body
        /// was not that shape at all.
        case service(status: Int, code: ServiceErrorCode?)
        case notJSON
        /// The `schema` field was absent or was not `skewline-fit/1`. Checked
        /// before any other field is read.
        case wrongSchema
        case missingField
        /// `units` was not `meters`, whose meaning this module hard-codes.
        case wrongUnits
        /// `outsideDomain` was not `refuse`, whose meaning this module
        /// hard-codes.
        case wrongOutsideDomain
        case malformedDomain
        case unknownClass
        case unknownVerdict
        /// An unnameable form, or coefficients that are not exactly the ones
        /// that form is evaluated from.
        case malformedForm
        /// A fold entry that is neither a scored form nor a disqualified one.
        case malformedFold
        case malformedTable
    }

    public let kind: Kind
    public let message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}

/// The three registered confidence classes, spelled as `fit.py`'s
/// `CLASS_NAMES` spells them and iterated in that same order.
///
/// This module owns this type rather than importing one. Joining a model to
/// rendered points is the consumer's edge, so nothing here knows about
/// `Render`'s integer confidence class or about `ConfidencePoint`.
public enum ConfidenceClass: String, Sendable, Equatable, CaseIterable {
    case low, medium, high
}

/// One adopted continuous form, with the coefficients that form is actually
/// evaluated from. The coefficients are form-dependent -- `affine` and
/// `quadratic` carry `{a, b}` while `power` carries `{a, p}` -- so they ride
/// the case rather than sitting in a dictionary a caller has to know how to
/// read.
public enum Form: Sendable, Equatable {
    /// a + b·d
    case affine(a: Double, b: Double)
    /// a + b·d²
    case quadratic(a: Double, b: Double)
    /// a·d^p
    case power(a: Double, p: Double)

    /// The form's name as the artifact spells it, which is also the key its
    /// per-fold entry is filed under.
    public var name: String {
        switch self {
        case .affine: "affine"
        case .quadratic: "quadratic"
        case .power: "power"
        }
    }

    func value(atDepthMeters depth: Double) -> Double {
        switch self {
        case .affine(let a, let b): a + b * depth
        case .quadratic(let a, let b): a + b * depth * depth
        case .power(let a, let p): a * pow(depth, p)
        }
    }

    /// Built from the artifact's `form` string and `coefficients` object. An
    /// unnameable form is refused, because a form that cannot be evaluated
    /// cannot be adopted; a coefficient set that is not exactly this form's is
    /// refused too, since quietly ignoring a coefficient the artifact carries
    /// is the silent coercion this reader exists to avoid.
    init(name: String, coefficients: [String: Double]) throws {
        func value(_ key: String) throws -> Double {
            guard let value = coefficients[key] else {
                throw ModelReadError(
                    kind: .malformedForm,
                    message: "the \(name) form has no \(key) coefficient"
                )
            }
            return value
        }
        func requireExactly(_ keys: Set<String>) throws {
            guard Set(coefficients.keys) == keys else {
                throw ModelReadError(
                    kind: .malformedForm,
                    message: "the \(name) form is evaluated from "
                        + "\(keys.sorted().joined(separator: ", ")) and the artifact carries "
                        + "\(coefficients.keys.sorted().joined(separator: ", "))"
                )
            }
        }
        switch name {
        case "affine":
            try requireExactly(["a", "b"])
            self = .affine(a: try value("a"), b: try value("b"))
        case "quadratic":
            try requireExactly(["a", "b"])
            self = .quadratic(a: try value("a"), b: try value("b"))
        case "power":
            try requireExactly(["a", "p"])
            self = .power(a: try value("a"), p: try value("p"))
        default:
            throw ModelReadError(kind: .malformedForm, message: "unknown form \"\(name)\"")
        }
    }
}

/// The incumbent a refused class keeps: one median per registered depth band.
/// A band with no samples has no median -- `fit_table` appends null -- so the
/// column is optional rather than zero-filled, and evaluating into such a band
/// refuses rather than answering with a number nobody measured.
public struct BandedTable: Sendable, Equatable {
    /// n + 1 strictly increasing edges for n bands.
    public let edges: [Double]

    /// Parallel to the bands, `nil` where the band had no samples.
    public let medians: [Double?]

    public init(edges: [Double], medians: [Double?]) throws {
        guard edges.count >= 2 else {
            throw ModelReadError(kind: .malformedTable, message: "a table needs at least one band")
        }
        guard zip(edges, edges.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw ModelReadError(kind: .malformedTable, message: "table edges are not strictly increasing")
        }
        guard medians.count == edges.count - 1 else {
            throw ModelReadError(
                kind: .malformedTable,
                message: "\(edges.count) edges bound \(edges.count - 1) bands, "
                    + "and the table carries \(medians.count) medians"
            )
        }
        self.edges = edges
        self.medians = medians
    }

    /// The band holding this depth, `low <= d < high` as `fit_table` bands it;
    /// `nil` when no band does.
    public func band(containingDepthMeters depth: Double) -> Int? {
        medians.indices.first { depth >= edges[$0] && depth < edges[$0 + 1] }
    }
}

/// One form's showing on one fold, either scored against that fold's own table
/// or disqualified by the positivity gate before selection ever compared it.
public enum FormOutcome: Sendable, Equatable {
    case scored(metric: Double, margin: Double)
    case disqualified
}

/// One leave-one-out fold: the container held out, the metric that fold's own
/// banded table scored on it, and every candidate form's showing against that
/// table.
public struct Fold: Sendable, Equatable {
    public let holdout: String
    public let tableMetric: Double

    /// Keyed by the form name as the artifact spells it. Deliberately a
    /// `String` and not a `Form` case: an adopted form must be understood to
    /// be evaluated, while a fold entry is a diagnostic, and refusing a whole
    /// artifact because a later fit reported a fourth candidate would be the
    /// wrong trade.
    public let forms: [String: FormOutcome]
}

/// One class's model: the verdict, and the folds that produced it.
///
/// The verdict is an enum inside the struct rather than the struct itself, so
/// a caller that only wants to evaluate switches over `verdict` and never
/// pattern-binds the diagnostics; a caller that wants to explain the verdict
/// reads `folds` beside it. Both of v0.6's teeth live in that enum: there is
/// no path from a refused class to coefficients that do not exist, and a
/// refused class still carries the table it kept.
public struct ClassModel: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        /// A continuous form beat the fold's own table in every fold.
        case adopted(Form)
        /// No candidate cleared the unanimity bar, so the class keeps its
        /// banded table -- which still answers.
        case refused(BandedTable)
    }

    public let verdict: Verdict
    public let folds: [Fold]
}

/// Which export a model was trained on, and at what decimation.
public struct Provenance: Sendable, Equatable, Decodable {
    public let session: String
    public let decimation: Int

    public init(session: String, decimation: Int) {
        self.session = session
        self.decimation = decimation
    }
}

/// The three registered classes, each present by construction. A dictionary
/// would make every lookup optional at the call site for an absence decoding
/// already refuses.
public struct Classes: Sendable, Equatable {
    public let low: ClassModel
    public let medium: ClassModel
    public let high: ClassModel

    public subscript(_ confidence: ConfidenceClass) -> ClassModel {
        switch confidence {
        case .low: low
        case .medium: medium
        case .high: high
        }
    }
}

/// A `skewline-fit/1` artifact as Swift values: what was fitted, what was
/// refused, what it was trained on, and the estimand the numbers are of.
///
/// The estimand is fixed and it is **pairwise** -- the disagreement of two
/// same-class readings of the same point, not a single-reading sigma. It rides
/// the API rather than sitting only in a doc comment: nothing here is named
/// `sigma`, and `estimate(for:atDepthMeters:)` hands back an `Estimate` whose
/// payload label says what the number is. A consumer that wants a per-reading
/// error bar must say how it converts, and that conversion is not this
/// module's claim.
public struct FittedModel: Sendable, Equatable {
    /// The payload's schema tag, checked before any other field is believed.
    public static let schemaTag = "skewline-fit/1"

    /// The one `units` value this module knows how to mean.
    public static let units = "meters"

    /// The one `outsideDomain` value this module knows how to mean.
    public static let outsideDomain = "refuse"

    /// The registered wording, verbatim. Carried rather than checked: gating
    /// on prose would go red on a rewording that changed nothing, while a
    /// changed *meaning* is what the schema tag is for.
    public let estimand: String

    /// Half-open, `0.5 ..< 5.0` m for today's artifact. The wire carries two
    /// numbers and no inclusivity marker, so this reader resolves the question
    /// on the banded table's own `low <= d < high` semantics -- the upper
    /// bound refuses, for an adopted class exactly as for a refused one.
    public let depthDomain: Range<Double>

    /// The sessions the fit was trained on, in the artifact's order.
    public let trainedOn: [String]

    public let export: [Provenance]

    public let classes: Classes

    /// Decodes an artifact, or refuses with the reason. Never coerces: a shape
    /// this reader cannot mean is a refusal, not a default.
    public init(decoding data: Data) throws {
        do {
            self = try JSONDecoder().decode(FittedModel.self, from: data)
        } catch let refusal as ModelReadError {
            throw refusal
        } catch let problem as DecodingError {
            throw ModelReadError(kind: Self.kind(of: problem), message: Self.describe(problem))
        }
    }

    private static func kind(of problem: DecodingError) -> ModelReadError.Kind {
        switch problem {
        case .dataCorrupted(let context):
            // A top-level parse failure has no coding path; a corrupt value
            // inside a document that parsed does.
            context.codingPath.isEmpty ? .notJSON : .missingField
        default:
            .missingField
        }
    }

    private static func describe(_ problem: DecodingError) -> String {
        let path: String
        let context: DecodingError.Context
        switch problem {
        case .keyNotFound(let key, let found):
            context = found
            path = (found.codingPath.map(\.stringValue) + [key.stringValue]).joined(separator: ".")
        case .typeMismatch(_, let found), .valueNotFound(_, let found), .dataCorrupted(let found):
            context = found
            path = found.codingPath.map(\.stringValue).joined(separator: ".")
        @unknown default:
            return "\(problem)"
        }
        return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
    }
}

// MARK: - Decoding

extension FittedModel: Decodable {
    private enum CodingKeys: String, CodingKey {
        case schema, estimand, units, outsideDomain, depthDomain, trainedOn, export, classes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // The tag first, before anything else is believed -- the discipline
        // `fit.read_artifact` and the PLY reader already apply. A tag that is
        // present but is not a string is simply not the tag.
        let schema = try? container.decode(String.self, forKey: .schema)
        guard schema == Self.schemaTag else {
            throw ModelReadError(
                kind: .wrongSchema,
                message: "expected \(Self.schemaTag), found "
                    + (schema.map { "\"\($0)\"" } ?? "no schema field")
            )
        }

        // Two fields whose meaning this type hard-codes, so it verifies them
        // rather than assuming them.
        let units = try container.decode(String.self, forKey: .units)
        guard units == Self.units else {
            throw ModelReadError(
                kind: .wrongUnits,
                message: "this reader means \(Self.units); the artifact says \"\(units)\""
            )
        }
        let outsideDomain = try container.decode(String.self, forKey: .outsideDomain)
        guard outsideDomain == Self.outsideDomain else {
            throw ModelReadError(
                kind: .wrongOutsideDomain,
                message: "this reader refuses outside the domain; the artifact says \"\(outsideDomain)\""
            )
        }

        estimand = try container.decode(String.self, forKey: .estimand)

        let bounds = try container.decode([Double].self, forKey: .depthDomain)
        guard bounds.count == 2, bounds[0] < bounds[1] else {
            throw ModelReadError(
                kind: .malformedDomain,
                message: "depthDomain must be two ascending bounds, found \(bounds)"
            )
        }
        depthDomain = bounds[0]..<bounds[1]

        trainedOn = try container.decode([String].self, forKey: .trainedOn)
        export = try container.decode([Provenance].self, forKey: .export)

        var byClass: [ConfidenceClass: ClassModel] = [:]
        for (name, model) in try container.decode([String: ClassModel].self, forKey: .classes) {
            guard let confidence = ConfidenceClass(rawValue: name) else {
                throw ModelReadError(
                    kind: .unknownClass,
                    message: "the artifact carries a \"\(name)\" class this reader cannot name"
                )
            }
            byClass[confidence] = model
        }
        for confidence in ConfidenceClass.allCases where byClass[confidence] == nil {
            throw ModelReadError(
                kind: .missingField,
                message: "the artifact has no \(confidence.rawValue) class"
            )
        }
        guard let low = byClass[.low], let medium = byClass[.medium], let high = byClass[.high] else {
            throw ModelReadError(kind: .missingField, message: "the artifact has no classes")
        }
        classes = Classes(low: low, medium: medium, high: high)

        // A refused class must answer wherever the domain does, except where a
        // band had no samples, so its table has to span the domain exactly.
        for confidence in ConfidenceClass.allCases {
            guard case .refused(let table) = classes[confidence].verdict else { continue }
            guard table.edges.first == depthDomain.lowerBound,
                  table.edges.last == depthDomain.upperBound else {
                throw ModelReadError(
                    kind: .malformedTable,
                    message: "the \(confidence.rawValue) table spans "
                        + "[\(table.edges.first ?? .nan), \(table.edges.last ?? .nan)] "
                        + "and the depth domain is [\(depthDomain.lowerBound), \(depthDomain.upperBound))"
                )
            }
        }
    }
}

extension ClassModel: Decodable {
    private enum CodingKeys: String, CodingKey {
        case verdict, form, coefficients, table, folds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        folds = try container.decode([Fold].self, forKey: .folds)
        let name = try container.decode(String.self, forKey: .verdict)
        switch name {
        case "adopted":
            verdict = .adopted(try Form(
                name: try container.decode(String.self, forKey: .form),
                coefficients: try container.decode([String: Double].self, forKey: .coefficients)
            ))
        case "refused":
            verdict = .refused(try container.decode(BandedTable.self, forKey: .table))
        default:
            throw ModelReadError(kind: .unknownVerdict, message: "unknown verdict \"\(name)\"")
        }
    }
}

extension BandedTable: Decodable {
    private enum CodingKeys: String, CodingKey {
        case edges, medians
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            edges: try container.decode([Double].self, forKey: .edges),
            medians: try container.decode([Double?].self, forKey: .medians)
        )
    }
}

extension Fold: Decodable {
    private enum CodingKeys: String, CodingKey {
        case holdout, table, forms
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        holdout = try container.decode(String.self, forKey: .holdout)
        tableMetric = try container.decode(Double.self, forKey: .table)
        forms = try container.decode([String: FormOutcome].self, forKey: .forms)
    }
}

extension FormOutcome: Decodable {
    private enum CodingKeys: String, CodingKey {
        case metric, margin, disqualified
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.disqualified) {
            guard try container.decode(Bool.self, forKey: .disqualified),
                  !container.contains(.metric), !container.contains(.margin) else {
                throw ModelReadError(
                    kind: .malformedFold,
                    message: "a disqualified form carries no metric and no margin"
                )
            }
            self = .disqualified
            return
        }
        guard container.contains(.metric), container.contains(.margin) else {
            throw ModelReadError(
                kind: .malformedFold,
                message: "a fold entry is either a metric with its margin or a disqualification"
            )
        }
        self = .scored(
            metric: try container.decode(Double.self, forKey: .metric),
            margin: try container.decode(Double.self, forKey: .margin)
        )
    }
}
