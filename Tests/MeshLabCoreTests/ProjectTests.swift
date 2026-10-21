import Foundation
import Testing
import simd
@testable import MeshLabCore

@Test func projectRoundTripsThroughProjectFile() throws {
    let project = try MeshLabProject.cantileverExample()
    let data = try MeshLabProjectFile.encode(project)
    let decoded = try MeshLabProjectFile.decode(data)
    #expect(decoded == project)
    #expect(decoded.schemaVersion == MeshLabProject.currentSchemaVersion)
    #expect(!decoded.mesh.nodes.isEmpty)
    #expect(!decoded.constraints.isEmpty)
}

@Test func projectAppliesLoadScaleToLoadsAndBodyForce() throws {
    var project = try MeshLabProject.cantileverExample()
    project.loadScale = 2.5
    project.bodyForce = SIMD3<Double>(0, 0, -10)
    let model = project.makeModel()

    #expect(model.loads.count == project.loads.count)
    #expect(model.bodyForce == SIMD3<Double>(0, 0, -25))
    if case .nodal(_, let vector) = model.loads.first {
        #expect(vector.z == -25_000)
    } else {
        Issue.record("Expected nodal loads in the cantilever example")
    }
}

@Test func projectRejectsFutureSchemaVersion() throws {
    let project = try MeshLabProject.cantileverExample()
    let data = try MeshLabProjectFile.encode(project)
    var object = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    object["schemaVersion"] = MeshLabProject.currentSchemaVersion + 1
    let futureData = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: MeshLabProjectError.self) {
        try MeshLabProjectFile.decode(futureData)
    }
}

@Test func resultCSVContainsEveryNodeAndHeader() throws {
    let project = try MeshLabProject.cantileverExample()
    let result = try StaticAnalysis(options: project.makeAnalysisOptions())
        .solve(project.makeModel())
    let csv = AnalysisResultExport.csv(project: project, result: result)
    let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)

    #expect(lines.first == "node,x,y,z,ux,uy,uz,vonMises")
    #expect(lines.count == project.mesh.nodes.count + 2)
    #expect(lines[1].hasPrefix("0,"))
}

@Test func projectRoundTripsSolverConfiguration() throws {
    var project = try MeshLabProject.cantileverExample()
    project.solverMethod = .gmres(
        restart: 25,
        settings: SparseIterativeSettings(
            maxIterations: 321,
            tolerance: 1e-9,
            initialSolution: [1, 2, 3],
            preconditioner: .ilu0
        )
    )
    project.directSettings = SparseDirectSettings(
        ordering: .natural,
        pivotTolerance: 1e-10,
        dropTolerance: 1e-14,
        refinementSteps: 2,
        refinementTolerance: 1e-11
    )
    let decoded = try MeshLabProjectFile.decode(
        try MeshLabProjectFile.encode(project)
    )
    #expect(decoded.solverMethod == project.solverMethod)
    #expect(decoded.directSettings == project.directSettings)
    #expect(decoded.showStress == project.showStress)
    #expect(decoded.deformationScale == project.deformationScale)
}

@Test func projectRoundTripsP3AnalysisSettings() throws {
    var project = try MeshLabProject.cantileverExample()
    project.analysis = .thermalStructural
    project.modalModeCount = 9
    project.selectedMode = 3
    project.thermalStudy.referenceTemperature = 293.15
    project.thermalStudy.volumetricHeat = 1_000
    project.material.thermalConductivity = 42
    project.material.thermalExpansion = 1.1e-5

    let decoded = try MeshLabProjectFile.decode(
        try MeshLabProjectFile.encode(project)
    )
    #expect(decoded == project)
    #expect(decoded.analysis == .thermalStructural)
    #expect(decoded.modalModeCount == 9)
    #expect(decoded.thermalStudy.constraints.count == project.thermalStudy.constraints.count)
}

@Test func projectReadsVersionOneAndDefaultsP3Fields() throws {
    let project = try MeshLabProject.cantileverExample()
    let data = try MeshLabProjectFile.encode(project)
    var object = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    object["schemaVersion"] = 1
    object.removeValue(forKey: "analysis")
    object.removeValue(forKey: "modalModeCount")
    object.removeValue(forKey: "selectedMode")
    object.removeValue(forKey: "thermalStudy")
    if var material = object["material"] as? [String: Any] {
        material.removeValue(forKey: "thermalConductivity")
        material.removeValue(forKey: "thermalExpansion")
        object["material"] = material
    }
    let v1Data = try JSONSerialization.data(withJSONObject: object)

    let decoded = try MeshLabProjectFile.decode(v1Data)
    #expect(decoded.schemaVersion == 1)
    #expect(decoded.analysis == .staticAnalysis)
    #expect(decoded.modalModeCount == 6)
    #expect(decoded.selectedMode == 0)
    #expect(decoded.thermalStudy.constraints.isEmpty)
    #expect(decoded.material.thermalConductivity == 0)
    #expect(decoded.material.thermalExpansion == 0)
}

@Test func modalAndThermalCSVExportsUseTheirOwnHeaders() throws {
    let project = try MeshLabProject.cantileverExample()
    let modal = try ModalAnalysis(options: ModalOptions(modeCount: 2))
        .solve(project.makeModel())
    let modalCSV = AnalysisResultExport.modalCSV(project: project, result: modal)
    #expect(modalCSV.split(separator: "\n").first == "mode,frequencyHz,angularFrequency,maxDisplacement")
    #expect(modalCSV.split(separator: "\n").count == 3)

    let thermal = try ThermalAnalysis(options: project.makeAnalysisOptions())
        .solve(project.makeThermalModel())
    let stress = try ThermalStressAnalysis(referenceTemperature: 20)
        .solve(project.makeModel(), temperatures: thermal.temperatures)
    let thermalCSV = AnalysisResultExport.thermalCSV(
        project: project,
        temperatures: thermal.temperatures,
        result: stress.staticResult
    )
    #expect(thermalCSV.split(separator: "\n").first
        == "node,x,y,z,temperature,ux,uy,uz,vonMises")
    #expect(thermalCSV.split(separator: "\n").count == project.mesh.nodes.count + 1)
}

@Test func exampleProjectSupportsEveryAnalysisKind() throws {
    let project = try MeshLabProject.cantileverExample()

    let modal = try ModalAnalysis(options: ModalOptions(
        modeCount: project.modalModeCount
    )).solve(project.makeModel())
    #expect(modal.modes.count == project.modalModeCount)
    #expect(modal.maximumRelativeResidual < 1e-8)

    let thermal = try ThermalAnalysis(options: project.makeAnalysisOptions())
        .solve(project.makeThermalModel())
    let stress = try ThermalStressAnalysis(
        options: project.makeAnalysisOptions(),
        referenceTemperature: project.thermalStudy.referenceTemperature
    ).solve(project.makeModel(), temperatures: thermal.temperatures)
    #expect(thermal.temperatures.count == project.mesh.nodes.count)
    #expect(stress.staticResult.maxVonMises.isFinite)
    #expect(stress.staticResult.maxDisplacement > 0)
}

@Test func projectRoundTripsDesignStudy() throws {
    var project = try MeshLabProject.cantileverExample()
    project.designStudy.kind = .topology
    project.designStudy.topology.volumeFraction = 0.42
    project.designStudy.topology.penalty = 3.5
    project.designStudy.topology.filterRadius = 0.08
    project.designStudy.topology.outerIterations = 3
    project.designStudy.topology.innerIterations = 12
    project.designStudy.topology.volumeTolerance = 0.02
    project.designStudy.shape.selectionAxis = 1
    project.designStudy.shape.motionAxis = 0
    project.designStudy.shape.margin = 0.1
    project.designStudy.parametric.axes[0].values = [150e9, 250e9]

    let decoded = try MeshLabProjectFile.decode(
        try MeshLabProjectFile.encode(project)
    )
    #expect(decoded == project)
    #expect(decoded.schemaVersion == 3)
    #expect(decoded.designStudy.kind == .topology)
    #expect(decoded.designStudy.topology.volumeFraction == 0.42)
    #expect(decoded.designStudy.shape.selectionAxis == 1)
}

@Test func projectReadsVersionTwoAndDefaultsDesignStudy() throws {
    let project = try MeshLabProject.cantileverExample()
    let data = try MeshLabProjectFile.encode(project)
    var object = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    object["schemaVersion"] = 2
    object.removeValue(forKey: "designStudy")
    let v2Data = try JSONSerialization.data(withJSONObject: object)

    let decoded = try MeshLabProjectFile.decode(v2Data)
    #expect(decoded.schemaVersion == 2)
    #expect(decoded.designStudy.kind == .parametric)
    #expect(decoded.designStudy.parametric.axes.isEmpty)
    #expect(decoded.designStudy.topology == TopologyStudy())
    #expect(decoded.designStudy.shape == ShapeStudy())
}

@Test func designStudyRunsEveryKind() throws {
    var project = try MeshLabProject.cantileverExample()
    project.mesh = try MeshGenerators.structuredRectangle(
        width: 4,
        height: 1,
        divisions: SIMD2(6, 2)
    )
    project.constraints = project.mesh.nodeIndices { abs($0.x) < 1e-12 }
        .map { DirichletCondition.fixed(node: $0) }
    let right = try #require(project.mesh.nodeIndices { abs($0.x - 4) < 1e-12 }.first)
    project.loads = [Load.nodal(node: right, vector: SIMD3<Double>(0, -1_000, 0))]

    project.designStudy.kind = .parametric
    project.designStudy.parametric = ParametricStudy(axes: [
        ParametricAxis(parameter: .youngModulus, values: [100e9, 200e9]),
        ParametricAxis(parameter: .loadScale, values: [0.5, 1]),
    ])
    guard case .parametric(let parametric) = try project.designStudy.run(on: project) else {
        Issue.record("Expected a parametric result")
        return
    }
    #expect(parametric.samples.count == 4)

    project.designStudy.kind = .topology
    project.designStudy.topology = TopologyStudy(
        volumeFraction: 0.5,
        filterRadius: 0,
        outerIterations: 2,
        innerIterations: 15,
        volumeTolerance: 0.03
    )
    guard case .topology(let topology) = try project.designStudy.run(on: project) else {
        Issue.record("Expected a topology result")
        return
    }
    #expect(topology.densities.count == project.mesh.elements.count)

    project.designStudy.kind = .shape
    project.designStudy.shape = ShapeStudy(
        selectionAxis: 0,
        motionAxis: 1,
        margin: 0.15,
        outerIterations: 1,
        innerIterations: 4,
        volumeTolerance: 0.05
    )
    guard case .shape(let shape) = try project.designStudy.run(on: project) else {
        Issue.record("Expected a shape result")
        return
    }
    #expect(shape.mesh.nodes.count == project.mesh.nodes.count)
}
