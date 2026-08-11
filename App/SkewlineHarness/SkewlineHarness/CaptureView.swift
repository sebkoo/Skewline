import SwiftUI

/// One screen: start, stop, and enough state to know what happened. Files
/// leave the device through Files.app, so there is nothing here for that.
struct CaptureView: View {
    @State private var recorder = SessionRecorder()

    var body: some View {
        VStack(spacing: 24) {
            if SessionRecorder.isSupported {
                Text("\(recorder.observationCount) / \(recorder.inertialCount) / \(recorder.frameCount)")
                    .font(.system(.largeTitle, design: .monospaced))

                Text(status)
                    .font(.footnote)
                    .monospaced()
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                Text("scene depth \(SessionRecorder.supportsSceneDepth ? "supported" : "unsupported")")
                    .font(.footnote)
                    .monospaced()
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
