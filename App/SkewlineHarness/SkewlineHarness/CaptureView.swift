import SwiftUI

/// One screen: start, stop, and enough state to know what happened. Files
/// leave the device through Files.app, so there is nothing here for that.
struct CaptureView: View {
    @State private var recorder = SessionRecorder()
    @State private var sighter = Sighter()

    var body: some View {
        VStack(spacing: 16) {
            if SessionRecorder.isSupported {
                // The passthrough, and the thing a tap lands on. Live only
                // while the session is, which is while a recording is: the
                // frame you tap is then a frame the container holds, so the
                // reading can be re-derived afterwards. A sighting nobody can
                // check is the number this repository exists to not produce.
                SightingSurface(
                    session: recorder.arSession,
                    onTap: { x, y in
                        sighter.sight(atNormalizedX: x, y: y, in: recorder.latestDepthFrame)
                    },
                    onNoFrame: { sighter.noFrame() }
                )
                .frame(maxWidth: .infinity)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Text("\(recorder.observationCount) / \(recorder.inertialCount) / \(recorder.frameCount)")
                    .font(.system(.title2, design: .monospaced))

                Text(status)
                    .font(.footnote)
                    .monospaced()
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                Text("scene depth \(SessionRecorder.supportsSceneDepth ? "supported" : "unsupported")")
                    .font(.footnote)
                    .monospaced()
                    .foregroundStyle(.secondary)

                // The address is typed, never guessed and never committed:
                // `serve.py` prints its own URL on the machine it runs on.
                HStack(spacing: 8) {
                    TextField("host:port", text: $sighter.endpoint)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.footnote)
                        .monospaced()
                    Button("Fetch") {
                        Task { await sighter.fetch() }
                    }
                    .disabled(sighter.endpointURL == nil)
                }

                // One row, and every state it can be in is a different thing
                // to be told: no model, fetching, no answer from the service,
                // a model this client will not believe, no frame yet, off the
                // map, and the four the artifact and the sensor already name.
                Text(sighter.line)
                    .font(.caption2)
                    .monospaced()
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.secondary)

                Button(isRecording ? "Stop" : "Start") {
                    if isRecording {
                        recorder.stop()
                    } else {
                        recorder.start()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if let timing = recorder.timing {
                    Text(timing)
                        .font(.caption2)
                        .monospaced()
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("This device does not support ARKit world tracking.")
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }

    private var isRecording: Bool {
        recorder.status == .recording
    }

    private var status: String {
        switch recorder.status {
        case .idle: "ready"
        case .recording: "recording"
        case .writing: "writing"
        case .wrote(let name): "wrote \(name)\nFiles ▸ On My iPhone ▸ SkewlineHarness"
        case .failed(let message): "failed: \(message)"
        }
    }
}

#Preview {
    CaptureView()
}
