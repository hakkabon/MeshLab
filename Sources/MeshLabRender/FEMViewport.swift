import Foundation
import MeshLabCore

#if canImport(SwiftUI) && canImport(MetalKit)

#if os(macOS)
import AppKit
import MetalKit
import SwiftUI

public struct FEMViewport: NSViewRepresentable {
    public var scene: RenderScene?
    public var options: RenderOptions
    public var initialCamera: OrbitCamera?
    public var onPick: ((SurfacePick?) -> Void)?

    public init(
        scene: RenderScene?,
        options: RenderOptions = RenderOptions(),
        initialCamera: OrbitCamera? = nil,
        onPick: ((SurfacePick?) -> Void)? = nil
    ) {
        self.scene = scene
        self.options = options
        self.initialCamera = initialCamera
        self.onPick = onPick
    }

    public init(
        surface: SurfaceMesh,
        result: StaticResult,
        options: RenderOptions = RenderOptions(),
        initialCamera: OrbitCamera? = nil,
        onPick: ((SurfacePick?) -> Void)? = nil
    ) {
        self.init(
            scene: RenderScene(surface: surface, result: result),
            options: options,
            initialCamera: initialCamera,
            onPick: onPick
        )
    }

    public init(
        mesh: Mesh,
        result: StaticResult,
        options: RenderOptions = RenderOptions(),
        initialCamera: OrbitCamera? = nil,
        onPick: ((SurfacePick?) -> Void)? = nil
    ) {
        let surface = try? mesh.makeSurfaceMesh()
        self.init(
            scene: surface.map { RenderScene(surface: $0, result: result) },
            options: options,
            initialCamera: initialCamera,
            onPick: onPick
        )
    }

    public func makeCoordinator() -> FEMViewportCoordinator {
        FEMViewportCoordinator()
    }

    public func makeNSView(context: Context) -> OrbitMTKView {
        let view = OrbitMTKView(
            frame: .zero,
            device: MTLCreateSystemDefaultDevice()
        )
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 120

        view.onOrbit = { [weak coordinator = context.coordinator] deltaX, deltaY in
            coordinator?.orbit(deltaX: deltaX, deltaY: deltaY)
        }
        view.onPan = { [weak coordinator = context.coordinator] deltaX, deltaY in
            coordinator?.pan(deltaX: deltaX, deltaY: deltaY)
        }
        view.onZoom = { [weak coordinator = context.coordinator] delta in
            coordinator?.zoom(delta: delta)
        }
        view.onPick = { [weak coordinator = context.coordinator] point in
            coordinator?.pick(at: point, originTopLeft: false)
        }

        context.coordinator.onPick = onPick
        context.coordinator.attach(to: view)
        context.coordinator.update(
            scene: scene,
            options: options,
            initialCamera: initialCamera
        )
        return view
    }

    public func updateNSView(_ nsView: OrbitMTKView, context: Context) {
        context.coordinator.onPick = onPick
        context.coordinator.update(
            scene: scene,
            options: options,
            initialCamera: initialCamera
        )
    }

    public static func dismantleNSView(
        _ nsView: OrbitMTKView,
        coordinator: FEMViewportCoordinator
    ) {
        nsView.delegate = nil
        nsView.onOrbit = nil
        nsView.onPan = nil
        nsView.onZoom = nil
        nsView.onPick = nil
        coordinator.onPick = nil
    }
}

public final class OrbitMTKView: MTKView {
    var onOrbit: ((CGFloat, CGFloat) -> Void)?
    var onPan: ((CGFloat, CGFloat) -> Void)?
    var onZoom: ((CGFloat) -> Void)?
    var onPick: ((CGPoint) -> Void)?

    private var lastDrag = NSPoint.zero
    private var mouseDownPoint: NSPoint?
    private var didDrag = false

    public override var acceptsFirstResponder: Bool { true }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        lastDrag = point
        mouseDownPoint = point
        didDrag = false
    }

    public override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let mouseDownPoint,
           hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) > 3 {
            didDrag = true
        }
        onOrbit?(point.x - lastDrag.x, point.y - lastDrag.y)
        lastDrag = point
    }

    public override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !didDrag {
            onPick?(point)
        }
        mouseDownPoint = nil
        didDrag = false
    }

    public override func rightMouseDown(with event: NSEvent) {
        lastDrag = convert(event.locationInWindow, from: nil)
    }

    public override func rightMouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onPan?(point.x - lastDrag.x, point.y - lastDrag.y)
        lastDrag = point
    }

    public override func scrollWheel(with event: NSEvent) {
        onZoom?(event.scrollingDeltaY)
    }
}

#elseif os(iOS) || os(tvOS) || os(visionOS)
import MetalKit
import SwiftUI
import UIKit

public struct FEMViewport: UIViewRepresentable {
    public var scene: RenderScene?
    public var options: RenderOptions
    public var initialCamera: OrbitCamera?
    public var onPick: ((SurfacePick?) -> Void)?

    public init(
        scene: RenderScene?,
        options: RenderOptions = RenderOptions(),
        initialCamera: OrbitCamera? = nil,
        onPick: ((SurfacePick?) -> Void)? = nil
    ) {
        self.scene = scene
        self.options = options
        self.initialCamera = initialCamera
        self.onPick = onPick
    }

    public init(
        surface: SurfaceMesh,
        result: StaticResult,
        options: RenderOptions = RenderOptions(),
        initialCamera: OrbitCamera? = nil,
        onPick: ((SurfacePick?) -> Void)? = nil
    ) {
        self.init(
            scene: RenderScene(surface: surface, result: result),
            options: options,
            initialCamera: initialCamera,
            onPick: onPick
        )
    }

    public init(
        mesh: Mesh,
        result: StaticResult,
        options: RenderOptions = RenderOptions(),
        initialCamera: OrbitCamera? = nil,
        onPick: ((SurfacePick?) -> Void)? = nil
    ) {
        let surface = try? mesh.makeSurfaceMesh()
        self.init(
            scene: surface.map { RenderScene(surface: $0, result: result) },
            options: options,
            initialCamera: initialCamera,
            onPick: onPick
        )
    }

    public func makeCoordinator() -> FEMViewportCoordinator {
        FEMViewportCoordinator()
    }

    public func makeUIView(context: Context) -> OrbitMTKView {
        let view = OrbitMTKView(
            frame: .zero,
            device: MTLCreateSystemDefaultDevice()
        )
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 120
        view.isMultipleTouchEnabled = true

        view.onOrbit = { [weak coordinator = context.coordinator] deltaX, deltaY in
            coordinator?.orbit(deltaX: deltaX, deltaY: deltaY)
        }
        view.onPan = { [weak coordinator = context.coordinator] deltaX, deltaY in
            coordinator?.pan(deltaX: deltaX, deltaY: deltaY)
        }
        view.onZoom = { [weak coordinator = context.coordinator] delta in
            coordinator?.zoom(delta: delta)
        }
        view.onPick = { [weak coordinator = context.coordinator] point in
            coordinator?.pick(at: point, originTopLeft: true)
        }

        context.coordinator.onPick = onPick
        context.coordinator.attach(to: view)
        context.coordinator.update(
            scene: scene,
            options: options,
            initialCamera: initialCamera
        )
        return view
    }

    public func updateUIView(_ uiView: OrbitMTKView, context: Context) {
        context.coordinator.onPick = onPick
        context.coordinator.update(
            scene: scene,
            options: options,
            initialCamera: initialCamera
        )
    }

    public static func dismantleUIView(
        _ uiView: OrbitMTKView,
        coordinator: FEMViewportCoordinator
    ) {
        uiView.delegate = nil
        uiView.onOrbit = nil
        uiView.onPan = nil
        uiView.onZoom = nil
        uiView.onPick = nil
        coordinator.onPick = nil
    }
}

public final class OrbitMTKView: MTKView {
    var onOrbit: ((CGFloat, CGFloat) -> Void)?
    var onPan: ((CGFloat, CGFloat) -> Void)?
    var onZoom: ((CGFloat) -> Void)?
    var onPick: ((CGPoint) -> Void)?

    private var lastPinchScale: CGFloat = 1

    public override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        configureGestures()
    }

    public required init(coder: NSCoder) {
        super.init(coder: coder)
        configureGestures()
    }

    private func configureGestures() {
        let orbit = UIPanGestureRecognizer(target: self, action: #selector(handleOrbitPan))
        orbit.minimumNumberOfTouches = 1
        orbit.maximumNumberOfTouches = 1
        addGestureRecognizer(orbit)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        addGestureRecognizer(pinch)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        onPick?(gesture.location(in: self))
    }

    @objc private func handleOrbitPan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        onOrbit?(translation.x, translation.y)
    }

    @objc private func handleTwoFingerPan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        onPan?(translation.x, translation.y)
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began {
            lastPinchScale = gesture.scale
        }
        let ratio = Double(max(gesture.scale / max(lastPinchScale, 0.0001), 0.0001))
        lastPinchScale = gesture.scale
        onZoom?(CGFloat(Foundation.log(ratio)) * 100)
    }
}
#endif

#endif
