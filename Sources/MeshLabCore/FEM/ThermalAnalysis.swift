import Foundation
import simd

public struct ThermalConstraint: Sendable, Hashable, Codable {
    public let node: Int
    public let temperature: Double

    public init(node: Int, temperature: Double) {
        self.node = node
        self.temperature = temperature
    }
}

public struct ThermalLoad: Sendable, Hashable, Codable {
    public let node: Int
    /// Nodal heat flow in watts.
    public let value: Double

    public init(node: Int, value: Double) {
        self.node = node
        self.value = value
    }
}

public enum ThermalSurfaceCondition: Sendable, Hashable, Codable {
    /// `q = h (T - ambientTemperature)` on an oriented or unoriented face.
    case convection(
        nodes: [Int],
        coefficient: Double,
        ambientTemperature: Double
    )
    /// Grey-body radiation linearized during the steady nonlinear iteration.
    case radiation(
        nodes: [Int],
        emissivity: Double,
        ambientTemperature: Double
    )
}

/// A steady heat-conduction model on a supported continuum mesh.
public struct ThermalModel: Sendable {
    public var mesh: Mesh
    public var material: ElasticMaterial
    public var constraints: [ThermalConstraint]
    public var nodalHeat: [ThermalLoad]
    public var surfaceConditions: [ThermalSurfaceCondition]
    /// Volumetric heat generation in W/m³.
    public var volumetricHeat: Double

    public init(
        mesh: Mesh,
        material: ElasticMaterial,
        constraints: [ThermalConstraint],
        nodalHeat: [ThermalLoad] = [],
        surfaceConditions: [ThermalSurfaceCondition] = [],
        volumetricHeat: Double = 0
    ) {
        self.mesh = mesh
        self.material = material
        self.constraints = constraints
        self.nodalHeat = nodalHeat
        self.surfaceConditions = surfaceConditions
        self.volumetricHeat = volumetricHeat
    }
}

public struct ElementHeatFlux: Sendable {
    public let elementIndex: Int
    public let vector: SIMD3<Double>
    public let magnitude: Double
}

public struct ThermalResult: Sendable {
    public let temperatures: [Double]
    public let elementHeatFluxes: [ElementHeatFlux]
    public let maximumTemperature: Double
    public let solveReport: SparseSolveReport
}

/// Solves steady conduction with Dirichlet temperatures, nodal heat, and
/// uniform volumetric heat generation.
public struct ThermalAnalysis: Sendable {
    public var options: AnalysisOptions

    public init(options: AnalysisOptions = AnalysisOptions()) {
        self.options = options
    }

    public func solve(_ model: ThermalModel) throws -> ThermalResult {
        let mesh = model.mesh
        guard !model.constraints.isEmpty || !model.surfaceConditions.isEmpty else {
            throw FEMError.invalidModel(
                "At least one thermal constraint or surface exchange condition is required"
            )
        }
        guard model.material.thermalConductivity.isFinite,
              model.material.thermalConductivity > 0 else {
            throw FEMError.invalidModel(
                "Thermal analysis requires positive thermal conductivity"
            )
        }
        guard model.volumetricHeat.isFinite else {
            throw FEMError.invalidModel("Volumetric heat generation is not finite")
        }
        guard mesh.dimension == 3 || mesh.dimension == 2 else {
            throw FEMError.invalidModel("Thermal analysis requires a 2D or 3D continuum mesh")
        }

        var prescribed: [Int: Double] = [:]
        for constraint in model.constraints {
            guard (0..<mesh.nodes.count).contains(constraint.node) else {
                throw FEMError.invalidConstraint(dof: constraint.node)
            }
            guard constraint.temperature.isFinite else {
                throw FEMError.invalidConstraint(dof: constraint.node)
            }
            if let existing = prescribed[constraint.node],
               existing != constraint.temperature {
                throw FEMError.conflictingConstraint(dof: constraint.node)
            }
            prescribed[constraint.node] = constraint.temperature
        }
        if model.surfaceConditions.isEmpty {
            try FEMAssembly.validateComponentCoverage(
                mesh: mesh,
                constrainedNodes: Set(prescribed.keys),
                dimension: 1
            )
        }

        var rightHandSide = [Double](repeating: 0, count: mesh.nodes.count)
        for load in model.nodalHeat {
            guard (0..<mesh.nodes.count).contains(load.node),
                  load.value.isFinite else {
                throw FEMError.invalidLoad("Invalid nodal heat load")
            }
            rightHandSide[load.node] += load.value
        }

        var triplets: [SparseTriplet] = []
        triplets.reserveCapacity(mesh.elements.count * 16)
        var kinematics: [ElementKinematics] = []
        kinematics.reserveCapacity(mesh.elements.count)
        for elementIndex in mesh.elements.indices {
            try Task.checkCancellation()
            let data = try ElementKinematics.compute(
                mesh: mesh,
                material: model.material,
                elementIndex: elementIndex
            )
            kinematics.append(data)
            let local = data.thermalStiffness(
                conductivity: model.material.thermalConductivity
            )
            let nodes = data.nodeIndices
            let nodalWeights = data.nodalMeasureWeights()
            for row in 0..<nodes.count {
                for column in 0...row {
                    let value = local[row * nodes.count + column]
                    guard value != 0 else { continue }
                    triplets.append(SparseTriplet(
                        row: nodes[row],
                        column: nodes[column],
                        value: value
                    ))
                }
                if model.volumetricHeat != 0 {
                    rightHandSide[nodes[row]] += model.volumetricHeat
                        * nodalWeights[row]
                }
            }
        }

        let free = try FEMAssembly.freeDOFs(
            count: mesh.nodes.count,
            prescribed: prescribed
        )
        let hasRadiation = model.surfaceConditions.contains {
            if case .radiation = $0 { return true }
            return false
        }
        let ambientValues = model.surfaceConditions.map { condition -> Double in
            switch condition {
            case .convection(_, _, let ambient), .radiation(_, _, let ambient):
                return ambient
            }
        }
        let initialTemperature = prescribed.values.first
            ?? (ambientValues.reduce(0, +) / Double(max(ambientValues.count, 1)))
        var temperatures = [Double](repeating: initialTemperature, count: mesh.nodes.count)
        for (node, value) in prescribed { temperatures[node] = value }
        var report: SparseSolveReport?
        let maximumIterations = hasRadiation ? 30 : 1
        var converged = !hasRadiation
        for _ in 0..<maximumIterations {
            try Task.checkCancellation()
            var iterationTriplets = triplets
            var iterationRHS = rightHandSide
            try addSurfaceExchange(
                model.surfaceConditions,
                mesh: mesh,
                temperatures: temperatures,
                triplets: &iterationTriplets,
                rightHandSide: &iterationRHS
            )
            let stiffness = try SparseMatrix.symmetric(
                size: mesh.nodes.count,
                lowerTriplets: iterationTriplets
            )
            let reduced = try FEMAssembly.reduced(stiffness, freeDOFs: free)
            let reducedRHS = FEMAssembly.reducedLoads(
                matrix: stiffness,
                rightHandSide: iterationRHS,
                freeDOFs: free,
                prescribed: prescribed
            )
            let solver: SparseSolver
            do {
                solver = try SparseSolver(
                    matrix: reduced,
                    method: options.solverMethod,
                    directSettings: options.directSettings
                )
                report = try solver.solveWithReport(reducedRHS)
            } catch let error as SparseSolverError {
                throw FEMError.solver(error)
            } catch {
                throw FEMError.solverFailure(String(describing: error))
            }
            guard let report, report.solution.allSatisfy(\.isFinite) else {
                throw FEMError.nonFiniteSolution
            }
            var next = temperatures
            for (index, node) in free.enumerated() { next[node] = report.solution[index] }
            let change = zip(next, temperatures).reduce(0.0) {
                max($0, abs($1.0 - $1.1))
            }
            temperatures = next
            if !hasRadiation || change <= 1e-8 * max(1, temperatures.map(abs).max() ?? 1) {
                converged = true
                break
            }
        }
        guard let report else {
            throw FEMError.solverFailure("Thermal solve produced no iteration")
        }
        guard converged else {
            throw FEMError.solverFailure(
                "Thermal radiation iteration did not converge in \(maximumIterations) iterations"
            )
        }

        var fluxes: [ElementHeatFlux] = []
        fluxes.reserveCapacity(kinematics.count)
        for data in kinematics {
            try Task.checkCancellation()
            let gradient = data.averageGradient(
                nodalValues: data.nodeIndices.map { temperatures[$0] }
            )
            let flux = gradient * -model.material.thermalConductivity
            fluxes.append(ElementHeatFlux(
                elementIndex: data.elementIndex,
                vector: flux,
                magnitude: simd_length(flux)
            ))
        }

        return ThermalResult(
            temperatures: temperatures,
            elementHeatFluxes: fluxes,
            maximumTemperature: temperatures.max() ?? 0,
            solveReport: report
        )
    }

    private func addSurfaceExchange(
        _ conditions: [ThermalSurfaceCondition],
        mesh: Mesh,
        temperatures: [Double],
        triplets: inout [SparseTriplet],
        rightHandSide: inout [Double]
    ) throws {
        let sigma = 5.670374419e-8
        for condition in conditions {
            let nodes: [Int]
            let ambient: Double
            let coefficient: Double
            switch condition {
            case .convection(let values, let h, let value):
                nodes = values
                ambient = value
                coefficient = h
                guard h.isFinite, h >= 0, value.isFinite else {
                    throw FEMError.invalidModel("Invalid convection condition")
                }
            case .radiation(let values, let emissivity, let value):
                nodes = values
                ambient = value
                guard emissivity.isFinite, (0...1).contains(emissivity),
                      value.isFinite, value >= 0,
                      values.allSatisfy(mesh.nodes.indices.contains) else {
                    throw FEMError.invalidModel("Invalid radiation condition")
                }
                let surfaceTemperature = values.reduce(0.0) {
                    $0 + max(0, temperatures[$1])
                } / Double(max(values.count, 1))
                coefficient = emissivity * sigma
                    * (surfaceTemperature + value)
                    * (surfaceTemperature * surfaceTemperature + value * value)
            }
            guard nodes.count == 3 || nodes.count == 4,
                  Set(nodes).count == nodes.count,
                  nodes.allSatisfy(mesh.nodes.indices.contains) else {
                throw FEMError.invalidModel(
                    "Thermal surface conditions require a valid tri3 or quad4 face"
                )
            }
            let origin = mesh.nodes[nodes[0]]
            var area = 0.0
            for index in 1..<(nodes.count - 1) {
                area += 0.5 * simd_length(simd_cross(
                    mesh.nodes[nodes[index]] - origin,
                    mesh.nodes[nodes[index + 1]] - origin
                ))
            }
            guard area.isFinite, area > 1e-15 else {
                throw FEMError.invalidModel("Thermal surface face is degenerate")
            }
            let nodal = coefficient * area / Double(nodes.count)
            for node in nodes {
                triplets.append(SparseTriplet(row: node, column: node, value: nodal))
                rightHandSide[node] += nodal * ambient
            }
        }
    }
}

public struct ThermalStressResult: Sendable {
    public let temperatures: [Double]
    public let staticResult: StaticResult
}

/// One-way thermal-structural coupling: nodal temperatures become a thermal
/// strain load in a linear-elastic static solve.
public struct ThermalStressAnalysis: Sendable {
    public var options: AnalysisOptions
    public var referenceTemperature: Double

    public init(
        options: AnalysisOptions = AnalysisOptions(),
        referenceTemperature: Double = 0
    ) {
        self.options = options
        self.referenceTemperature = referenceTemperature
    }

    public func solve(
        _ model: FEMModel,
        temperatures: [Double]
    ) throws -> ThermalStressResult {
        guard temperatures.count == model.mesh.nodes.count else {
            throw FEMError.invalidModel(
                "Temperatures must provide one value per mesh node"
            )
        }
        guard temperatures.allSatisfy(\.isFinite),
              referenceTemperature.isFinite else {
            throw FEMError.invalidModel("Temperatures must be finite")
        }
        guard model.mesh.dimension == 3 else {
            throw FEMError.invalidModel(
                "Thermal stress coupling currently requires a three-dimensional mesh"
            )
        }

        var thermalModel = model
        thermalModel.temperatureChange = temperatures.map {
            $0 - referenceTemperature
        }
        let result = try StaticAnalysis(options: options).solve(thermalModel)
        return ThermalStressResult(
            temperatures: temperatures,
            staticResult: result
        )
    }
}
