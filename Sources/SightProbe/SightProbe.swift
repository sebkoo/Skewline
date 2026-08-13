import Foundation
import Model
import Replay
import Sight

/// Sights points in a recorded container and prints what the fitted model says
/// about each one.
///
/// This is the rung with the phone taken out. The client that will hold this
/// arithmetic runs a live depth map through the same two calls; here the depth
/// map is one a device already wrote, so the whole path is visible on a Mac
/// with no hardware attached -- and the numbers it prints are the numbers the
/// device would print for the same pixel.
///
/// Both operands stay on this machine, which is the point that outlives the
/// probe: the artifact comes down whole and is evaluated locally, and no depth
/// a client picked ever travels up.
///
/// Usage: `SightProbe <model.json | http://host:port/v1/model> <container.skewline> [x,y ...]`
/// Points are in normalized image space, `0 <= x < 1` from the top-left corner.
/// Given none, it sights the centre.
///
/// The report is paired blocks, the RenderProbe pattern: the deterministic
/// block byte-reproduces across runs on one machine, and the timing block is
/// labeled non-deterministic and is only meaningful from a release build.
@main
struct SightProbe {
    /// The default sighting, and the only one that needs no argument: the
    /// middle of the map, which is where a phone's crosshair sits.
    static let centre = (x: 0.5, y: 0.5)

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 2 else {
            FileHandle.standardError.write(Data(
                "usage: SightProbe <model.json | http://host:port\(ModelClient.modelPath)> <container.skewline> [x,y ...]\n".utf8
            ))
            exit(64)
        }
        #if DEBUG
        print("warning: debug build -- the timing below is the optimizer's absence, not the arithmetic's bill")
        #endif

        let points: [(x: Double, y: Double)]
        do {
            points = try parsePoints(Array(arguments.dropFirst(2)))
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(64)
        }

        do {
            try await report(model: arguments[0], container: arguments[1], points: points)
        } catch let refusal as ModelReadError {
            FileHandle.standardError.write(Data(
                "error: \(arguments[0]): \(name(of: refusal.kind)) -- \(refusal.message)\n".utf8
            ))
            exit(1)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    enum ProbeError: Error, CustomStringConvertible {
        case malformedPoint(String)
        case noFrameCarriesDepthAndConfidence

        var description: String {
            switch self {
            case .malformedPoint(let text):
                "\(text) is not an x,y pair of numbers"
            case .noFrameCarriesDepthAndConfidence:
                "no frame in the container carries both a depth map and a confidence map"
            }
        }
    }

    static func parsePoints(_ arguments: [String]) throws -> [(x: Double, y: Double)] {
        guard !arguments.isEmpty else { return [centre] }
        return try arguments.map { text in
            let parts = text.split(separator: ",")
            guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else {
                throw ProbeError.malformedPoint(text)
            }
            return (x, y)
        }
    }

    static func report(
        model source: String,
        container: String,
        points: [(x: Double, y: Double)]
    ) async throws {
        let url = URL(string: source)
        let overTheWire = url?.scheme == "http" || url?.scheme == "https"
        let model: FittedModel
        if overTheWire, let url {
            model = try await ModelClient.fetch(from: url)
        } else {
            model = try FittedModel(decoding: try Data(contentsOf: URL(filePath: source)))
        }

        let reader = try SessionContainer.Reader(contentsOf: URL(filePath: container))
        let session = reader.session

        // The first frame carrying both maps, not a frame chosen by anything
        // about its contents: which pixel answers is the finding, and picking
        // the frame that answers best would be picking the finding.
        guard let index = session.frames.firstIndex(where: {
            $0.depth != nil && $0.depth?.confidence != nil
        }), let record = session.frames[index].depth else {
            throw ProbeError.noFrameCarriesDepthAndConfidence
        }

        let clock = ContinuousClock()
        let start = clock.now
        let decoded = try DepthDecoder.decode(
            record: record,
            depthData: try reader.depthData(at: index),
            confidenceData: try reader.confidenceData(at: index)
        )
        let elapsed = start.duration(to: clock.now)

        print("model \(source)")
        print(row("transport", overTheWire ? "\(ModelClient.apiVersion) over HTTP" : "file"))
        print("container \(container)")
        print("  --- sighted (deterministic) ---")
        print(row("frame", "\(index) of \(session.frames.count)"))
        print(row("depth map", "\(decoded.width) x \(decoded.height)"))
        print(row("depth domain", bound(model.depthDomain.lowerBound)
            + " ..< " + bound(model.depthDomain.upperBound) + " m"))
        print(row("trained on", "\(model.trainedOn.count) sessions"))

        guard let grid = DepthMapGrid(width: decoded.width, height: decoded.height),
              let confidences = decoded.confidences else {
            throw ProbeError.noFrameCarriesDepthAndConfidence
        }

        for point in points {
            let label = "at \(normalized(point.x)),\(normalized(point.y))"
            guard let pixel = grid.pixel(atNormalizedX: point.x, y: point.y) else {
                print(row(label, "off the map"))
                continue
            }
            let depth = decoded.depths[pixel.index]
            let raw = confidences[pixel.index]
            print(row(label, "pixel \(pixel.column),\(pixel.row)  "
                + "depth \(bound(Double(depth))) m  class \(raw)"))
            print(row("", say(model.sighting(depthMeters: depth, rawConfidence: raw), model: model)))
        }

        #if DEBUG
        let build = "debug build"
        #else
        let build = "release build"
        #endif
        print("  --- timing (\(build); not deterministic) ---")
        print(row("read and decode one frame", String(format: "%.1f ms", (elapsed / .seconds(1)) * 1000)))
        print("")
    }

    /// The registered wording, and the reason this is a function rather than
    /// an interpolation at the call site.
    ///
    /// The artifact guards depth -- outside the fitted range every class
    /// refuses -- and guards scene not at all, because it cannot: the fit is
    /// leave-one-out over the sessions it names, so a number read off a scene
    /// that is not one of them is an extrapolation across scenes. A bare "this
    /// point disagrees by X" would hide that. The sentence carries where the
    /// number came from instead, and every consumer of this module owes its
    /// reader the same.
    static func say(_ sighting: Sighting, model: FittedModel) -> String {
        switch sighting {
        case .model(.fromAdoptedForm(let meters)):
            "on the \(model.trainedOn.count) sessions this was fitted from, two views of a point"
                + " like this disagreed by about \(fixed(meters)) m"
        case .model(.fromBandedTable(let meters)):
            "no form was adopted for this class; on the \(model.trainedOn.count) sessions this was"
                + " fitted from, its band disagreed by about \(fixed(meters)) m"
        case .model(.refusedBandWithoutSamples):
            "refused: inside the fitted depths, but this band had no samples"
        case .model(.refusedOutsideDepthDomain):
            "refused: outside the depths this was fitted over, nothing answers"
        case .noDepthReturned:
            "refused: the sensor returned no depth at this pixel"
        case .unknownConfidenceClass(let raw):
            "refused: the sensor reported class \(raw), which no fold was fitted over"
        }
    }

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

    /// Six decimals for a disagreement, the scale the fit's own transcript
    /// prints at.
    private static func fixed(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    /// Two decimals for a depth, matching ModelProbe -- a block that claims to
    /// be deterministic cannot print a float the way Swift feels like it.
    private static func bound(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// Four decimals for a normalized coordinate: a depth map is a few hundred
    /// pixels across, so four is past the point where a digit picks a pixel.
    private static func normalized(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    private static func row(_ label: String, _ value: String) -> String {
        "  " + label.padding(toLength: 26, withPad: " ", startingAt: 0) + value
    }
}
