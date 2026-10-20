import Accelerate
import Foundation

/// Vector operations backed by Accelerate's vDSP and vForce libraries.
///
/// These helpers intentionally operate on `[Double]` so they can be used
/// directly by the solver, assembly, and post-processing code without an
/// intermediate representation. Every operation maps to a vectorized
/// Accelerate kernel rather than a Swift loop.
public enum VectorMath {
    public static func zeros(_ count: Int) -> [Double] {
        [Double](repeating: 0, count: count)
    }

    public static func add(_ a: [Double], _ b: [Double]) -> [Double] {
        precondition(a.count == b.count, "Vector sizes must match")
        return vDSP.add(a, b)
    }

    public static func subtract(_ a: [Double], _ b: [Double]) -> [Double] {
        precondition(a.count == b.count, "Vector sizes must match")
        return vDSP.subtract(a, b)
    }

    public static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        precondition(a.count == b.count, "Vector sizes must match")
        return vDSP.multiply(a, b)
    }

    public static func divide(_ a: [Double], _ b: [Double]) -> [Double] {
        precondition(a.count == b.count, "Vector sizes must match")
        return vDSP.divide(a, b)
    }

    public static func scale(_ values: [Double], by scalar: Double) -> [Double] {
        vDSP.multiply(scalar, values)
    }

    /// Computes `y + alpha * x`.
    public static func addScaled(_ y: [Double], _ x: [Double], alpha: Double) -> [Double] {
        precondition(y.count == x.count, "Vector sizes must match")
        var result = vDSP.multiply(alpha, x)
        vDSP.add(y, result, result: &result)
        return result
    }

    public static func dot(_ a: [Double], _ b: [Double]) -> Double {
        precondition(a.count == b.count, "Vector sizes must match")
        return vDSP.dot(a, b)
    }

    public static func sum(_ values: [Double]) -> Double {
        vDSP.sum(values)
    }

    public static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return vDSP.mean(values)
    }

    public static func norm(_ values: [Double]) -> Double {
        Foundation.sqrt(dot(values, values))
    }

    public static func maximum(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : vDSP.maximum(values)
    }

    public static func minimum(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : vDSP.minimum(values)
    }

    public static func square(_ values: [Double]) -> [Double] {
        vDSP.square(values)
    }

    public static func subtract(_ scalar: Double, from values: [Double]) -> [Double] {
        vDSP.add(-scalar, values)
    }

    public static func clip(_ values: [Double], to range: ClosedRange<Double>) -> [Double] {
        let lower = [Double](repeating: range.lowerBound, count: values.count)
        let upper = [Double](repeating: range.upperBound, count: values.count)
        let atLeastLower = vDSP.maximum(values, lower)
        return vDSP.minimum(atLeastLower, upper)
    }

    /// Element-wise square root using vForce.
    public static func sqrt(_ values: [Double]) -> [Double] {
        guard !values.isEmpty else { return [] }
        var result = [Double](repeating: 0, count: values.count)
        var count = Int32(values.count)
        vvsqrt(&result, values, &count)
        return result
    }

    /// Element-wise exponential using vForce.
    public static func exp(_ values: [Double]) -> [Double] {
        guard !values.isEmpty else { return [] }
        var result = [Double](repeating: 0, count: values.count)
        var count = Int32(values.count)
        vvexp(&result, values, &count)
        return result
    }

    /// Element-wise conversion to `Float`.
    public static func float(_ values: [Double]) -> [Float] {
        guard !values.isEmpty else { return [] }
        var result = [Float](repeating: 0, count: values.count)
        let count = vDSP_Length(values.count)
        vDSP_vdpsp(values, 1, &result, 1, count)
        return result
    }

    public static func normalize(_ values: [Double]) -> [Double] {
        let length = norm(values)
        guard length > .ulpOfOne else { return zeros(values.count) }
        return scale(values, by: 1 / length)
    }
}
