import Foundation
import simd

public struct RegionConstraint: Sendable, Hashable, Codable {
    public var regionName: String
    /// Constrained component axes. An empty array constrains every mesh axis.
    public var axes: [Int]
    public var value: Double

    public init(regionName: String, axes: [Int] = [], value: Double = 0) {
        self.regionName = regionName
        self.axes = axes
        self.value = value
    }
}

public struct RegionLoad: Sendable, Hashable, Codable {
    public var regionName: String
    /// Total force distributed equally over the unique nodes in the region.
    public var totalForce: SIMD3<Double>

    public init(regionName: String, totalForce: SIMD3<Double>) {
        self.regionName = regionName
        self.totalForce = totalForce
    }
}

public struct LinearLoadCase: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var loads: [Load]
    public var regionLoads: [RegionLoad]
    public var bodyForce: SIMD3<Double>

    public init(
        id: String,
        name: String,
        loads: [Load] = [],
        regionLoads: [RegionLoad] = [],
        bodyForce: SIMD3<Double> = .zero
    ) {
        self.id = id
        self.name = name
        self.loads = loads
        self.regionLoads = regionLoads
        self.bodyForce = bodyForce
    }
}

public struct LinearCombinationTerm: Sendable, Hashable, Codable {
    public var loadCaseID: String
    public var factor: Double

    public init(loadCaseID: String, factor: Double) {
        self.loadCaseID = loadCaseID
        self.factor = factor
    }
}

public struct LinearLoadCombination: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var terms: [LinearCombinationTerm]

    public init(id: String, name: String, terms: [LinearCombinationTerm]) {
        self.id = id
        self.name = name
        self.terms = terms
    }
}

public struct ProductionLinearStudy: Sendable, Hashable, Codable {
    public var regionConstraints: [RegionConstraint]
    public var materialAssignments: [RegionMaterialAssignment]
    public var loadCases: [LinearLoadCase]
    public var combinations: [LinearLoadCombination]

    public init(
        regionConstraints: [RegionConstraint] = [],
        materialAssignments: [RegionMaterialAssignment] = [],
        loadCases: [LinearLoadCase] = [],
        combinations: [LinearLoadCombination] = []
    ) {
        self.regionConstraints = regionConstraints
        self.materialAssignments = materialAssignments
        self.loadCases = loadCases
        self.combinations = combinations
    }

    private enum CodingKeys: String, CodingKey {
        case regionConstraints
        case materialAssignments
        case loadCases
        case combinations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        regionConstraints = try container.decodeIfPresent(
            [RegionConstraint].self,
            forKey: .regionConstraints
        ) ?? []
        materialAssignments = try container.decodeIfPresent(
            [RegionMaterialAssignment].self,
            forKey: .materialAssignments
        ) ?? []
        loadCases = try container.decodeIfPresent(
            [LinearLoadCase].self,
            forKey: .loadCases
        ) ?? []
        combinations = try container.decodeIfPresent(
            [LinearLoadCombination].self,
            forKey: .combinations
        ) ?? []
    }
}

public struct RegionMaterialAssignment: Sendable, Hashable, Codable {
    public var regionName: String
    public var material: ElasticMaterial

    public init(regionName: String, material: ElasticMaterial) {
        self.regionName = regionName
        self.material = material
    }
}

public enum LinearStudyResultKind: String, Sendable, Hashable, Codable {
    case loadCase
    case combination
}

public struct LinearStudyResult: Sendable {
    public let id: String
    public let name: String
    public let kind: LinearStudyResultKind
    public let result: StaticResult
}

public struct LinearResultEnvelope: Sendable {
    public let nodalMaximumDisplacement: [Double]
    public let nodalMaximumVonMises: [Double]
    public let displacementGoverningResultIDs: [String]
    public let stressGoverningResultIDs: [String]
    public let maximumDisplacement: Double
    public let maximumDisplacementResultID: String?
    public let maximumVonMises: Double
    public let maximumVonMisesResultID: String?
}

public struct ProductionLinearResult: Sendable {
    public let results: [LinearStudyResult]
    public let envelope: LinearResultEnvelope

    public func result(id: String?) -> LinearStudyResult? {
        if let id, let match = results.first(where: { $0.id == id }) { return match }
        return results.first
    }
}

public enum ProductionLinearError: Error, Equatable, Sendable {
    case emptyStudy
    case emptyIdentifier
    case duplicateIdentifier(String)
    case emptyCombination(String)
    case unknownLoadCase(String)
    case unknownRegion(String)
    case emptyRegion(String)
    case invalidAxis(Int)
    case invalidFactor(String)
    case invalidRegionLoad(String)
    case overlappingMaterialAssignment(Int)
}

/// Runs independent linear load cases and factored combinations over one mesh,
/// material, constraint set, and solver configuration.
public enum ProductionLinearAnalysis {
    public static func solve(project: MeshLabProject) throws -> ProductionLinearResult {
        let study = project.linearStudy
        guard !study.loadCases.isEmpty else { throw ProductionLinearError.emptyStudy }
        try validateIdentifiers(study)

        let constraints = try resolveConstraints(project: project)
        let elementMaterials = try resolveElementMaterials(project: project)
        var resolvedCases: [String: (loads: [Load], bodyForce: SIMD3<Double>)] = [:]
        var results: [LinearStudyResult] = []
        results.reserveCapacity(study.loadCases.count + study.combinations.count)

        for loadCase in study.loadCases {
            try Task.checkCancellation()
            let resolved = try resolve(loadCase: loadCase, project: project)
            resolvedCases[loadCase.id] = resolved
            let result = try solve(
                project: project,
                constraints: constraints,
                elementMaterials: elementMaterials,
                loads: resolved.loads,
                bodyForce: resolved.bodyForce
            )
            results.append(LinearStudyResult(
                id: loadCase.id,
                name: loadCase.name,
                kind: .loadCase,
                result: result
            ))
        }

        for combination in study.combinations {
            try Task.checkCancellation()
            guard !combination.terms.isEmpty else {
                throw ProductionLinearError.emptyCombination(combination.id)
            }
            var loads: [Load] = []
            var bodyForce = SIMD3<Double>.zero
            for term in combination.terms {
                guard term.factor.isFinite else {
                    throw ProductionLinearError.invalidFactor(combination.id)
                }
                guard let loadCase = resolvedCases[term.loadCaseID] else {
                    throw ProductionLinearError.unknownLoadCase(term.loadCaseID)
                }
                loads.append(contentsOf: loadCase.loads.map { $0.scaled(by: term.factor) })
                bodyForce += loadCase.bodyForce * term.factor
            }
            let result = try solve(
                project: project,
                constraints: constraints,
                elementMaterials: elementMaterials,
                loads: loads,
                bodyForce: bodyForce
            )
            results.append(LinearStudyResult(
                id: combination.id,
                name: combination.name,
                kind: .combination,
                result: result
            ))
        }

        return ProductionLinearResult(results: results, envelope: envelope(results))
    }

    private static func validateIdentifiers(_ study: ProductionLinearStudy) throws {
        var identifiers = Set<String>()
        for value in study.loadCases.map(\.id) + study.combinations.map(\.id) {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProductionLinearError.emptyIdentifier
            }
            guard identifiers.insert(value).inserted else {
                throw ProductionLinearError.duplicateIdentifier(value)
            }
        }
    }

    private static func resolveConstraints(
        project: MeshLabProject
    ) throws -> [DirichletCondition] {
        var constraints = project.constraints
        for definition in project.linearStudy.regionConstraints {
            let nodes = try regionNodes(named: definition.regionName, project: project)
            guard definition.value.isFinite else {
                throw ProductionLinearError.invalidRegionLoad(definition.regionName)
            }
            let axes = definition.axes.isEmpty
                ? Array(0..<project.mesh.dimension)
                : Array(Set(definition.axes)).sorted()
            for axis in axes {
                guard (0..<project.mesh.dimension).contains(axis) else {
                    throw ProductionLinearError.invalidAxis(axis)
                }
            }
            constraints.append(contentsOf: nodes.flatMap { node in
                axes.map { DirichletCondition(node: node, axis: $0, value: definition.value) }
            })
        }
        return constraints
    }

    private static func resolve(
        loadCase: LinearLoadCase,
        project: MeshLabProject
    ) throws -> (loads: [Load], bodyForce: SIMD3<Double>) {
        guard loadCase.bodyForce.x.isFinite,
              loadCase.bodyForce.y.isFinite,
              loadCase.bodyForce.z.isFinite else {
            throw ProductionLinearError.invalidRegionLoad(loadCase.id)
        }
        var loads = loadCase.loads
        for definition in loadCase.regionLoads {
            guard definition.totalForce.x.isFinite,
                  definition.totalForce.y.isFinite,
                  definition.totalForce.z.isFinite else {
                throw ProductionLinearError.invalidRegionLoad(definition.regionName)
            }
            let nodes = try regionNodes(named: definition.regionName, project: project)
            let force = definition.totalForce / Double(nodes.count)
            loads.append(contentsOf: nodes.map { .nodal(node: $0, vector: force) })
        }
        return (loads, loadCase.bodyForce)
    }

    private static func resolveElementMaterials(
        project: MeshLabProject
    ) throws -> [ElasticMaterial] {
        guard !project.linearStudy.materialAssignments.isEmpty else { return [] }
        var materials = [ElasticMaterial](
            repeating: project.material,
            count: project.mesh.elements.count
        )
        var assigned = Set<Int>()
        for assignment in project.linearStudy.materialAssignments {
            guard let region = project.meshMetadata.regions.first(where: {
                $0.name == assignment.regionName
            }) else {
                throw ProductionLinearError.unknownRegion(assignment.regionName)
            }
            guard !region.elementIndices.isEmpty else {
                throw ProductionLinearError.emptyRegion(assignment.regionName)
            }
            for index in region.elementIndices {
                guard project.mesh.elements.indices.contains(index) else {
                    throw ProductionLinearError.emptyRegion(assignment.regionName)
                }
                guard assigned.insert(index).inserted else {
                    throw ProductionLinearError.overlappingMaterialAssignment(index)
                }
                materials[index] = assignment.material
            }
        }
        return materials
    }

    private static func regionNodes(
        named name: String,
        project: MeshLabProject
    ) throws -> [Int] {
        guard let region = project.meshMetadata.regions.first(where: { $0.name == name }) else {
            throw ProductionLinearError.unknownRegion(name)
        }
        let nodes = Array(Set(region.nodeIndices)).sorted()
        guard !nodes.isEmpty else { throw ProductionLinearError.emptyRegion(name) }
        guard nodes.allSatisfy(project.mesh.nodes.indices.contains) else {
            throw ProductionLinearError.emptyRegion(name)
        }
        return nodes
    }

    private static func solve(
        project: MeshLabProject,
        constraints: [DirichletCondition],
        elementMaterials: [ElasticMaterial],
        loads: [Load],
        bodyForce: SIMD3<Double>
    ) throws -> StaticResult {
        try StaticAnalysis(options: project.makeAnalysisOptions()).solve(FEMModel(
            mesh: project.mesh,
            material: project.material,
            elementMaterials: elementMaterials,
            constraints: constraints,
            loads: loads,
            bodyForce: bodyForce
        ))
    }

    private static func envelope(_ values: [LinearStudyResult]) -> LinearResultEnvelope {
        let nodeCount = values.first?.result.displacements.count ?? 0
        var displacement = [Double](repeating: 0, count: nodeCount)
        var stress = [Double](repeating: 0, count: nodeCount)
        var displacementIDs = [String](repeating: "", count: nodeCount)
        var stressIDs = [String](repeating: "", count: nodeCount)
        for value in values {
            for node in 0..<nodeCount {
                let magnitude = simd_length(value.result.displacements[node])
                if magnitude >= displacement[node] {
                    displacement[node] = magnitude
                    displacementIDs[node] = value.id
                }
                let vonMises = value.result.nodalVonMises[node]
                if vonMises >= stress[node] {
                    stress[node] = vonMises
                    stressIDs[node] = value.id
                }
            }
        }
        let displacementMaximum = values.max {
            $0.result.maxDisplacement < $1.result.maxDisplacement
        }
        let stressMaximum = values.max {
            $0.result.maxVonMises < $1.result.maxVonMises
        }
        return LinearResultEnvelope(
            nodalMaximumDisplacement: displacement,
            nodalMaximumVonMises: stress,
            displacementGoverningResultIDs: displacementIDs,
            stressGoverningResultIDs: stressIDs,
            maximumDisplacement: displacementMaximum?.result.maxDisplacement ?? 0,
            maximumDisplacementResultID: displacementMaximum?.id,
            maximumVonMises: stressMaximum?.result.maxVonMises ?? 0,
            maximumVonMisesResultID: stressMaximum?.id
        )
    }
}

extension Load {
    func scaled(by factor: Double) -> Load {
        switch self {
        case .nodal(let node, let vector):
            .nodal(node: node, vector: vector * factor)
        case .traction(let nodes, let vector):
            .traction(nodes: nodes, vector: vector * factor)
        }
    }
}
