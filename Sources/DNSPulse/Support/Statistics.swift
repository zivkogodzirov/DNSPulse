import Foundation

/// The few significance tests DNS Pulse needs to tell a real winner from measurement noise.
enum Statistics {
    /// z for a two-sided 83.4% interval. Two such intervals that don't overlap correspond to roughly a 5% test
    /// when their widths are similar (Payton, Greenstone & Schenker 2003); 95% intervals would be far stricter.
    static let overlapZ = 1.386

    /// Two-sided p-value of Welch's t-test (unequal variances) for the difference between two means.
    /// Nil when either side has fewer than two samples.
    static func welchPValue(_ a: LatencyStats, _ b: LatencyStats) -> Double? {
        guard a.count >= 2, b.count >= 2, a.mean.isFinite, b.mean.isFinite else { return nil }
        let va = a.stdDev * a.stdDev / Double(a.count)
        let vb = b.stdDev * b.stdDev / Double(b.count)
        let variance = va + vb
        guard variance > 0 else { return a.mean == b.mean ? 1 : 0 }
        let t = (a.mean - b.mean) / variance.squareRoot()
        let df = variance * variance / (va * va / Double(a.count - 1) + vb * vb / Double(b.count - 1))
        return studentTwoSided(t: t, df: df)
    }

    /// Two-sided p-value of Fisher's exact test: how likely `failuresA` of `attemptsA` and `failuresB` of
    /// `attemptsB` are if both sides fail equally often. Exact, so it stays right for rare failures (0 of 1,000
    /// against 5 of 1,000), where a t-test or normal approximation does not.
    static func fisherExactPValue(_ failuresA: Int, of attemptsA: Int, _ failuresB: Int, of attemptsB: Int) -> Double {
        let failures = failuresA + failuresB
        let total = attemptsA + attemptsB
        guard attemptsA > 0, attemptsB > 0, failures > 0, failures < total else { return 1 }
        func logChoose(_ n: Int, _ k: Int) -> Double {
            lgamma(Double(n + 1)) - lgamma(Double(k + 1)) - lgamma(Double(n - k + 1))
        }
        let logAll = logChoose(total, failures)
        func probability(_ k: Int) -> Double { exp(logChoose(attemptsA, k) + logChoose(attemptsB, failures - k) - logAll) }
        // Every split of the failures at most as likely as the one observed (with a little slack for rounding).
        let observed = probability(failuresA) * (1 + 1e-7)
        var p = 0.0
        for k in max(0, failures - attemptsB)...min(attemptsA, failures) {
            let pk = probability(k)
            if pk <= observed { p += pk }
        }
        return min(1, p)
    }

    /// P(|T| ≥ |t|) for Student's t with `df` degrees of freedom.
    static func studentTwoSided(t: Double, df: Double) -> Double {
        guard t.isFinite, df > 0 else { return 0 }
        return regularizedIncompleteBeta(df / (df + t * t), a: df / 2, b: 0.5)
    }

    /// Distribution-free confidence interval for the `q` quantile of `sorted`, from order statistics
    /// (normal approximation to the binomial). When a bound needs a rank past either end of the sample, there are
    /// too few samples to set it, so that end is open (−∞ or +∞) rather than the smallest or largest sample.
    static func quantileInterval(_ sorted: [Double], q: Double, z: Double) -> ClosedRange<Double>? {
        guard sorted.count >= 2 else { return nil }
        let n = Double(sorted.count)
        let spread = z * (n * q * (1 - q)).squareRoot()
        let lower = Int((n * q - spread).rounded(.down))
        let upper = Int((n * q + spread).rounded(.up))
        return (lower < 1 ? -.infinity : sorted[lower - 1])...(upper > sorted.count ? .infinity : sorted[upper - 1])
    }

    /// I_x(a, b), via the continued fraction in Numerical Recipes (Lentz's method).
    static func regularizedIncompleteBeta(_ x: Double, a: Double, b: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let front = exp(lgamma(a + b) - lgamma(a) - lgamma(b) + a * log(x) + b * log(1 - x))
        if x < (a + 1) / (a + b + 2) {
            return front * betaContinuedFraction(x, a: a, b: b) / a
        }
        return 1 - front * betaContinuedFraction(1 - x, a: b, b: a) / b
    }

    private static func betaContinuedFraction(_ x: Double, a: Double, b: Double) -> Double {
        let tiny = 1e-300
        var c = 1.0
        var d = 1 - (a + b) * x / (a + 1)
        if abs(d) < tiny { d = tiny }
        d = 1 / d
        var result = d
        for step in 1...300 {
            let m = Double(step)
            let even = m * (b - m) * x / ((a + 2 * m - 1) * (a + 2 * m))
            d = 1 + even * d
            if abs(d) < tiny { d = tiny }
            c = 1 + even / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            result *= d * c
            let odd = -(a + m) * (a + b + m) * x / ((a + 2 * m) * (a + 2 * m + 1))
            d = 1 + odd * d
            if abs(d) < tiny { d = tiny }
            c = 1 + odd / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            let delta = d * c
            result *= delta
            if abs(delta - 1) < 3e-14 { break }
        }
        return result
    }
}

extension Format {
    /// "12.4 ± 0.8 ms": both numbers at the precision the margin supports.
    static func ms(_ value: Double, margin: Double) -> String {
        guard value.isFinite, margin.isFinite else { return ms(value) }
        let decimals = margin < 0.1 ? 2 : margin < 10 ? 1 : 0
        return String(format: "%.\(decimals)f ± %.\(decimals)f ms", value, margin)
    }
}
