import Foundation
import MeshLabCore
import Testing
import simd

private func productionProject() throws -> MeshLabProject {
    let mesh = try MeshGenerators.structuredBox(
        size: SIMD3<Double>(1, 1, 2),
        divisions: SIMD3<Int>(1, 1, 2)
    )
    let fixed = mesh.nodeIndices { abs($0.z) < 1e-12 }
    let loaded = mesh.nodeIndices { abs($0.z - 2) < 1e-12 }
    let material = try ElasticMaterial(youngModulus: 200e9, poissonRatio: 0.3)
    let metadata = MeshMetadata(regions: [
        MeshRegion(
            name: "fixed",
            dimension: 2,
            physicalTag: 1,
            nodeIndices: fixed,
            elementIndices: []
        ),
        MeshRegion(
            name: "loaded",
            dimension: 2,
            physicalTag: 2,
            nodeIndices: loaded,
            elementIndices: []
        ),
    ])
    return MeshLabProject(
        name: "Production",
        mesh: mesh,
        meshMetadata: metadata,
        material: material,
        constraints: [],
        analysis: .productionLinear,
        linearStudy: ProductionLinearStudy(
            regionConstraints: [RegionConstraint(regionName: "fixed")],
            loadCases: [
                LinearLoadCase(
                    id: "dead",
                    name: "Dead",
                    regionLoads: [RegionLoad(
                        regionName: "loaded",
                        totalForce: SIMD3<Double>(0, 0, -1_000)
                    )]
                ),
                LinearLoadCase(
                    id: "live",
                    name: "Live",
                    regionLoads: [RegionLoad(
                        regionName: "loaded",
                        totalForce: SIMD3<Double>(0, 0, -2_000)
                    )]
                ),
            ],
            combinations: [LinearLoadCombination(
                id: "uls",
                name: "ULS",
                terms: [
                    LinearCombinationTerm(loadCaseID: "dead", factor: 1.2),
                    LinearCombinationTerm(loadCaseID: "live", factor: 1.5),
                ]
            )]
        )
    )
}

@Test func productionLinearCasesCombinationsAndEnvelopeAreConsistent() throws {
    let project = try productionProject()
    let output = try ProductionLinearAnalysis.solve(project: project)

    #expect(output.results.map(\.id) == ["dead", "live", "uls"])
    #expect(output.linearSystemPreparationCount == 1)
    #expect(output.rightHandSideSolveCount == 3)
    let dead = try #require(output.result(id: "dead"))
    let live = try #require(output.result(id: "live"))
    let uls = try #require(output.result(id: "uls"))
    #expect(abs(live.result.maxDisplacement / dead.result.maxDisplacement - 2) < 1e-9)
    #expect(abs(uls.result.maxDisplacement / dead.result.maxDisplacement - 4.2) < 1e-9)
    #expect(abs(uls.result.maxVonMises / dead.result.maxVonMises - 4.2) < 1e-9)
    #expect(output.envelope.maximumDisplacement == uls.result.maxDisplacement)
    #expect(output.envelope.maximumVonMises == uls.result.maxVonMises)
    #expect(output.envelope.maximumDisplacementResultID == "uls")
    #expect(output.envelope.maximumVonMisesResultID == "uls")
    #expect(output.envelope.displacementGoverningResultIDs.allSatisfy { $0 == "uls" })
    let csv = AnalysisResultExport.linearStudyCSV(project: project, result: output)
    #expect(csv.split(separator: "\n").first
        == "resultID,resultName,resultKind,node,x,y,z,ux,uy,uz,vonMises")
    #expect(csv.contains("\"uls\",\"ULS\",combination"))
}

@Test func productionLinearRejectsUnknownRegionsAndCases() throws {
    var project = try productionProject()
    project.linearStudy.regionConstraints = [RegionConstraint(regionName: "missing")]
    #expect(throws: ProductionLinearError.unknownRegion("missing")) {
        _ = try ProductionLinearAnalysis.solve(project: project)
    }

    project = try productionProject()
    project.linearStudy.combinations[0].terms[0].loadCaseID = "missing"
    #expect(throws: ProductionLinearError.unknownLoadCase("missing")) {
        _ = try ProductionLinearAnalysis.solve(project: project)
    }
}

@Test func productionLinearAppliesMaterialsByVolumeRegion() throws {
    let baseline = try productionProject()
    let baselineResult = try ProductionLinearAnalysis.solve(project: baseline)
    var assigned = baseline
    assigned.meshMetadata.regions.append(MeshRegion(
        name: "soft-volume",
        dimension: 3,
        physicalTag: 3,
        nodeIndices: Array(assigned.mesh.nodes.indices),
        elementIndices: Array(assigned.mesh.elements.indices)
    ))
    let soft = try ElasticMaterial(youngModulus: 100e9, poissonRatio: 0.3)
    assigned.linearStudy.materialAssignments = [RegionMaterialAssignment(
        regionName: "soft-volume",
        material: soft
    )]
    let assignedResult = try ProductionLinearAnalysis.solve(project: assigned)

    let baselineDead = try #require(baselineResult.result(id: "dead"))
    let assignedDead = try #require(assignedResult.result(id: "dead"))
    #expect(abs(assignedDead.result.maxDisplacement / baselineDead.result.maxDisplacement - 2) < 1e-8)
}

@Test func meshQualityReportsScaleIndependentQualityAndOrientation() throws {
    let mesh = try Mesh(
        nodes: [
            SIMD3<Double>(0, 0, 0),
            SIMD3<Double>(2, 0, 0),
            SIMD3<Double>(0, 2, 0),
            SIMD3<Double>(0, 0, 2),
        ],
        elements: [Element(type: .tetrahedron4, nodes: [0, 2, 1, 3])]
    )
    let report = mesh.qualityReport()

    #expect(report.elements.count == 1)
    #expect(report.minimumQuality == report.maximumQuality)
    #expect(report.minimumQuality > 0)
    #expect(report.invertedElementIndices == [0])
    #expect(report.elementIndices(below: report.minimumQuality + 1e-12) == [0])
}

@Test func staticResultReportsForceAndMomentEquilibrium() throws {
    let output = try ProductionLinearAnalysis.solve(project: productionProject())
    let result = try #require(output.result(id: "dead")).result

    #expect(simd_length(result.equilibrium.forceImbalance) < 1e-6)
    #expect(simd_length(result.equilibrium.momentImbalance) < 1e-6)
    #expect(result.equilibrium.relativeFreeResidual < 1e-10)
}

@Test func productionStudyRoundTripsCurrentSchemaAndMigratesVersionFive() throws {
    let project = try productionProject()
    let data = try MeshLabProjectFile.encode(project)
    let decoded = try MeshLabProjectFile.decode(data)
    #expect(decoded == project)
    #expect(decoded.schemaVersion == MeshLabProject.currentSchemaVersion)

    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["schemaVersion"] = 5
    object.removeValue(forKey: "linearStudy")
    object.removeValue(forKey: "selectedLinearResultID")
    let migrated = try MeshLabProjectFile.decode(
        try JSONSerialization.data(withJSONObject: object)
    )
    #expect(migrated.schemaVersion == 5)
    #expect(migrated.linearStudy == ProductionLinearStudy())
    #expect(migrated.selectedLinearResultID == nil)
}
