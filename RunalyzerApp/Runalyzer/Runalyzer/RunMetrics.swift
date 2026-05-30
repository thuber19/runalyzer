import Foundation
import Combine

class RunMetrics: ObservableObject {
    // Published metrics
    @Published var cadence: Int = 0
    @Published var bounce: Float = 0
    @Published var peakImpact: Float = 0
    @Published var symmetryLeft: Float = 50
    @Published var symmetryRight: Float = 50
    @Published var symmetryVerdict: String = "Waiting..."
    @Published var batteryLevel: Int = -1
    @Published var sampleCount: Int = 0
    @Published var lastTimestamp: UInt32 = 0

    // Chart data (orientation-independent magnitudes)
    @Published var accelHistory: [Float] = []
    @Published var gyroHistory: [Float] = []
    @Published var stepIntervals: [Float] = []

    private let historySize = 500 // 5 seconds at 100Hz

    // Step detection state
    private var filteredAccel: Float = 0
    private var prevFilteredAccel: Float = 0
    private var prevSlope: Float = 0
    private let liveThreshold: Float = 0.08 // adaptive would be better, but this works for most
    private var lastStepTime: UInt32 = 0
    private var recentStepIntervals: [Float] = []
    private var peakCooldown: Int = 0

    // Symmetry state
    private var rotLeft: Float = 0
    private var rotRight: Float = 0
    private let symmetryDecay: Float = 0.998

    func process(_ p: IMUPacket) {
        let accelMag = p.accelMagnitude
        let gyroMag = p.gyroMagnitude

        // History
        accelHistory.append(accelMag)
        gyroHistory.append(gyroMag)
        if accelHistory.count > historySize { accelHistory.removeFirst() }
        if gyroHistory.count > historySize { gyroHistory.removeFirst() }

        // Peak impact — decays to baseline over ~3 seconds (0.99^100 ≈ 0.37)
        if accelMag > peakImpact { peakImpact = accelMag }
        peakImpact = 1.0 + (peakImpact - 1.0) * 0.99

        // Bounce (peak-to-peak in recent window)
        if accelHistory.count > 100 {
            let recent = accelHistory.suffix(200)
            let min = recent.min() ?? 0
            let max = recent.max() ?? 0
            bounce = max - min
        }

        // Step detection — peak in filtered accel (gravity removed, smoothed)
        let noGrav = accelMag - 1.0
        let alphaF: Float = 0.1
        filteredAccel = alphaF * noGrav + (1 - alphaF) * filteredAccel
        let slope = filteredAccel - prevFilteredAccel
        if prevSlope > 0 && slope <= 0 && filteredAccel > liveThreshold && peakCooldown <= 0 {
            if lastStepTime > 0 {
                let interval = Float(p.timestamp - lastStepTime)
                if interval > 250 && interval < 1200 {
                    recentStepIntervals.append(interval)
                    if recentStepIntervals.count > 12 { recentStepIntervals.removeFirst() }
                    let avg = recentStepIntervals.reduce(0, +) / Float(recentStepIntervals.count)
                    cadence = Int(60000 / avg)

                    stepIntervals.append(interval)
                    if stepIntervals.count > 100 { stepIntervals.removeFirst() }
                }
            }
            lastStepTime = p.timestamp
            peakCooldown = 30
        }
        if peakCooldown > 0 { peakCooldown -= 1 }

        // Reset cadence if no step detected for 2 seconds
        if lastStepTime > 0 && (p.timestamp - lastStepTime) > 2000 {
            cadence = 0
            recentStepIntervals.removeAll()
        }

        prevFilteredAccel = filteredAccel
        prevSlope = slope

        // Symmetry — dominant gyro axis direction
        let g = p.gyroDPS
        let absX = abs(g.x), absY = abs(g.y), absZ = abs(g.z)
        let maxAbs = max(absX, max(absY, absZ))
        let dominant: Float = (absX == maxAbs) ? g.x : (absY == maxAbs) ? g.y : g.z

        rotLeft *= symmetryDecay
        rotRight *= symmetryDecay
        if dominant > 5 { rotRight += gyroMag * 0.01 }
        else if dominant < -5 { rotLeft += gyroMag * 0.01 }

        let total = rotLeft + rotRight
        if total > 0.1 {
            symmetryLeft = (rotLeft / total) * 100
            symmetryRight = 100 - symmetryLeft
            let diff = abs(symmetryLeft - symmetryRight)
            let side = symmetryLeft > symmetryRight ? "left" : "right"
            if diff < 10 {
                symmetryVerdict = "Symmetric gait"
            } else if diff < 20 {
                symmetryVerdict = "Slight asymmetry (\(side))"
            } else {
                symmetryVerdict = "Asymmetric (\(side))"
            }
        }

        sampleCount += 1
        lastTimestamp = p.timestamp
    }

    func reset() {
        cadence = 0; bounce = 0; peakImpact = 0
        symmetryLeft = 50; symmetryRight = 50
        symmetryVerdict = "Waiting..."
        accelHistory.removeAll(); gyroHistory.removeAll()
        stepIntervals.removeAll()
        filteredAccel = 0; prevFilteredAccel = 0; prevSlope = 0
        lastStepTime = 0; recentStepIntervals.removeAll()
        peakCooldown = 0; rotLeft = 0; rotRight = 0
        sampleCount = 0; lastTimestamp = 0
    }

    // MARK: - Offline step analysis with proper signal processing
    static func analyzeRecording(_ samples: [RecordedSample]) -> RecordingAnalysis {
        guard samples.count > 50 else {
            return RecordingAnalysis.empty
        }

        // Step 1: Compute accel magnitude + gyro per sample
        var rawMag: [Float] = []
        var timestamps: [UInt32] = []
        var gyroX: [Float] = [], gyroY: [Float] = [], gyroZ: [Float] = []

        for s in samples {
            let ax = Float(s.ax) * IMUPacket.accelScale
            let ay = Float(s.ay) * IMUPacket.accelScale
            let az = Float(s.az) * IMUPacket.accelScale
            rawMag.append(sqrtf(ax*ax + ay*ay + az*az))
            timestamps.append(s.timestamp)
            gyroX.append(Float(s.gx) * IMUPacket.gyroScale)
            gyroY.append(Float(s.gy) * IMUPacket.gyroScale)
            gyroZ.append(Float(s.gz) * IMUPacket.gyroScale)
        }

        // Step 2: Remove gravity
        let noGravity = rawMag.map { $0 - 1.0 }

        // Step 3: Low-pass filter (alpha=0.1 → ~1.6Hz cutoff at 100Hz)
        let alpha: Float = 0.1
        var filtered = [Float](repeating: 0, count: noGravity.count)
        filtered[0] = noGravity[0]
        for i in 1..<noGravity.count {
            filtered[i] = alpha * noGravity[i] + (1 - alpha) * filtered[i-1]
        }

        // Step 4: Dynamic threshold
        let mean = filtered.reduce(0, +) / Float(filtered.count)
        let variance = filtered.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(filtered.count)
        let stdDev = sqrtf(variance)
        let threshold = max(0.05, stdDev * 0.6)

        // Step 5: Peak detection
        var stepIndices: [Int] = []
        var lastStepTs: UInt32 = 0
        var intervals: [Float] = []

        var prevVal = filtered[0]
        var prevSlope: Float = 0

        for i in 1..<filtered.count {
            let val = filtered[i]
            let slope = val - prevVal

            if prevSlope > 0 && slope <= 0 && prevVal > threshold {
                let ts = timestamps[i-1]
                if lastStepTs > 0 {
                    let interval = Float(ts - lastStepTs)
                    if interval >= 250 && interval <= 1500 {
                        intervals.append(interval)
                        stepIndices.append(i-1)
                    }
                } else {
                    stepIndices.append(i-1)
                }
                lastStepTs = ts
            }

            prevVal = val
            prevSlope = slope
        }

        // Step 6: Determine dominant gyro axis for L/R detection
        // Find which gyro axis has the most variance — that's the pelvic rotation axis
        func variance(_ arr: [Float]) -> Float {
            let m = arr.reduce(0, +) / Float(arr.count)
            return arr.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Float(arr.count)
        }
        let varX = variance(gyroX)
        let varY = variance(gyroY)
        let varZ = variance(gyroZ)
        let dominantGyro: [Float]
        let dominantAxis: String
        if varX >= varY && varX >= varZ {
            dominantGyro = gyroX; dominantAxis = "X"
        } else if varY >= varX && varY >= varZ {
            dominantGyro = gyroY; dominantAxis = "Y"
        } else {
            dominantGyro = gyroZ; dominantAxis = "Z"
        }

        // Low-pass filter the dominant gyro axis too
        var filteredGyro = [Float](repeating: 0, count: dominantGyro.count)
        filteredGyro[0] = dominantGyro[0]
        for i in 1..<dominantGyro.count {
            filteredGyro[i] = alpha * dominantGyro[i] + (1 - alpha) * filteredGyro[i-1]
        }

        // Step 7: Classify each step as Side A or Side B based on gyro sign at step
        // Average the gyro over a small window around the step peak
        var detectedSteps: [DetectedStep] = []
        let windowSize = 10 // ±10 samples around peak

        for idx in stepIndices {
            let start = max(0, idx - windowSize)
            let end = min(filteredGyro.count - 1, idx + windowSize)
            let gyroSlice = filteredGyro[start...end]
            let avgGyro = gyroSlice.reduce(0, +) / Float(gyroSlice.count)

            let side: StepSide = avgGyro >= 0 ? .sideA : .sideB

            detectedSteps.append(DetectedStep(
                timestamp: timestamps[idx],
                sampleIndex: idx,
                accelMag: rawMag[idx],
                filteredAccel: filtered[idx],
                gyroValue: avgGyro,
                side: side
            ))
        }

        let avgCadence: Float
        if !intervals.isEmpty {
            let avgInterval = intervals.reduce(0, +) / Float(intervals.count)
            avgCadence = 60000 / avgInterval
        } else {
            avgCadence = 0
        }

        let accelMag = zip(timestamps, rawMag).map { (timestamp: $0, value: $1) }
        let filteredTimeline = zip(timestamps, filtered).map { (timestamp: $0, value: $1) }
        let gyroTimeline = zip(timestamps, filteredGyro).map { (timestamp: $0, value: $1) }

        return RecordingAnalysis(
            totalSteps: detectedSteps.count,
            avgCadence: avgCadence,
            steps: detectedSteps,
            accelMag: accelMag,
            filtered: filteredTimeline,
            gyroFiltered: gyroTimeline,
            dynamicThreshold: threshold,
            dominantGyroAxis: dominantAxis
        )
    }
}

// MARK: - Step Data Types

enum StepSide: String {
    case sideA = "A"
    case sideB = "B"
}

struct DetectedStep {
    let timestamp: UInt32
    let sampleIndex: Int
    let accelMag: Float      // raw accel magnitude at step
    let filteredAccel: Float  // filtered accel at step
    let gyroValue: Float      // filtered gyro value (determines side)
    let side: StepSide
}

struct RecordingAnalysis {
    let totalSteps: Int
    let avgCadence: Float
    let steps: [DetectedStep]
    let accelMag: [(timestamp: UInt32, value: Float)]
    let filtered: [(timestamp: UInt32, value: Float)]
    let gyroFiltered: [(timestamp: UInt32, value: Float)]
    let dynamicThreshold: Float
    let dominantGyroAxis: String

    static let empty = RecordingAnalysis(
        totalSteps: 0, avgCadence: 0, steps: [],
        accelMag: [], filtered: [], gyroFiltered: [],
        dynamicThreshold: 0, dominantGyroAxis: ""
    )

    var peakG: Float { accelMag.map(\.value).max() ?? 0 }
    var minG: Float { accelMag.map(\.value).min() ?? 0 }
    var bounceG: Float { peakG - minG }

    var stepsA: [DetectedStep] { steps.filter { $0.side == .sideA } }
    var stepsB: [DetectedStep] { steps.filter { $0.side == .sideB } }

    var avgImpactA: Float {
        let s = stepsA; return s.isEmpty ? 0 : s.map(\.accelMag).reduce(0, +) / Float(s.count)
    }
    var avgImpactB: Float {
        let s = stepsB; return s.isEmpty ? 0 : s.map(\.accelMag).reduce(0, +) / Float(s.count)
    }
}
