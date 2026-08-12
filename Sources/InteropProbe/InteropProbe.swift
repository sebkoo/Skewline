import Foundation
import Core
import Replay
import Render
import Interop

/// Reads PLY files across the seam and prints what came back: the declared
/// layout, the counts, and what the read cost. `--dump` writes a probe-local
/// binary PLY from a replayed container -- the unprojected cloud with each
/// point's confidence -- so the reader has a real file to be measured
/// against without any writer entering the library or any capture entering
/// the repository.
///
/// The report is paired blocks, the RenderProbe pattern: the deterministic
/// block holds layout and counts that must byte-reproduce across runs on one
/// machine; the timing block is labeled non-deterministic and is only
/// meaningful from a release build.
///
/// `@main` on a struct rather than top-level code in `main.swift`: top-level
/// code is `MainActor`-isolated, and nothing here wants an actor.
@main
struct InteropProbe {
    static func main() {
        var paths: [String] = []
        var dump: (container: URL, output: URL)?
        let arguments = Array(CommandLine.arguments.dropFirst())
        var index = 0
        var usageError = false
        while index < arguments.count {
            if arguments[index] == "--dump" {
                if index + 2 < arguments.count {
                    dump = (
                        container: URL(filePath: arguments[index + 1]),
                        output: URL(filePath: arguments[index + 2])
                    )
                    index += 2
                } else {
                    usageError = true
                }
            } else {
                paths.append(arguments[index])
            }
            index += 1
        }
        guard !usageError, dump != nil || !paths.isEmpty else {
            FileHandle.standardError.write(Data(
                "usage: InteropProbe [--dump <capture.skewline> <out.ply>] <file.ply> ...\n".utf8
            ))
            exit(64)
        }
        #if DEBUG
        print("warning: debug build -- the timing below is the optimizer's absence, not the parser's bill")
        #endif
        var failed = false
        if let dump {
            do {
                try writeCloud(from: dump.container, to: dump.output)
            } catch {
                FileHandle.standardError.write(Data("error: \(dump.container.path): \(error)\n".utf8))
                failed = true
            }
        }
        for path in paths {
            do {
                try report(on: URL(filePath: path))
            } catch {
                FileHandle.standardError.write(Data("error: \(path): \(error)\n".utf8))
                failed = true
            }
        }
        if failed {
            exit(1)
        }
    }

    static func report(on url: URL) throws {
        let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let clock = ContinuousClock()
        let start = clock.now
        let file = try PLYFile(contentsOf: url)
        let elapsed = start.duration(to: clock.now)

        print("file \(url.path)")
        print(row("encoding", "\(file.encoding)"))
        print(row("bytes", "\(bytes)"))
        print(row("comments", "\(file.comments.count)"))
        for element in file.elements {
            print(row("element \(element.name)", "\(element.count) instances"))
            for property in element.properties {
                let kind = property.listCountType.map { "list \($0.rawValue) " } ?? ""
                print(row("  \(property.name)", "\(kind)\(property.valueType.rawValue)"))
            }
        }
        do {
            let positions = try file.positions()
            print(row("positions", "\(positions.count)"))
        } catch {
            print(row("positions", "none -- no vertex element with scalar x, y, z"))
        }

        #if DEBUG
        let build = "debug build"
        #else
        let build = "release build"
        #endif
        print("  --- timing (\(build); not deterministic) ---")
        let seconds = elapsed / .seconds(1)
        let vertexCount = file.element("vertex")?.count ?? 0
        let rate = seconds > 0 && vertexCount > 0
            ? String(format: " · %.1f M points/s", Double(vertexCount) / seconds / 1_000_000)
            : ""
        print(row("read", String(format: "%.1f ms · %.1f MB/s%@", seconds * 1000, Double(bytes) / seconds / 1_000_000, rate)))
        print("")
    }

    /// The dump: every unprojectable frame's points as one binary
    /// little-endian PLY -- float32 positions, the container's own uint8
    /// confidence beside each -- written the RenderProbe eligibility way,
    /// exact-match pose association and never nearest-neighbour. The writer
    /// lives here because producing a test subject is a probe's job; the
    /// library ships a reader only.
    static func writeCloud(from container: URL, to output: URL) throws {
        let reader = try SessionContainer.Reader(contentsOf: container)
        let session = reader.session
        let poseByTimestamp = Dictionary(
            session.observations.map { ($0.timestamp, $0.transform) },
            uniquingKeysWith: { first, _ in first }
        )

        var points: [ConfidencePoint] = []
        var skippedFrames = 0
        for (index, frame) in session.frames.enumerated() {
            try autoreleasepool {
                guard let depthRecord = frame.depth, depthRecord.confidence != nil,
                      let intrinsics = frame.intrinsics,
                      let pose = poseByTimestamp[frame.timestamp] else {
                    skippedFrames += 1
                    return
                }
                let decoded = try DepthDecoder.decode(
                    record: depthRecord,
                    depthData: try reader.depthData(at: index),
                    confidenceData: try reader.confidenceData(at: index)
                )
                let result = try Unprojector.unproject(
                    depth: decoded,
                    intrinsics: intrinsics,
                    cameraToWorld: pose
                )
                points.append(contentsOf: result.points)
            }
        }

        let header = """
        ply
        format binary_little_endian 1.0
        comment probe-local dump; unprojected from a replayed container; never committed
        element vertex \(points.count)
        property float x
        property float y
        property float z
        property uchar confidence
        end_header

        """
        var data = Data(header.utf8)
        data.reserveCapacity(data.count + points.count * 13)
        for point in points {
            for component in [point.position.x, point.position.y, point.position.z] {
                withUnsafeBytes(of: component.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            }
            data.append(point.confidence)
        }
        try data.write(to: output)

        print("dump \(container.path)")
        print(row("frames unprojected", "\(session.frames.count - skippedFrames) of \(session.frames.count)"))
        print(row("points", "\(points.count)"))
        print(row("bytes", "\(data.count)"))
        print(row("wrote", output.path))
        print("")
    }

    private static func row(_ label: String, _ value: String) -> String {
        "  " + label.padding(toLength: 26, withPad: " ", startingAt: 0) + value
    }
}
