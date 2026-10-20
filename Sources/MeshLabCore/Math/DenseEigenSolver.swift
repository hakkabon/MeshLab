import Accelerate
import Foundation

enum DenseEigenSolverError: Error, Equatable, Sendable {
    case invalidDimensions
    case nonFiniteInput
    case massNotPositiveDefinite
    case didNotConverge
}

/// Dense symmetric generalized eigensolver for `K φ = λ M φ`.
///
/// This wraps LAPACK's `dsygv`, which returns eigenvalues in ascending order
/// and mass-normalized eigenvectors (`φᵀ M φ = I`). Matrices are row-major
/// arrays of length `size * size`.
enum SymmetricGeneralizedEigenSolver {
    static func solve(
        stiffness: [Double],
        mass: [Double],
        size: Int
    ) throws -> (eigenvalues: [Double], eigenvectors: [[Double]]) {
        guard size > 0,
              stiffness.count == size * size,
              mass.count == size * size else {
            throw DenseEigenSolverError.invalidDimensions
        }
        guard (stiffness + mass).allSatisfy(\.isFinite) else {
            throw DenseEigenSolverError.nonFiniteInput
        }

        let count = Int32(size)
        var itype: Int32 = 1
        var jobz = Int8(UInt8(ascii: "V"))
        var uplo = Int8(UInt8(ascii: "U"))
        var n = count
        var lda = count
        var ldb = count
        var info: Int32 = 0
        var eigenvalues = [Double](repeating: 0, count: size)
        var a = [Double](repeating: 0, count: size * size)
        var b = [Double](repeating: 0, count: size * size)
        for row in 0..<size {
            for column in 0..<size {
                a[column * size + row] = stiffness[row * size + column]
                b[column * size + row] = mass[row * size + column]
            }
        }

        var query = [Double](repeating: 0, count: 1)
        var queryLength: Int32 = -1
        _ = a.withUnsafeMutableBufferPointer { aBuffer in
            b.withUnsafeMutableBufferPointer { bBuffer in
                eigenvalues.withUnsafeMutableBufferPointer { valueBuffer in
                    query.withUnsafeMutableBufferPointer { queryBuffer in
                        dsygv_(
                            &itype,
                            &jobz,
                            &uplo,
                            &n,
                            aBuffer.baseAddress,
                            &lda,
                            bBuffer.baseAddress,
                            &ldb,
                            valueBuffer.baseAddress,
                            queryBuffer.baseAddress,
                            &queryLength,
                            &info
                        )
                    }
                }
            }
        }
        guard info == 0, let rawLength = query.first, rawLength.isFinite else {
            throw DenseEigenSolverError.didNotConverge
        }

        var workspace = [Double](
            repeating: 0,
            count: max(1, Int(rawLength.rounded(.up)))
        )
        var workspaceLength = Int32(workspace.count)
        info = 0
        _ = a.withUnsafeMutableBufferPointer { aBuffer in
            b.withUnsafeMutableBufferPointer { bBuffer in
                eigenvalues.withUnsafeMutableBufferPointer { valueBuffer in
                    workspace.withUnsafeMutableBufferPointer { workspaceBuffer in
                        dsygv_(
                            &itype,
                            &jobz,
                            &uplo,
                            &n,
                            aBuffer.baseAddress,
                            &lda,
                            bBuffer.baseAddress,
                            &ldb,
                            valueBuffer.baseAddress,
                            workspaceBuffer.baseAddress,
                            &workspaceLength,
                            &info
                        )
                    }
                }
            }
        }

        if info > 0, Int(info) <= size {
            throw DenseEigenSolverError.didNotConverge
        }
        if info > size {
            throw DenseEigenSolverError.massNotPositiveDefinite
        }
        guard info == 0, eigenvalues.allSatisfy(\.isFinite) else {
            throw DenseEigenSolverError.didNotConverge
        }

        var eigenvectors = [[Double]](
            repeating: [Double](repeating: 0, count: size),
            count: size
        )
        for mode in 0..<size {
            for row in 0..<size {
                eigenvectors[mode][row] = a[mode * size + row]
            }
        }
        return (eigenvalues, eigenvectors)
    }
}
