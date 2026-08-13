import Foundation
import Model
import Observation
import Sight

/// Holds the fitted model and what it said about the last point tapped.
///
/// Separate from `SessionRecorder` because that type's own docstring says its
/// only job is producing a container and it should not grow a second one. This
/// is the second one, kept beside it rather than inside it.
///
/// Every state below is a different thing to be told, and none of them is
/// another. That is the whole discipline of this rung: four of them come from
/// the artifact and the sensor and were already distinguishable before any
/// screen existed, and the rest are this client's own. A single "—" in place
/// of any of them would be the collapse the four `Estimate` cases and the
/// three `Sighting` cases exist to refuse.
@MainActor
@Observable
final class Sighter {
    enum Readout: Equatable {
        /// Nothing has been fetched. Not an error -- the operator has not
        /// asked yet.
        case notFetched
        case fetching
        /// The request never produced an HTTP response. Two causes share this
        /// state, and saying so is honest rather than lazy: iOS exposes no
        /// documented way to read local-network authorization, and a denial
        /// and a service that is not running fail the same way. The
        /// underlying code is shown so the evidence is on screen even when
        /// the cause cannot be named.
        case unreachable(detail: String)
        /// A response arrived and this client will not believe it. Every
        /// other `ModelReadError.Kind`, named by the name that type carries.
        case refused(name: String, detail: String)
        /// The model is here and no frame has been written yet -- either
        /// nothing is recording, or recording started and the first frame
        /// carrying depth has not landed. Distinct from a pixel with no
        /// depth: there is no frame to have a pixel in.
        case noFrameYet
        /// The tap was outside the depth map.
        case offTheMap
        /// A frame, a pixel and what the model said -- including which of the
        /// four registered silences it said.
        case sighted(Sighted)

        struct Sighted: Equatable {
            let sighting: Sighting
            /// The frame's index in the container, and the normalized point.
            /// Both are shown, because they are the two arguments that turn
            /// this reading into `SightProbe --frame <index> <x>,<y>` and let
            /// somebody check it. A number nobody can re-derive is the thing
            /// this repository exists to not produce.
            let frame: Int
            let x: Double
            let y: Double
            let depthMeters: Float
            let rawConfidence: UInt8
        }
    }

    private(set) var readout: Readout = .notFetched
    private(set) var model: FittedModel?

    /// `host:port`, typed by the operator. Not committed and not guessed: the
    /// service prints its own URL on the machine it runs on, and no address
    /// belongs in this repository.
    var endpoint = ""

    var endpointURL: URL? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: "http://\(trimmed)\(ModelClient.modelPath)")
    }

    func fetch() async {
        guard let url = endpointURL else { return }
        readout = .fetching
        model = nil
        do {
            model = try await ModelClient.fetch(from: url)
            readout = .noFrameYet
        } catch let refusal as ModelReadError {
            readout = Self.readout(for: refusal)
        } catch {
            readout = .refused(name: "unreadable", detail: error.localizedDescription)
        }
    }

    static func readout(for refusal: ModelReadError) -> Readout {
        switch refusal.kind {
        case .unreachable:
            // The message carries the `URLError` code, so a denied
            // local-network permission and a service that is not running are
            // distinguishable by evidence even though nothing here can name
            // which of the two it was.
            return .unreachable(detail: refusal.message)
        default:
            return .refused(name: refusal.kind.name, detail: refusal.message)
        }
    }

    /// A tap that arrived with no ARKit frame to locate it against.
    ///
    /// Its own entry point rather than a normalized point nothing can place:
    /// feeding a not-a-number through `sight` would land on `.offTheMap`,
    /// and "nothing is running" is not "you tapped past the edge of the depth
    /// map". Two findings, two states.
    ///
    /// Left alone when there is no model, so this cannot overwrite the reason
    /// the model is missing with a reason it is not.
    func noFrame() {
        guard model != nil else { return }
        readout = .noFrameYet
    }

    /// What the model says about a point, or which silence.
    ///
    /// The depth is the depth map's own sample -- planar z, the quantity the
    /// model was fitted on. Nothing here raycasts.
    func sight(atNormalizedX x: Double, y: Double, in latest: LatestDepthFrame) {
        guard let model else { return }
        guard let sample = latest.sample else {
            readout = .noFrameYet
            return
        }
        guard let pixel = sample.grid.pixel(atNormalizedX: x, y: y) else {
            readout = .offTheMap
            return
        }
        let reading = sample.reading(at: pixel)
        readout = .sighted(Readout.Sighted(
            sighting: model.sighting(
                depthMeters: reading.depthMeters,
                rawConfidence: reading.rawConfidence
            ),
            frame: sample.index,
            x: x,
            y: y,
            depthMeters: reading.depthMeters,
            rawConfidence: reading.rawConfidence
        ))
    }

    /// The line the panel shows. Millimetres, because a person is reading it.
    var line: String {
        switch readout {
        case .notFetched:
            return "no model yet -- enter the address serve.py printed and fetch"
        case .fetching:
            return "fetching the model"
        case .unreachable(let detail):
            // Two causes, both named, because iOS will not say which.
            return "no answer: the service is not running at that address, or local "
                + "network access is denied for this app in Settings -- \(detail)"
        case .refused(let name, let detail):
            return "the model was refused: \(name) -- \(detail)"
        case .noFrameYet:
            return "model ready; no frame written yet -- start a recording and tap the view"
        case .offTheMap:
            return "that point is not on the depth map"
        case .sighted(let sighted):
            // Unreachable: a `sighted` readout is only ever set where the
            // model is non-nil. Written as a state rather than a `!` because
            // this rung's whole claim is that no silence goes unnamed.
            guard let model else { return "the model went away mid-reading" }
            return "frame \(sighted.frame) at \(Self.normalized(sighted.x)),"
                + "\(Self.normalized(sighted.y))  depth "
                + String(format: "%.2f", sighted.depthMeters)
                + " m  class \(sighted.rawConfidence)\n"
                + sighted.sighting.sentence(from: model, precision: .millimeters)
        }
    }

    /// Four decimals, matching `SightProbe` -- these are the digits an
    /// operator retypes into it.
    private static func normalized(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}
