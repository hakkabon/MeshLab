import Foundation
import MeshLabCore
import Testing

@Test func gmshVersionTwoImportsNamedRegionsAndConvertsUnits() throws {
    let source = """
    $MeshFormat
    2.2 0 8
    $EndMeshFormat
    $PhysicalNames
    2
    2 11 "fixed"
    3 20 "solid"
    $EndPhysicalNames
    $Nodes
    4
    10 0 0 0
    20 1000 0 0
    30 0 1000 0
    40 0 0 1000
    $EndNodes
    $Elements
    2
    1 2 2 11 1 10 20 30
    2 4 2 20 1 10 20 30 40
    $EndElements
    """

    let imported = try GmshImporter.decode(
        source,
        options: GmshImportOptions(sourceLengthUnit: .millimeter)
    )

    #expect(imported.mesh.nodes.count == 4)
    #expect(imported.mesh.elements.count == 1)
    #expect(imported.mesh.nodes[1].x == 1)
    #expect(imported.metadata.sourceFormat == "gmsh-2.2")
    #expect(imported.metadata.sourceLengthUnit == .millimeter)
    #expect(imported.metadata.lengthUnit == .meter)
    #expect(imported.metadata.regions.count == 2)
    #expect(imported.metadata.regions[0].name == "fixed")
    #expect(imported.metadata.regions[0].nodeIndices == [0, 1, 2])
    #expect(imported.metadata.regions[0].elementIndices.isEmpty)
    #expect(imported.metadata.regions[1].name == "solid")
    #expect(imported.metadata.regions[1].elementIndices == [0])
}

@Test func gmshVersionFourImportsEntityPhysicalGroups() throws {
    let source = """
    $MeshFormat
    4.1 0 8
    $EndMeshFormat
    $PhysicalNames
    2
    2 11 "fixed"
    3 20 "solid"
    $EndPhysicalNames
    $Entities
    0 0 1 1
    1 0 0 0 1 1 0 1 11 0
    1 0 0 0 1 1 1 1 20 0
    $EndEntities
    $Nodes
    1 4 1 4
    3 1 0 4
    1 2 3 4
    0 0 0
    1 0 0
    0 1 0
    0 0 1
    $EndNodes
    $Elements
    2 2 1 2
    2 1 2 1
    1 1 2 3
    3 1 4 1
    2 1 2 3 4
    $EndElements
    """

    let imported = try GmshImporter.decode(source)

    #expect(imported.mesh.elements == [Element(type: .tetrahedron4, nodes: [0, 1, 2, 3])])
    #expect(imported.metadata.regions.map(\.name) == ["fixed", "solid"])
    #expect(imported.metadata.regions[0].nodeIndices == [0, 1, 2])
    #expect(imported.metadata.regions[1].elementIndices == [0])
}

@Test func vtkLegacyExportIncludesGeometryAndStaticFields() throws {
    let project = try MeshLabProject.cantileverExample()
    let result = try StaticAnalysis().solve(project.makeModel())
    let vtk = VTKLegacyExporter.string(mesh: project.mesh, result: result)

    #expect(vtk.contains("DATASET UNSTRUCTURED_GRID"))
    #expect(vtk.contains("POINTS \(project.mesh.nodes.count) double"))
    #expect(vtk.contains("CELL_TYPES \(project.mesh.elements.count)"))
    #expect(vtk.contains("VECTORS displacement double"))
    #expect(vtk.contains("SCALARS von_mises double 1"))
}

@Test func projectVersionFiveRoundTripsMeshMetadata() throws {
    var project = try MeshLabProject.cantileverExample()
    project.meshMetadata = MeshMetadata(
        sourceFormat: "gmsh-4.1",
        sourceLengthUnit: .millimeter,
        lengthUnit: .meter,
        regions: [MeshRegion(
            name: "fixed",
            dimension: 2,
            physicalTag: 11,
            nodeIndices: [0, 1, 2],
            elementIndices: []
        )]
    )

    let decoded = try MeshLabProjectFile.decode(try MeshLabProjectFile.encode(project))
    #expect(decoded == project)
    #expect(decoded.schemaVersion == 5)
    #expect(decoded.meshMetadata.regions.first?.name == "fixed")
}

@Test func projectVersionFourDefaultsMeshMetadata() throws {
    let project = try MeshLabProject.cantileverExample()
    let data = try MeshLabProjectFile.encode(project)
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["schemaVersion"] = 4
    object.removeValue(forKey: "meshMetadata")

    let decoded = try MeshLabProjectFile.decode(try JSONSerialization.data(withJSONObject: object))
    #expect(decoded.schemaVersion == 4)
    #expect(decoded.meshMetadata == MeshMetadata())
}

@Test func elementOperatorProvidesStablePublicContract() throws {
    let first = try FEMElementContribution(
        degreesOfFreedom: [0, 1],
        matrix: [2, -1, -1, 2]
    )
    let second = try FEMElementContribution(
        degreesOfFreedom: [1, 2],
        matrix: [3, -2, -2, 4]
    )
    let linearOperator: any FEMLinearOperator = try FEMElementOperator(
        dimension: 3,
        contributions: [first, second]
    )

    #expect(linearOperator.dimension == 3)
    #expect(linearOperator.diagonal == [2, 5, 4])
    #expect(linearOperator.multiply([1, 2, 3]) == [0, 3, 8])
}
