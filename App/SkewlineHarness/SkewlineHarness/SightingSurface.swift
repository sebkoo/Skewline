import ARKit
import RealityKit
import SwiftUI

/// Camera passthrough with a tap on it, over the session the recorder already
/// owns.
///
/// `ARView` rather than Metal, decided at rung level: what this needs is
/// passthrough, a tap and a 2D overlay -- no anchors, no 3D content, no
/// occlusion, no mesh -- and `ARView` is passthrough with no rendering code.
/// The Metal in this tree is an offscreen point-cloud shader for replay with
/// measured numbers behind it, not a camera-background pass, so "Metal is
/// already here" does not transfer.
///
/// Two things about the session are load-bearing, and both would fail quietly:
///
/// 1. The session is **handed in**, not made here. Two `ARSession`s cannot
///    both hold the camera, and the recorder's is the one already configured
///    and already delegated to `SensorSource`.
/// 2. `automaticallyConfigureSession` is **false**. Left at its default,
///    `ARView` reconfigures the session it is given -- which would drop the
///    `.sceneDepth` frame semantic `SessionRecorder.start()` sets, and depth
///    would simply stop being captured with nothing going red.
///
/// `ARView` conforms to `ARSessionProviding` and `UIGestureRecognizerDelegate`
/// and not to `ARSessionDelegate`, so handing it this session does not
/// displace `SensorSource` from the delegate slot. The frame counters
/// advancing during a recording with this view on screen is the evidence.
struct SightingSurface: UIViewRepresentable {
    let session: ARSession

    /// The tapped point in **normalized image space** -- `(0, 0)` at the
    /// image's top-left, the space `DepthMapGrid` takes. Converting from the
    /// viewport is `ARFrame.displayTransform(for:viewportSize:)` inverted,
    /// which is the half of a tap only ARKit can do.
    let onTap: (Double, Double) -> Void

    /// Reported when a tap arrives with no frame to locate it against, so
    /// "nothing is running" stays a different answer from "off the map".
    let onNoFrame: () -> Void

    func makeUIView(context: Context) -> ARView {
        let view = ARView(
            frame: .zero,
            cameraMode: .ar,
            automaticallyConfigureSession: false
        )
        view.session = session
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        view.addGestureRecognizer(tap)
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.surface = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(surface: self)
    }

    @MainActor
    final class Coordinator: NSObject {
        var surface: SightingSurface
        weak var view: ARView?

        init(surface: SightingSurface) {
            self.surface = surface
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view, view.bounds.width > 0, view.bounds.height > 0 else { return }
            // The current frame is used for the *transform* only; the depth
            // comes from the last frame the drain wrote. The transform is a
            // function of orientation, viewport and image resolution, none of
            // which differ between adjacent frames in one orientation -- a
            // rotation mid-tap makes it one frame stale, which is bounded and
            // said out loud rather than assumed away.
            guard let frame = surface.session.currentFrame else {
                surface.onNoFrame()
                return
            }
            let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
            let location = recognizer.location(in: view)
            let normalizedInView = CGPoint(
                x: location.x / view.bounds.width,
                y: location.y / view.bounds.height
            )
            // `displayTransform` maps normalized image space onto the
            // viewport, so the inverse is what turns a tap back into the
            // image's own coordinates.
            let toImage = frame
                .displayTransform(for: orientation, viewportSize: view.bounds.size)
                .inverted()
            let inImage = normalizedInView.applying(toImage)
            surface.onTap(Double(inImage.x), Double(inImage.y))
        }
    }
}
