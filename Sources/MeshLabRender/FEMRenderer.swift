import Foundation
import Metal
import MetalKit
import MeshLabCore
import simd

public enum FEMRendererError: Error, Sendable {
    case noMetalDevice
    case commandQueueUnavailable
    case shaderSourceMissing
    case libraryCompilation(String)
    case pipelineCreation(String)
    case bufferAllocation
    case fieldCountMismatch(expected: Int, displacements: Int, stress: Int)
}

private struct FEMVertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
}

private struct Uniforms {
    var mvp: simd_float4x4
    var lightDirection: SIMD4<Float>
    var stressMin: Float
    var stressMax: Float
    var deformationScale: Float
    var flags: UInt32
}

/// Metal renderer for a computed FEM surface.
///
/// Static geometry and topology live in immutable buffers. Displacement and
/// stress buffers are shared-memory allocations whose contents are updated
/// directly by the CPU; Metal reads the same physical memory on Apple Silicon.
@MainActor
public final class FEMRenderer: NSObject, MTKViewDelegate {
    public private(set) var camera = OrbitCamera()
    public private(set) var options = RenderOptions()

    public var triangleCount: Int { indexCount / 3 }
    public var hasGeometry: Bool { indexCount > 0 }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let depthStencilState: MTLDepthStencilState
    private let inFlight = DispatchSemaphore(value: 3)
    private let fieldBufferCount = 3

    private var vertexBuffer: MTLBuffer?
    private var indexBuffer: MTLBuffer?
    private var displacementBuffers = [MTLBuffer?](repeating: nil, count: 3)
    private var stressBuffers = [MTLBuffer?](repeating: nil, count: 3)
    private var fieldFrame = 0
    private var fieldDisplacements: [SIMD3<Float>] = []
    private var fieldStress: [Float] = []
    private var geometryPositions: [SIMD3<Float>] = []
    private var geometryNormals: [SIMD3<Float>] = []
    private var geometryIndices: [UInt32] = []
    private var vertexCount = 0
    private var indexCount = 0
    private var hasFramedScene = false
    private var stressRange: ClosedRange<Float> = 0...1

    public init(view: MTKView) throws {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice() else {
            throw FEMRendererError.noMetalDevice
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw FEMRendererError.commandQueueUnavailable
        }

        self.device = device
        self.commandQueue = commandQueue

        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0.055, green: 0.065, blue: 0.08, alpha: 1)
        view.framebufferOnly = true
        view.sampleCount = 1

        let library: MTLLibrary
        do {
            library = try Self.makeLibrary(device: device)
        } catch let error as FEMRendererError {
            throw error
        } catch {
            throw FEMRendererError.libraryCompilation(String(describing: error))
        }

        guard let vertexFunction = library.makeFunction(name: "femVertex"),
              let fragmentFunction = library.makeFunction(name: "femFragment") else {
            throw FEMRendererError.pipelineCreation("Missing femVertex/femFragment shader functions")
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "FEM Surface"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        pipelineDescriptor.rasterSampleCount = view.sampleCount

        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            throw FEMRendererError.pipelineCreation(String(describing: error))
        }

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthStencilState = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            throw FEMRendererError.pipelineCreation("Could not create depth-stencil state")
        }
        self.depthStencilState = depthStencilState

        super.init()
    }

    public func update(scene: RenderScene, options: RenderOptions? = nil) throws {
        if let options {
            self.options = options
        }
        guard !scene.isEmpty else {
            clear()
            return
        }

        let positions = scene.surface.positions
        let indices = scene.surface.indices

        let geometryChanged = vertexBuffer == nil
            || geometryPositions != positions
            || geometryNormals != scene.surface.normals
            || geometryIndices != indices
        if geometryChanged {
            let vertices = zip(positions, scene.surface.normals).map {
                FEMVertex(position: $0, normal: $1)
            }
            vertexBuffer = try Self.makeBuffer(device: device, values: vertices)
            indexBuffer = try Self.makeBuffer(device: device, values: indices)
            vertexCount = positions.count
            indexCount = indices.count
            geometryPositions = positions
            geometryNormals = scene.surface.normals
            geometryIndices = indices

            if !hasFramedScene {
                frameScene()
                hasFramedScene = true
            }
        }

        try ensureFieldBuffers(count: vertexCount)
        setFields(
            displacements: scene.displacements,
            stress: scene.stress,
            stressRange: scene.stressRange
        )
    }

    /// Updates only the per-vertex fields while reusing the shared buffers.
    ///
    /// Call this from a display or simulation loop when the mesh topology stays
    /// fixed and only displacements/stress change. Values are staged in CPU
    /// arrays and copied into a ring of shared Metal buffers at draw time, so an
    /// in-flight frame is never overwritten and no per-frame allocation is
    /// required.
    public func updateFields(
        displacements: [SIMD3<Float>],
        stress: [Float],
        stressRange: ClosedRange<Float>
    ) throws {
        guard hasGeometry else { return }
        guard displacements.count == vertexCount, stress.count == vertexCount else {
            throw FEMRendererError.fieldCountMismatch(
                expected: vertexCount,
                displacements: displacements.count,
                stress: stress.count
            )
        }
        try ensureFieldBuffers(count: vertexCount)
        setFields(
            displacements: displacements,
            stress: stress,
            stressRange: stressRange
        )
    }

    public func update(options: RenderOptions) {
        self.options = options
    }

    public func setCamera(_ camera: OrbitCamera) {
        self.camera = camera
        hasFramedScene = true
    }

    public func clear() {
        vertexBuffer = nil
        indexBuffer = nil
        displacementBuffers = [MTLBuffer?](repeating: nil, count: fieldBufferCount)
        stressBuffers = [MTLBuffer?](repeating: nil, count: fieldBufferCount)
        fieldFrame = 0
        fieldDisplacements = []
        fieldStress = []
        geometryPositions = []
        geometryNormals = []
        geometryIndices = []
        vertexCount = 0
        indexCount = 0
        hasFramedScene = false
    }

    public func resetCamera() {
        frameScene()
    }

    public func frameScene() {
        guard let vertexBuffer else { return }
        let vertexCount = vertexBuffer.length / MemoryLayout<FEMVertex>.stride
        guard vertexCount > 0 else { return }
        let vertices = vertexBuffer.contents().bindMemory(to: FEMVertex.self, capacity: vertexCount)

        var minimum = vertices[0].position
        var maximum = vertices[0].position
        for index in 1..<vertexCount {
            minimum = simd_min(minimum, vertices[index].position)
            maximum = simd_max(maximum, vertices[index].position)
        }
        camera.frame(minimum: minimum, maximum: maximum)
    }

    public func orbit(deltaX: Float, deltaY: Float) {
        camera.orbit(deltaX: deltaX, deltaY: deltaY)
    }

    public func pan(deltaX: Float, deltaY: Float, viewportHeight: Float) {
        camera.pan(deltaX: deltaX, deltaY: deltaY, viewportHeight: viewportHeight)
    }

    public func zoom(delta: Float) {
        camera.zoom(by: delta)
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Projection aspect is derived from the drawable size each frame.
    }

    public func draw(in view: MTKView) {
        guard let renderPassDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else {
            return
        }

        inFlight.wait()

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        commandBuffer.label = "FEM Frame"
        commandBuffer.addCompletedHandler { [inFlight] _ in
            inFlight.signal()
        }

        let fieldIndex = fieldFrame % fieldBufferCount
        guard let displacementBuffer = displacementBuffers[fieldIndex],
              let stressBuffer = stressBuffers[fieldIndex] else {
            inFlight.signal()
            return
        }
        Self.write(values: fieldDisplacements, into: displacementBuffer)
        Self.write(values: fieldStress, into: stressBuffer)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: renderPassDescriptor
        ) else {
            inFlight.signal()
            return
        }
        encoder.label = "FEM Surface Pass"
        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthStencilState)

        if let vertexBuffer, let indexBuffer, indexCount > 0 {
            let drawableSize = view.drawableSize
            let aspect = Float(drawableSize.width / max(drawableSize.height, 1))
            var uniforms = Uniforms(
                mvp: camera.viewProjectionMatrix(aspect: aspect),
                lightDirection: SIMD4<Float>(
                    options.lightDirection.x,
                    options.lightDirection.y,
                    options.lightDirection.z,
                    0
                ),
                stressMin: stressRange.lowerBound,
                stressMax: stressRange.upperBound,
                deformationScale: options.deformationScale,
                flags: options.showStress ? 1 : 0
            )

            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(displacementBuffer, offset: 0, index: 1)
            encoder.setVertexBuffer(stressBuffer, offset: 0, index: 2)
            encoder.setVertexBytes(
                &uniforms,
                length: MemoryLayout<Uniforms>.stride,
                index: 3
            )
            encoder.setFragmentBytes(
                &uniforms,
                length: MemoryLayout<Uniforms>.stride,
                index: 3
            )
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: indexCount,
                indexType: .uint32,
                indexBuffer: indexBuffer,
                indexBufferOffset: 0
            )
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        fieldFrame = (fieldFrame + 1) % fieldBufferCount
    }

    private func ensureFieldBuffers(count: Int) throws {
        let displacementLength = max(
            count * MemoryLayout<SIMD3<Float>>.stride,
            MemoryLayout<SIMD3<Float>>.stride
        )
        for index in 0..<fieldBufferCount {
            if displacementBuffers[index] == nil
                || displacementBuffers[index]!.length < displacementLength {
                displacementBuffers[index] = try Self.makeBuffer(
                    device: device,
                    byteCount: displacementLength
                )
            }
        }

        let stressLength = max(
            count * MemoryLayout<Float>.stride,
            MemoryLayout<Float>.stride
        )
        for index in 0..<fieldBufferCount {
            if stressBuffers[index] == nil || stressBuffers[index]!.length < stressLength {
                stressBuffers[index] = try Self.makeBuffer(
                    device: device,
                    byteCount: stressLength
                )
            }
        }
    }

    private func setFields(
        displacements: [SIMD3<Float>],
        stress: [Float],
        stressRange: ClosedRange<Float>
    ) {
        fieldDisplacements = displacements
        fieldStress = stress
        self.stressRange = stressRange
    }

    private static func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        if let library = try? device.makeDefaultLibrary(bundle: .module),
           library.functionNames.contains("femVertex") {
            return library
        }

        guard let url = Bundle.module.url(
            forResource: "Shaders",
            withExtension: "metal"
        ), let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw FEMRendererError.shaderSourceMissing
        }

        do {
            return try device.makeLibrary(source: source, options: nil)
        } catch {
            throw FEMRendererError.libraryCompilation(String(describing: error))
        }
    }

    private static func makeBuffer(device: MTLDevice, byteCount: Int) throws -> MTLBuffer {
        guard let buffer = device.makeBuffer(
            length: max(byteCount, 1),
            options: .storageModeShared
        ) else {
            throw FEMRendererError.bufferAllocation
        }
        buffer.label = "FEM Shared Buffer"
        return buffer
    }

    private static func makeBuffer<T>(
        device: MTLDevice,
        values: [T]
    ) throws -> MTLBuffer {
        let buffer = try makeBuffer(
            device: device,
            byteCount: values.count * MemoryLayout<T>.stride
        )
        write(values: values, into: buffer)
        return buffer
    }

    private static func write<T>(values: [T], into buffer: MTLBuffer) {
        let byteCount = values.count * MemoryLayout<T>.stride
        guard byteCount > 0, byteCount <= buffer.length else { return }
        values.withUnsafeBytes { bytes in
            if let baseAddress = bytes.baseAddress {
                buffer.contents().copyMemory(
                    from: baseAddress,
                    byteCount: byteCount
                )
            }
        }
    }
}
