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
/// Usage: `SightProbe <model.json | http://host:port/v1/model> <container.skewline> [--frame N] [x,y ...]`
/// Points are in normalized image space, `0 <= x < 1` from the top-left corner.
/// Given none, it sights the centre.
///
/// `--frame N` names a frame by its index in the container rather than taking
/// the first one carrying both maps. It exists so a sighting made on the
/// device can be re-derived here: the phone shows the index of the frame it
/// read and the point that was tapped, and those two arguments are what turn
/// that reading into something this probe can check. Naming an index is not
/// the same as choosing a frame by what it contains -- the operator is
/// repeating a measurement, not shopping for one that answers.
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
                "usage: SightProbe <model.json | http://host:port\(ModelClient.modelPath)> <container.skewline> [--frame N] [x,y ...]\n".utf8
            ))
            exit(64)
        }
        #if DEBUG
        print("warning: debug build -- the timing below is the optimizer's absence, not the arithmetic's bill")
        #endif

        let trailing: (frame: Int?, points: [(x: Double, y: Double)])
        do {
            trailing = try parseTrailing(Array(arguments.dropFirst(2)))
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(64)
        }

        do {
            try await report(
                model: arguments[0],
                container: arguments[1],
                frame: trailing.frame,
                points: trailing.points
            )
        } catch let refusal as ModelReadError {
            FileHandle.standardError.write(Data(
                "error: \(arguments[0]): \(refusal.kind.name) -- \(refusal.message)\n".utf8
            ))
            exit(1)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    enum ProbeError: Error, CustomStringConvertible {
        case malformedPoint(String)
        case malformedFrame(String)
        /// `--frame` with nothing after it. Its own case because a missing
        /// index and an unreadable one send the operator to different
        /// places.
        case frameIndexMissing
        case noFrameCarriesDepthAndConfidence
        /// A named frame that is not in the container. Distinct from the case
        /// above: "this container has nothing to sight" and "the frame you
        /// asked for is not here" are different findings, and the second is
        /// usually a transcription slip worth saying so.
        case frameOutOfRange(index: Int, count: Int)
        /// A named frame that exists and carries no maps. Also its own case,
        /// for the same reason: the container is fine and this frame is not.
        case frameCarriesNoDepthAndConfidence(index: Int)

        var description: String {
            switch self {
            case .malformedPoint(let text):
                "\(text) is not an x,y pair of numbers"
            case .malformedFrame(let text):
                "\(text) is not a frame index"
            case .frameIndexMissing:
                "--frame needs an index after it"
            case .noFrameCarriesDepthAndConfidence:
                "no frame in the container carries both a depth map and a confidence map"
            case .frameOutOfRange(let index, let count):
                "frame \(index) is not in this container, which has \(count)"
            case .frameCarriesNoDepthAndConfidence(let index):
                "frame \(index) carries no depth map and confidence map"
            }
        }
    }

    /// `--frame N` and the points, from whatever follows the container path.
    ///
    /// One pass, so `--frame` may sit before or after the points: an operator
    /// copying an index and a point off a phone screen should not have to
    /// learn an order as well.
    static func parseTrailing(
        _ arguments: [String]
    ) throws -> (frame: Int?, points: [(x: Double, y: Double)]) {
        var frame: Int?
        var points: [(x: Double, y: Double)] = []
        var rest = arguments[...]
        while let argument = rest.first {
            rest = rest.dropFirst()
            if argument == "--frame" {
                guard let text = rest.first else { throw ProbeError.frameIndexMissing }
                rest = rest.dropFirst()
                guard let index = Int(text), index >= 0 else {
                    throw ProbeError.malformedFrame(text)
                }
                frame = index
                continue
            }
            let parts = argument.split(separator: ",")
            guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else {
                throw ProbeError.malformedPoint(argument)
            }
            points.append((x, y))
        }
        return (frame, points.isEmpty ? [centre] : points)
    }

    static func report(
        model source: String,
        container: String,
        frame named: Int?,
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

        // Without `--frame`, the first frame carrying both maps -- not a frame
        // chosen by anything about its contents, because which pixel answers
        // is the finding and picking the frame that answers best would be
        // picking the finding. With `--frame`, the operator names an index and
        // gets it or an error; naming the frame a phone already read is
        // repeating a measurement rather than shopping for one.
        let index: Int
        let chosenBy: String
        if let named {
            guard named < session.frames.count else {
                throw ProbeError.frameOutOfRange(index: named, count: session.frames.count)
            }
            index = named
            chosenBy = "named"
        } else {
            guard let first = session.frames.firstIndex(where: {
                $0.depth != nil && $0.depth?.confidence != nil
            }) else {
                throw ProbeError.noFrameCarriesDepthAndConfidence
            }
            index = first
            chosenBy = "first carrying depth and confidence"
        }
        guard let record = session.frames[index].depth, record.confidence != nil else {
            throw ProbeError.frameCarriesNoDepthAndConfidence(index: index)
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
        print(row("frame", "\(index) of \(session.frames.count), \(chosenBy)"))
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
            print(row("", model.sighting(depthMeters: depth, rawConfidence: raw).sentence(from: model, precision: .meters)))
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
