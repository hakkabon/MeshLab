import Foundation
import simd

public enum DesignStudyKind: String, Sendable, Hashable, Codable, CaseIterable {
    case parametric
    case topology
    case shape
}

public struct TopologyStudy: Sendable, Hashable, Codable {
    public var volumeFraction: Double
    public var penalty: Double
    public var filterRadius: Double
    public var outerIterations: Int
    public var innerIterations: Int
    public var volumeTolerance: Double

    public init(
        volumeFraction: Double = 0.5,
        penalty: Double = 3,
        filterRadius: Double = 0.15,
        outerIterations: Int = 2,
        innerIterations: Int = 10,
        volumeTolerance: Double = 0.01
    ) {
        self.volumeFraction = volumeFraction
        self.penalty = penalty
        self.filterRadius = filterRadius
        self.outerIterations = outerIterations
        self.innerIterations = innerIterations
        self.volumeTolerance = volumeTolerance
    }

    public func makeOptions(
        analysisOptions: AnalysisOptions
    ) -> TopologyOptions {
        TopologyOptions(
            volumeFraction: volumeFraction,
            penalty: penalty,
            filterRadius: filterRadius,
            outerIterations: outerIterations,
            innerIterations: innerIterations,
            volumeTolerance: volumeTolerance,
            analysisOptions: analysisOptions
        )
    }
}

public struct ShapeStudy: Sendable, Hashable, Codable {
    /// Mesh axis whose maximum-coordinate face supplies the shape variables.
    public var selectionAxis: Int
    /// Coordinate axis moved by the optimizer.
    public var motionAxis: Int
    /// Absolute coordinate range around each selected node's current value.
    public var margin: Double
    public var volumeTargetRatio: Double
    public var outerIterations: Int
    public var innerIterations: Int
    public var volumeTolerance: Double

    public init(
        selectionAxis: Int = 2,
        motionAxis: Int = 0,
        margin: Double = 0.1,
        volumeTargetRatio: Double = 1,
        outerIterations: Int = 2,
        innerIterations: Int = 4,
        volumeTolerance: Double = 0.01
    ) {
        self.selectionAxis = selectionAxis
        self.motionAxis = motionAxis
        self.margin = margin
        self.volumeTargetRatio = volumeTargetRatio
        self.outerIterations = outerIterations
        self.innerIterations = innerIterations
        self.volumeTolerance = volumeTolerance
    }

    public func makeVariables(for mesh: Mesh) throws -> [ShapeDesignVariable] {
        guard (0..<mesh.dimension).contains(selectionAxis) else {
            throw DesignError.invalidStudy("Shape selection axis is out of range")
        }
        guard (0..<mesh.dimension).contains(motionAxis) else {
            throw DesignError.invalidStudy("Shape motion axis is out of range")
        }
        guard margin.isFinite, margin > 0 else {
            throw DesignError.invalidStudy("Shape margin must be positive")
        }
        let face = mesh.bounds.maximum[selectionAxis]
        return mesh.nodeIndices { point in
            abs(point[selectionAxis] - face) < 1e-12
        }.map { node in
            let coordinate = mesh.nodes[node][motionAxis]
            return ShapeDesignVariable(
                node: node,
                axis: motionAxis,
                lower: coordinate - margin,
                upper: coordinate + margin
            )
        }
    }

    public func makeOptions(
        analysisOptions: AnalysisOptions
    ) -> ShapeOptions {
        ShapeOptions(
            volumeTargetRatio: volumeTargetRatio,
            outerIterations: outerIterations,
            innerIterations: innerIterations,
            volumeTolerance: volumeTolerance,
            analysisOptions: analysisOptions
        )
    }
}

public struct DesignStudy: Sendable, Hashable, Codable {
    public var kind: DesignStudyKind
    public var parametric: ParametricStudy
    public var topology: TopologyStudy
    public var shape: ShapeStudy

    public init(
        kind: DesignStudyKind = .parametric,
        parametric: ParametricStudy = ParametricStudy(axes: []),
        topology: TopologyStudy = TopologyStudy(),
        shape: ShapeStudy = ShapeStudy()
    ) {
        self.kind = kind
        self.parametric = parametric
        self.topology = topology
        self.shape = shape
    }
}

public enum DesignRunResult: Sendable {
    case parametric(ParametricResult)
    case topology(TopologyResult)
    case shape(ShapeResult)
}

public extension DesignStudy {
    func run(on project: MeshLabProject) throws -> DesignRunResult {
        switch kind {
        case .parametric:
            return .parametric(try parametric.solve(project))
        case .topology:
            let options = topology.makeOptions(
                analysisOptions: project.makeAnalysisOptions()
            )
            return .topology(
                try TopologyOptimization(options: options)
                    .solve(project.makeModel())
            )
        case .shape:
            let variables = try shape.makeVariables(for: project.mesh)
            let options = shape.makeOptions(
                analysisOptions: project.makeAnalysisOptions()
            )
            return .shape(
                try ShapeOptimization(options: options)
                    .solve(project.makeModel(), variables: variables)
            )
        }
    }
}
