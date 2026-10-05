import Foundation

/// Tileable blue-noise texture, generated with Ulichney's void-and-cluster method.
///
/// Every value in [0, 1) appears once, and similar values sit far apart, so the error from using these
/// as random numbers is high-frequency. The denoiser's spatial filter removes that kind of error much
/// better than the blotchy, low-frequency error of white noise.
enum BlueNoise {
    static let size = 128   // must match BLUE_NOISE_SIZE in Shaders/Sampling.metal

    /// Returns `size * size` values, row-major: (rank + 0.5) / count.
    static func generate(size n: Int = BlueNoise.size, sigma: Float = 1.9, seed: UInt64 = 1) -> [Float] {
        let count = n * n
        // Toroidal Gaussian, truncated where it falls below ~0.1% of its peak.
        let radius = Int((sigma * 3.7).rounded(.up))
        let width = 2 * radius + 1
        var kernel = [Float](repeating: 0, count: width * width)
        for dy in -radius...radius {
            for dx in -radius...radius {
                kernel[(dy + radius) * width + dx + radius] = exp(-Float(dx * dx + dy * dy) / (2 * sigma * sigma))
            }
        }

        var energy = [Float](repeating: 0, count: count)   // sum of kernel weights from every set pixel
        var isSet = [Bool](repeating: false, count: count)
        func splat(_ i: Int, _ sign: Float) {
            let x = i % n, y = i / n
            for dy in -radius...radius {
                let row = ((y + dy + n) % n) * n
                let k = (dy + radius) * width + radius
                for dx in -radius...radius {
                    energy[row + (x + dx + n) % n] += sign * kernel[k + dx]
                }
            }
        }
        func tightestCluster() -> Int {   // the set pixel with the most set neighbors
            var best = -1; var bestE = -Float.infinity
            for i in 0..<count where isSet[i] && energy[i] > bestE { best = i; bestE = energy[i] }
            return best
        }
        func largestVoid() -> Int {       // the empty pixel with the fewest set neighbors
            var best = -1; var bestE = Float.infinity
            for i in 0..<count where !isSet[i] && energy[i] < bestE { best = i; bestE = energy[i] }
            return best
        }

        // 1. Random initial pattern (10% of pixels), relaxed into an even distribution.
        var rng = SplitMix64(seed: seed)
        let initial = count / 10
        var placed = 0
        while placed < initial {
            let i = Int(rng.next() % UInt64(count))
            if !isSet[i] { isSet[i] = true; splat(i, 1); placed += 1 }
        }
        while true {
            let cluster = tightestCluster()
            isSet[cluster] = false; splat(cluster, -1)
            let void = largestVoid()
            isSet[void] = true; splat(void, 1)
            if void == cluster { break }
        }
        let relaxed = isSet, relaxedEnergy = energy

        // 2. Rank the initial points: removing the tightest cluster each time gives ranks initial-1 ... 0.
        var rank = [Int](repeating: 0, count: count)
        for r in stride(from: initial - 1, through: 0, by: -1) {
            let cluster = tightestCluster()
            isSet[cluster] = false; splat(cluster, -1)
            rank[cluster] = r
        }

        // 3. From the initial pattern, filling the largest void each time gives ranks initial ... count-1.
        //    (With a kernel whose weights sum to a constant this covers both of Ulichney's later phases.)
        isSet = relaxed; energy = relaxedEnergy
        for r in initial..<count {
            let void = largestVoid()
            isSet[void] = true; splat(void, 1)
            rank[void] = r
        }
        return rank.map { (Float($0) + 0.5) / Float(count) }
    }

    /// The default tile, kept in the user's cache folder: generating it takes about half a second.
    static var cacheURL: URL { CacheFile.userFolder.appendingPathComponent("bluenoise-\(size)-s1.9-seed1-v1.bin") }

    /// The cached tile, if it is there and whole.
    static func cached() -> [Float]? {
        guard let data = try? Data(contentsOf: cacheURL), data.count == size * size * MemoryLayout<Float>.stride else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// The default tile: from the cache, or generated now and cached for the next launch.
    static func tile() -> [Float] {
        if let values = cached() { return values }
        let values = generate()
        try? CacheFile.write(values.withUnsafeBytes { Data($0) }, to: cacheURL)
        return values
    }

    struct SplitMix64: RandomNumberGenerator {   // also the dataset's camera tracks
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
