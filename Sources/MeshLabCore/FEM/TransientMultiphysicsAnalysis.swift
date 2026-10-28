import Foundation
import simd

public struct TransientThermalOptions: Sendable, Hashable, Codable {
    public var timeStep: Double
    public var steps: Int
    /// Volumetric heat capacity rho*c in J/(m^3 K).
    public var volumetricHeatCapacity: Double
    /// Generalized trapezoidal parameter: 1 is backward Euler, 0.5 is Crank-Nicolson.
    public var theta: Double

    public init(
        timeStep: Double = 0.01,
        steps: Int = 100,
        volumetricHeatCapacity: Double = 3.5e6,
        theta: Double = 1
    ) {
        self.timeStep = timeStep
        self.steps = steps
        self.volumetricHeatCapacity = volumetricHeatCapacity
        self.theta = theta
    }
}

public struct TransientThermalState: Sendable {
    public let time: Double
    public let temperatures: [Double]
    public let maximumTemperature: Double
    public let thermalEnergy: Double
}

public struct TransientThermalResult: Sendable {
    public let states: [TransientThermalState]
    public let conductivity: SparseMatrix
    public let capacity: SparseMatrix
    public let maximumRelativeResidual: Double
}

/// Implicit transient conduction with a consistent capacity matrix.
/// Constant Dirichlet values and linear convection are supported. Radiation is
/// deliberately rejected because it requires a per-step nonlinear tangent.
public struct TransientThermalAnalysis: Sendable {
    public var options: TransientThermalOptions
    public var analysisOptions: AnalysisOptions

    public init(
        options: TransientThermalOptions,
        analysisOptions: AnalysisOptions = AnalysisOptions()
    ) {
        self.options = options
        self.analysisOptions = analysisOptions
    }

    public func solve(
        _ model: ThermalModel,
        heatFactors: [Double] = [],
        initialTemperature: [Double] = []
    ) throws -> TransientThermalResult {
        let mesh = model.mesh
        guard options.timeStep.isFinite, options.timeStep > 0,
              options.steps > 0,
              options.volumetricHeatCapacity.isFinite,
              options.volumetricHeatCapacity > 0,
              options.theta.isFinite, (0.5...1).contains(options.theta),
              model.material.thermalConductivity > 0 else {
            throw FEMError.invalidModel("Invalid transient thermal options")
        }
        guard !model.surfaceConditions.contains(where: {
            if case .radiation = $0 { return true }
            return false
        }) else {
            throw FEMError.invalidModel(
                "Transient radiation requires nonlinear time-step iteration"
            )
        }
        let factors = heatFactors.isEmpty
            ? [Double](repeating: 1, count: options.steps + 1)
            : heatFactors
        guard factors.count == options.steps + 1, factors.allSatisfy(\.isFinite) else {
            throw FEMError.invalidModel("Heat factors must contain steps + 1 finite values")
        }

        var prescribed: [Int: Double] = [:]
        for constraint in model.constraints {
            guard mesh.nodes.indices.contains(constraint.node),
                  constraint.temperature.isFinite else {
                throw FEMError.invalidConstraint(dof: constraint.node)
            }
            if let old = prescribed[constraint.node], old != constraint.temperature {
                throw FEMError.conflictingConstraint(dof: constraint.node)
            }
            prescribed[constraint.node] = constraint.temperature
        }
        guard !prescribed.isEmpty || !model.surfaceConditions.isEmpty else {
            throw FEMError.invalidModel("Transient heat transfer needs a temperature anchor")
        }

        var stiffnessTriplets: [SparseTriplet] = []
        var capacityTriplets: [SparseTriplet] = []
        var source = [Double](repeating: 0, count: mesh.nodes.count)
        for load in model.nodalHeat {
            guard mesh.nodes.indices.contains(load.node), load.value.isFinite else {
                throw FEMError.invalidLoad("Invalid nodal heat load")
            }
            source[load.node] += load.value
        }
        for elementIndex in mesh.elements.indices {
            let data = try ElementKinematics.compute(
                mesh: mesh, material: model.material, elementIndex: elementIndex
            )
            let localK = data.thermalStiffness(
                conductivity: model.material.thermalConductivity
            )
            let localC = data.scalarCapacity(
                coefficient: options.volumetricHeatCapacity
            )
            let weights = data.nodalMeasureWeights()
            for row in data.nodeIndices.indices {
                let globalRow = data.nodeIndices[row]
                source[globalRow] += model.volumetricHeat * weights[row]
                for column in 0...row {
                    let globalColumn = data.nodeIndices[column]
                    stiffnessTriplets.append(SparseTriplet(
                        row: globalRow, column: globalColumn,
                        value: localK[row * data.nodeIndices.count + column]
                    ))
                    capacityTriplets.append(SparseTriplet(
                        row: globalRow, column: globalColumn,
                        value: localC[row * data.nodeIndices.count + column]
                    ))
                }
            }
        }
        try addConvection(
            model.surfaceConditions, mesh: mesh,
            triplets: &stiffnessTriplets, source: &source
        )
        let conductivity = try SparseMatrix.symmetric(
            size: mesh.nodes.count, lowerTriplets: stiffnessTriplets
        )
        let capacity = try SparseMatrix.symmetric(
            size: mesh.nodes.count, lowerTriplets: capacityTriplets
        )
        let free = try FEMAssembly.freeDOFs(count: mesh.nodes.count, prescribed: prescribed)
        let dt = options.timeStep
        let theta = options.theta
        let effectiveFull = try combined(capacity, 1 / dt, conductivity, theta)
        let effective = try FEMAssembly.reduced(effectiveFull, freeDOFs: free)
        let solver: SparseSolver
        do {
            solver = try SparseSolver(
                matrix: effective,
                method: analysisOptions.solverMethod,
                directSettings: analysisOptions.directSettings
            )
        } catch let error as SparseSolverError {
            throw FEMError.solver(error)
        }

        var temperature: [Double]
        if initialTemperature.isEmpty {
            let fallback = prescribed.values.first ?? 0
            temperature = [Double](repeating: fallback, count: mesh.nodes.count)
        } else {
            guard initialTemperature.count == mesh.nodes.count,
                  initialTemperature.allSatisfy(\.isFinite) else {
                throw FEMError.invalidModel("Initial temperature must be a finite nodal field")
            }
            temperature = initialTemperature
        }
        for (node, value) in prescribed { temperature[node] = value }

        var states = [makeState(time: 0, temperature: temperature, capacity: capacity)]
        var maxResidual = 0.0
        for step in 1...options.steps {
            try Task.checkCancellation()
            var fullRHS = capacity.multiply(temperature).map { $0 / dt }
            let oldConduction = conductivity.multiply(temperature)
            for index in fullRHS.indices {
                fullRHS[index] -= (1 - theta) * oldConduction[index]
                let factor = theta * factors[step] + (1 - theta) * factors[step - 1]
                fullRHS[index] += factor * source[index]
            }
            let rhs = FEMAssembly.reducedLoads(
                matrix: effectiveFull,
                rightHandSide: fullRHS,
                freeDOFs: free,
                prescribed: prescribed
            )
            let report: SparseSolveReport
            do { report = try solver.solveWithReport(rhs) }
            catch let error as SparseSolverError { throw FEMError.solver(error) }
            guard report.solution.allSatisfy(\.isFinite) else { throw FEMError.nonFiniteSolution }
            var next = FEMAssembly.full(
                report.solution, freeDOFs: free, count: mesh.nodes.count
            )
            for (node, value) in prescribed { next[node] = value }
            var residual = effective.multiply(report.solution)
            for index in residual.indices { residual[index] -= rhs[index] }
            maxResidual = max(
                maxResidual,
                VectorMath.norm(residual) / max(1, VectorMath.norm(rhs))
            )
            temperature = next
            states.append(makeState(
                time: Double(step) * dt,
                temperature: temperature,
                capacity: capacity
            ))
        }
        return TransientThermalResult(
            states: states,
            conductivity: conductivity,
            capacity: capacity,
            maximumRelativeResidual: maxResidual
        )
    }

    private func combined(
        _ first: SparseMatrix, _ firstScale: Double,
        _ second: SparseMatrix, _ secondScale: Double
    ) throws -> SparseMatrix {
        let values = first.coordinateTriplets().map {
            SparseTriplet(row: $0.row, column: $0.column, value: $0.value * firstScale)
        } + second.coordinateTriplets().map {
            SparseTriplet(row: $0.row, column: $0.column, value: $0.value * secondScale)
        }
        return try SparseMatrix.symmetric(size: first.rowCount, lowerTriplets: values)
    }

    private func makeState(
        time: Double, temperature: [Double], capacity: SparseMatrix
    ) -> TransientThermalState {
        let energy = VectorMath.dot(temperature, capacity.multiply(temperature)) * 0.5
        return TransientThermalState(
            time: time,
            temperatures: temperature,
            maximumTemperature: temperature.max() ?? 0,
            thermalEnergy: energy
        )
    }

    private func addConvection(
        _ conditions: [ThermalSurfaceCondition], mesh: Mesh,
        triplets: inout [SparseTriplet], source: inout [Double]
    ) throws {
        for condition in conditions {
            guard case .convection(let nodes, let h, let ambient) = condition else { continue }
            guard (nodes.count == 3 || nodes.count == 4), Set(nodes).count == nodes.count,
                  nodes.allSatisfy(mesh.nodes.indices.contains),
                  h.isFinite, h >= 0, ambient.isFinite else {
                throw FEMError.invalidModel("Invalid transient convection condition")
            }
            let origin = mesh.nodes[nodes[0]]
            var area = 0.0
            for index in 1..<(nodes.count - 1) {
                area += 0.5 * simd_length(simd_cross(
                    mesh.nodes[nodes[index]] - origin,
                    mesh.nodes[nodes[index + 1]] - origin
                ))
            }
            guard area > 1e-15 else { throw FEMError.invalidModel("Degenerate convection face") }
            let coefficient = h * area / Double(nodes.count)
            for node in nodes {
                triplets.append(SparseTriplet(row: node, column: node, value: coefficient))
                source[node] += coefficient * ambient
            }
        }
    }
}

public struct TransientThermoMechanicalResult: Sendable {
    public let thermal: TransientThermalResult
    public let structural: TransientResult
}

/// Sequential transient thermo-mechanics. Heat transfer is integrated first;
/// each thermal state then supplies thermal strain to the matching Newmark step.
public struct TransientThermoMechanicalAnalysis: Sendable {
    public var thermalOptions: TransientThermalOptions
    public var structuralOptions: TransientOptions
    public var analysisOptions: AnalysisOptions
    public var referenceTemperature: Double

    public init(
        thermalOptions: TransientThermalOptions,
        structuralOptions: TransientOptions,
        analysisOptions: AnalysisOptions = AnalysisOptions(),
        referenceTemperature: Double = 0
    ) {
        self.thermalOptions = thermalOptions
        self.structuralOptions = structuralOptions
        self.analysisOptions = analysisOptions
        self.referenceTemperature = referenceTemperature
    }

    public func solve(
        thermal thermalModel: ThermalModel,
        structural structuralModel: FEMModel,
        loadHistory: [[Load]],
        heatFactors: [Double] = [],
        initialTemperature: [Double] = []
    ) throws -> TransientThermoMechanicalResult {
        guard thermalModel.mesh == structuralModel.mesh,
              thermalOptions.steps == structuralOptions.steps,
              thermalOptions.timeStep == structuralOptions.timeStep,
              referenceTemperature.isFinite else {
            throw FEMError.invalidModel("Transient coupled fields must share mesh and time grid")
        }
        let thermal = try TransientThermalAnalysis(
            options: thermalOptions, analysisOptions: analysisOptions
        ).solve(
            thermalModel,
            heatFactors: heatFactors,
            initialTemperature: initialTemperature
        )
        let history = thermal.states.map { state in
            state.temperatures.map { $0 - referenceTemperature }
        }
        let structural = try TransientAnalysis(options: structuralOptions).solve(
            structuralModel,
            loadHistory: loadHistory,
            temperatureHistory: history
        )
        return TransientThermoMechanicalResult(thermal: thermal, structural: structural)
    }
}
