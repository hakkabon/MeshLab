#if canImport(MetalKit)
import Foundation
import MetalKit
import MeshLabCore

@MainActor
public final class FEMViewportCoordinator: NSObject, MTKViewDelegate {
    public private(set) var renderer: FEMRenderer?
    public private(set) weak var view: MTKView?
    private var hasAppliedInitialCamera = false

    public func attach(to view: MTKView) {
        self.view = view
        do {
            let renderer = try FEMRenderer(view: view)
            self.renderer = renderer
            view.delegate = self
        } catch {
            // A device without Metal still gets a clear MTKView; the error is
            // surfaced for diagnostics without interrupting the UI.
            print("MeshLab renderer unavailable: \(error)")
        }
    }

    public func update(
        scene: RenderScene?,
        options: RenderOptions,
        initialCamera: OrbitCamera?
    ) {
        if let initialCamera, !hasAppliedInitialCamera {
            renderer?.setCamera(initialCamera)
            hasAppliedInitialCamera = true
        }
        guard let renderer else { return }
        if let scene {
            do {
                try renderer.update(scene: scene, options: options)
            } catch {
                print("MeshLab scene update failed: \(error)")
            }
        } else {
            renderer.clear()
        }
    }

    public func orbit(deltaX: CGFloat, deltaY: CGFloat) {
        renderer?.orbit(deltaX: Float(deltaX), deltaY: Float(deltaY))
    }

    public func pan(deltaX: CGFloat, deltaY: CGFloat) {
        guard let view else { return }
        renderer?.pan(
            deltaX: Float(deltaX),
            deltaY: Float(deltaY),
            viewportHeight: Float(view.bounds.height)
        )
    }

    public func zoom(delta: CGFloat) {
        renderer?.zoom(delta: Float(delta))
    }

    public func resetCamera() {
        renderer?.resetCamera()
    }

    public func draw(in view: MTKView) {
        renderer?.draw(in: view)
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        renderer?.mtkView(view, drawableSizeWillChange: size)
    }
}
#endif
