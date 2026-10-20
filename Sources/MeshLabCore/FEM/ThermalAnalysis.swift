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

/// A steady heat-conduction model on a tet4 or tri3 mesh.
public struct ThermalModel: Sendable {
    public var mesh: Mesh
    public var material: ElasticMaterial
    public var constraints: [ThermalConstraint]
    public var nodalHeat: [ThermalLoad]
    /// Volumetric heat generation in W/m³.
    public var volumetricHeat: Double

    public init(
        mesh: Mesh,
        material: ElasticMaterial,
        constraints: [ThermalConstraint],
        nodalHeat: [ThermalLoad] = [],
        volumetricHeat: Double = 0
    ) {
        self.mesh = mesh
        self.material = material
        self.constraints = constraints
        self.nodalHeat = nodalHeat
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
        guard !model.constraints.isEmpty else {
            throw FEMError.invalidModel("At least one thermal constraint is required")
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
            throw FEMError.invalidModel("Thermal analysis requires a tet4 or tri3 mesh")
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
        try FEMAssembly.validateComponentCoverage(
            mesh: mesh,
            constrainedNodes: Set(prescribed.keys),
            dimension: 1
        )

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
                        * data.measure / Double(nodes.count)
                }
            }
        }

        let stiffness = try SparseMatrix.symmetric(
            size: mesh.nodes.count,
            lowerTriplets: triplets
        )
        let free = try FEMAssembly.freeDOFs(
            count: mesh.nodes.count,
            prescribed: prescribed
        )
        let reduced = try FEMAssembly.reduced(stiffness, freeDOFs: free)
        let reducedRHS = FEMAssembly.reducedLoads(
            matrix: stiffness,
            rightHandSide: rightHandSide,
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
        } catch let error as SparseSolverError {
            throw FEMError.solver(error)
        } catch {
            throw FEMError.solverFailure(String(describing: error))
        }

        let report: SparseSolveReport
        do {
            report = try solver.solveWithReport(reducedRHS)
        } catch let error as SparseSolverError {
            throw FEMError.solver(error)
        } catch {
            throw FEMError.solverFailure(String(describing: error))
        }
        guard report.solution.allSatisfy(\.isFinite) else {
            throw FEMError.nonFiniteSolution
        }

        var temperatures = [Double](repeating: 0, count: mesh.nodes.count)
        for (node, value) in prescribed {
            temperatures[node] = value
        }
        for (index, node) in free.enumerated() {
            temperatures[node] = report.solution[index]
        }

        var fluxes: [ElementHeatFlux] = []
        fluxes.reserveCapacity(kinematics.count)
        for data in kinematics {
            var gradient = SIMD3<Double>.zero
            for (node, shapeGradient) in zip(data.nodeIndices, data.shapeGradients) {
                gradient += shapeGradient * temperatures[node]
            }
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
