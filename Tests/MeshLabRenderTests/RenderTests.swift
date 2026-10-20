import Testing
import simd
import MeshLabCore
@testable import MeshLabRender

#if os(macOS)
import MetalKit

private func cantileverModel() throws -> (mesh: Mesh, result: StaticResult) {
    let mesh = try MeshGenerators.structuredBox(
        size: SIMD3<Double>(1, 1, 2),
        divisions: SIMD3<Int>(1, 1, 2)
    )
    let material = try ElasticMaterial(
        youngModulus: 200e9,
        poissonRatio: 0.3,
        density: 7800
    )
    let constraints = mesh.nodeIndices { abs($0.z) < 1e-12 }
        .map { DirichletCondition.fixed(node: $0) }
    let loads = mesh.nodeIndices { abs($0.z - 2) < 1e-12 }
        .map { Load.nodal(node: $0, vector: SIMD3<Double>(0, 0, -100)) }

    let model = FEMModel(
        mesh: mesh,
        material: material,
        constraints: constraints,
        loads: loads
    )
    let result = try StaticAnalysis().solve(model)
    return (mesh, result)
}

@Test func renderSceneGathersSurfaceFieldsInVertexOrder() throws {
    let (mesh, result) = try cantileverModel()
    let surface = try mesh.makeSurfaceMesh()
    let scene = RenderScene(surface: surface, result: result)

    #expect(!scene.isEmpty)
    #expect(scene.displacements.count == surface.positions.count)
    #expect(scene.stress.count == surface.positions.count)
    #expect(scene.stressRange.lowerBound <= scene.stressRange.upperBound)

    for index in surface.positions.indices {
        let node = surface.sourceNodes[index]
        let displacement = result.displacements[node]
        #expect(scene.displacements[index] == SIMD3<Float>(
            Float(displacement.x),
            Float(displacement.y),
            Float(displacement.z)
        ))
        #expect(scene.stress[index] == Float(result.nodalVonMises[node]))
    }
}

@Test func emptyRenderSceneIsEmpty() {
    let surface = SurfaceMesh(
        positions: [],
        normals: [],
        indices: [],
        sourceNodes: []
    )
    let scene = RenderScene(surface: surface)
    #expect(scene.isEmpty)
    #expect(scene.stressRange == 0...1)
}

@Test func cameraFramesBoundsAndNearFarProjectToUnitRange() {
    var camera = OrbitCamera()
    camera.frame(
        minimum: SIMD3<Float>(-1, -2, -3),
        maximum: SIMD3<Float>(1, 2, 3)
    )

    #expect(simd_length(camera.target) < 1e-5)
    #expect(camera.distance > 0)
    #expect(camera.nearZ > 0)
    #expect(camera.farZ > camera.nearZ)

    let view = camera.viewMatrix
    let eyeInView = view * SIMD4<Float>(camera.eye, 1)
    #expect(simd_length(SIMD3<Float>(eyeInView.x, eyeInView.y, eyeInView.z)) < 1e-4)

    let projection = camera.projectionMatrix(aspect: 16.0 / 9.0)
    let nearPoint = projection * SIMD4<Float>(0, 0, -camera.nearZ, 1)
    let farPoint = projection * SIMD4<Float>(0, 0, -camera.farZ, 1)
    #expect(abs(nearPoint.z / nearPoint.w) < 1e-5)
    #expect(abs(farPoint.z / farPoint.w - 1) < 1e-5)
}

@Test func orbitPitchIsClampedAndZoomIsBounded() {
    var camera = OrbitCamera(distance: 10)
    camera.orbit(deltaX: 0, deltaY: 1_000_000)
    #expect(camera.pitch > 0)
    #expect(camera.pitch < .pi / 2)
    #expect(camera.eye.z > 0)

    camera.orbit(deltaX: 0, deltaY: -1_000_000)
    #expect(camera.pitch < 0)
    #expect(camera.pitch > -.pi / 2)

    camera.zoom(by: -1_000_000)
    #expect(camera.distance <= camera.maximumDistance)
    camera.zoom(by: 1_000_000)
    #expect(camera.distance >= camera.minimumDistance)
}

@Test @MainActor func rendererBuildsPipelineAndAcceptsScene() throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
        return
    }
    let view = MTKView(
        frame: CGRect(x: 0, y: 0, width: 256, height: 256),
        device: device
    )
    let renderer = try FEMRenderer(view: view)
    #expect(view.colorPixelFormat == .bgra8Unorm)
    #expect(view.depthStencilPixelFormat == .depth32Float)
    #expect(!renderer.hasGeometry)

    let (mesh, result) = try cantileverModel()
    let surface = try mesh.makeSurfaceMesh()
    let scene = RenderScene(surface: surface, result: result)
    try renderer.update(scene: scene)

    #expect(renderer.hasGeometry)
    #expect(renderer.triangleCount == surface.indices.count / 3)
    #expect(renderer.camera.distance > 0)

    try renderer.updateFields(
        displacements: scene.displacements,
        stress: scene.stress,
        stressRange: scene.stressRange
    )
    #expect(renderer.hasGeometry)

    #expect(throws: FEMRendererError.self) {
        try renderer.updateFields(
            displacements: [.zero],
            stress: [0],
            stressRange: 0...1
        )
    }

    renderer.clear()
    #expect(!renderer.hasGeometry)
}
#endif
