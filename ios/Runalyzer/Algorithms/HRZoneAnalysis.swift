import Foundation

/// Pure computation of time spent in each heart-rate zone from timestamped samples.
enum HRZoneAnalysis {

    struct ZoneDefinition {
        let name: String
        let range: ClosedRange<Double>
    }

    struct ZoneTime {
        let name: String
        let seconds: Double
        let fraction: Double
    }

    /// Compute time-per-zone from HR samples and zone definitions.
    /// Each sample's duration is the interval until the next sample;
    /// the last sample uses the average interval.
    static func compute(
        hrValues: [(value: Double, timestamp: Date)],
        zones: [ZoneDefinition]
    ) -> [ZoneTime] {
        let sorted = hrValues.sorted { $0.timestamp < $1.timestamp }
        var zoneSeconds: [Int: Double] = [:]

        for i in 0..<sorted.count {
            let hr = sorted[i].value
            let interval: Double
            if i < sorted.count - 1 {
                interval = sorted[i + 1].timestamp.timeIntervalSince(sorted[i].timestamp)
            } else if sorted.count > 1, let first = sorted.first, let last = sorted.last {
                let total = last.timestamp.timeIntervalSince(first.timestamp)
                interval = total / Double(sorted.count - 1)
            } else {
                interval = 0
            }
            for (j, zone) in zones.enumerated() {
                if zone.range.contains(hr) {
                    zoneSeconds[j, default: 0] += interval
                    break
                }
            }
        }

        let totalSec = zoneSeconds.values.reduce(0, +)
        return zones.enumerated().map { i, zone in
            let sec = zoneSeconds[i] ?? 0
            return ZoneTime(name: zone.name, seconds: sec,
                            fraction: totalSec > 0 ? sec / totalSec : 0)
        }
    }
}
