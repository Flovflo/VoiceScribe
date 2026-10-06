import Foundation

public enum AudioConditions {
    /// Adds deterministic, zero-mean uniform white noise at the requested RMS
    /// signal-to-noise ratio. No clipping or amplitude normalization follows.
    public static func addingNoise(_ samples: [Float], snrDB: Double, seed: UInt64 = 42) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let signalPower = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        guard signalPower > 0 else { return samples }
        var state = seed
        var noise = samples.map { _ -> Double in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(UInt64(1) << 53) * 2 - 1
        }
        let mean = noise.reduce(0, +) / Double(noise.count)
        noise = noise.map { $0 - mean }
        let noisePower = noise.reduce(0.0) { $0 + $1 * $1 }
        guard noisePower > 0 else { return samples }
        let scale = sqrt(signalPower / (pow(10, snrDB / 10) * noisePower))
        return zip(samples, noise).map { $0 + Float($1 * scale) }
    }
}
