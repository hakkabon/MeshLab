import Foundation

public enum FEMError: Error, Equatable, Sendable {
    case degenerateElement(Int)
    case unsupportedElement(ElementType)
    case invalidModel(String)
    case noFreeDegreesOfFreedom
    case unconstrainedDegreesOfFreedom([Int])
    case conflictingConstraint(dof: Int)
    case invalidConstraint(dof: Int)
    case invalidLoad(String)
    case nonFiniteSolution
    case solver(SparseSolverError)
    case solverFailure(String)
}
