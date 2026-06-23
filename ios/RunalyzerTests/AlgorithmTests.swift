import XCTest
@testable import Runalyzer

final class BodyCompositionTests: XCTestCase {

    func testMaleBodyComposition() {
        let profile = UserProfile(heightCm: 180, age: 30, sex: .male)
        let result = BodyComposition.calculate(weightKg: 80, impedanceOhm: 500, profile: profile)

        XCTAssertEqual(result.weightKg, 80.0)
        XCTAssertGreaterThan(result.bmi, 20)
        XCTAssertLessThan(result.bmi, 30)
        XCTAssertGreaterThan(result.bodyFatPercent, 5)
        XCTAssertLessThan(result.bodyFatPercent, 40)
        XCTAssertGreaterThan(result.fatFreeMassKg, 40)
        XCTAssertGreaterThan(result.muscleMassKg, 30)
        XCTAssertGreaterThan(result.bodyWaterPercent, 40)
        XCTAssertGreaterThan(result.bmrKcal, 1500)
        XCTAssertEqual(result.impedanceOhm, 500)
    }

    func testFemaleBodyComposition() {
        let profile = UserProfile(heightCm: 165, age: 25, sex: .female)
        let result = BodyComposition.calculate(weightKg: 60, impedanceOhm: 550, profile: profile)

        XCTAssertEqual(result.weightKg, 60.0)
        XCTAssertGreaterThan(result.bodyFatPercent, 10)
        XCTAssertLessThan(result.bodyFatPercent, 50)
        XCTAssertGreaterThan(result.bmrKcal, 1100)
        XCTAssertLessThan(result.bmrKcal, 1800)
    }

    func testBMICalculation() {
        let profile = UserProfile(heightCm: 180, age: 30, sex: .male)
        let result = BodyComposition.calculate(weightKg: 81, impedanceOhm: 500, profile: profile)
        // BMI = 81 / (1.8 * 1.8) = 25.0
        XCTAssertEqual(result.bmi, 25.0, accuracy: 0.1)
    }

    func testFatMassNeverNegative() {
        // Very low impedance could theoretically make FFM > weight
        let profile = UserProfile(heightCm: 190, age: 20, sex: .male)
        let result = BodyComposition.calculate(weightKg: 50, impedanceOhm: 200, profile: profile)
        XCTAssertGreaterThanOrEqual(result.fatMassKg, 0)
        XCTAssertGreaterThanOrEqual(result.bodyFatPercent, 0)
    }
}

final class SleepScoreTests: XCTestCase {

    func testPerfectSleep() {
        let input = SleepScore.NightInput(
            asleepMinutes: 470,  // target
            deepMinutes: 100,    // ~21% (healthy range)
            remMinutes: 110,     // ~23% (healthy range)
            awakeMinutes: 5,
            wakeEvents: 1,
            bedtime: makeTime(hour: 22, minute: 30),
            averageBedtime: makeTime(hour: 22, minute: 30)
        )
        let result = SleepScore.compute(input)

        XCTAssertGreaterThanOrEqual(result.total, 85)
        XCTAssertEqual(result.label, "Excellent")
        XCTAssertEqual(result.durationScore + result.qualityScore + result.consistencyScore + result.interruptionScore, result.total)
    }

    func testShortSleep() {
        let input = SleepScore.NightInput(
            asleepMinutes: 300,  // 5 hours
            deepMinutes: 60,
            remMinutes: 70,
            awakeMinutes: 10,
            wakeEvents: 2,
            bedtime: makeTime(hour: 23, minute: 0),
            averageBedtime: makeTime(hour: 23, minute: 0)
        )
        let result = SleepScore.compute(input)

        XCTAssertLessThan(result.total, 75)
        XCTAssertLessThan(result.durationScore, 40)
    }

    func testLateBedtime() {
        let input = SleepScore.NightInput(
            asleepMinutes: 470,
            deepMinutes: 100,
            remMinutes: 110,
            awakeMinutes: 5,
            wakeEvents: 1,
            bedtime: makeTime(hour: 2, minute: 0),   // 2 AM
            averageBedtime: makeTime(hour: 22, minute: 30)  // normally 10:30 PM
        )
        let result = SleepScore.compute(input)

        XCTAssertLessThan(result.consistencyScore, 20)
    }

    func testManyWakeEvents() {
        let input = SleepScore.NightInput(
            asleepMinutes: 470,
            deepMinutes: 100,
            remMinutes: 110,
            awakeMinutes: 30,
            wakeEvents: 8,
            bedtime: makeTime(hour: 22, minute: 30),
            averageBedtime: makeTime(hour: 22, minute: 30)
        )
        let result = SleepScore.compute(input)

        XCTAssertLessThan(result.interruptionScore, 15)
    }

    func testNoBaselineBedtime() {
        let input = SleepScore.NightInput(
            asleepMinutes: 470,
            deepMinutes: 100,
            remMinutes: 110,
            awakeMinutes: 5,
            wakeEvents: 1,
            bedtime: makeTime(hour: 22, minute: 30),
            averageBedtime: nil
        )
        let result = SleepScore.compute(input)

        // Full consistency credit when no baseline
        XCTAssertEqual(result.consistencyScore, 30)
    }

    func testScoreComponentsAddUp() {
        let input = SleepScore.NightInput(
            asleepMinutes: 400, deepMinutes: 80, remMinutes: 90,
            awakeMinutes: 15, wakeEvents: 3,
            bedtime: makeTime(hour: 23, minute: 0),
            averageBedtime: makeTime(hour: 22, minute: 0)
        )
        let result = SleepScore.compute(input)

        XCTAssertEqual(result.total, result.durationScore + result.qualityScore + result.consistencyScore + result.interruptionScore)
        XCTAssertGreaterThanOrEqual(result.durationScore, 0)
        XCTAssertLessThanOrEqual(result.durationScore, 40)
        XCTAssertGreaterThanOrEqual(result.qualityScore, 0)
        XCTAssertLessThanOrEqual(result.qualityScore, 10)
        XCTAssertGreaterThanOrEqual(result.consistencyScore, 0)
        XCTAssertLessThanOrEqual(result.consistencyScore, 30)
        XCTAssertGreaterThanOrEqual(result.interruptionScore, 0)
        XCTAssertLessThanOrEqual(result.interruptionScore, 20)
    }

    func testScoreLabels() {
        XCTAssertEqual(SleepScore.label(for: 90), "Excellent")
        XCTAssertEqual(SleepScore.label(for: 75), "Excellent")
        XCTAssertEqual(SleepScore.label(for: 60), "Good")
        XCTAssertEqual(SleepScore.label(for: 30), "Fair")
        XCTAssertEqual(SleepScore.label(for: 10), "Poor")
    }

    private func makeTime(hour: Int, minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date())!
    }
}

final class HRZoneAnalysisTests: XCTestCase {

    private let zones = [
        HRZoneAnalysis.ZoneDefinition(name: "Zone 1", range: 95...114),
        HRZoneAnalysis.ZoneDefinition(name: "Zone 2", range: 114...133),
        HRZoneAnalysis.ZoneDefinition(name: "Zone 3", range: 133...152),
        HRZoneAnalysis.ZoneDefinition(name: "Zone 4", range: 152...171),
        HRZoneAnalysis.ZoneDefinition(name: "Zone 5", range: 171...190),
    ]

    func testAllSamplesInOneZone() {
        let now = Date()
        let samples: [(value: Double, timestamp: Date)] = [
            (120, now),
            (125, now.addingTimeInterval(60)),
            (122, now.addingTimeInterval(120)),
        ]

        let result = HRZoneAnalysis.compute(hrValues: samples, zones: zones)

        // All samples are in Zone 2 (114-133)
        // 3 samples at 60s intervals: first two have 60s each, last uses avg interval (60s) = 180s total
        let zone2 = result.first(where: { $0.name == "Zone 2" })!
        XCTAssertEqual(zone2.fraction, 1.0, accuracy: 0.01)
        XCTAssertEqual(zone2.seconds, 180, accuracy: 1)
    }

    func testMultipleZones() {
        let now = Date()
        let samples: [(value: Double, timestamp: Date)] = [
            (100, now),                          // Zone 1
            (140, now.addingTimeInterval(60)),    // Zone 3
            (160, now.addingTimeInterval(120)),   // Zone 4
        ]

        let result = HRZoneAnalysis.compute(hrValues: samples, zones: zones)

        XCTAssertGreaterThan(result.first(where: { $0.name == "Zone 1" })!.seconds, 0)
        XCTAssertGreaterThan(result.first(where: { $0.name == "Zone 3" })!.seconds, 0)
        XCTAssertGreaterThan(result.first(where: { $0.name == "Zone 4" })!.seconds, 0)
    }

    func testEmptySamples() {
        let result = HRZoneAnalysis.compute(hrValues: [], zones: zones)
        XCTAssertTrue(result.allSatisfy { $0.seconds == 0 })
        XCTAssertTrue(result.allSatisfy { $0.fraction == 0 })
    }

    func testSingleSample() {
        let result = HRZoneAnalysis.compute(
            hrValues: [(value: 120, timestamp: Date())],
            zones: zones
        )
        // Single sample has 0 duration
        XCTAssertTrue(result.allSatisfy { $0.seconds == 0 })
    }

    func testFractionsSum() {
        let now = Date()
        let samples: [(value: Double, timestamp: Date)] = (0..<10).map { i in
            (value: Double(100 + i * 10), timestamp: now.addingTimeInterval(Double(i) * 30))
        }

        let result = HRZoneAnalysis.compute(hrValues: samples, zones: zones)
        let totalFraction = result.reduce(0) { $0 + $1.fraction }

        // Fractions of zones that had samples should sum to ~1.0
        // (some HR values may fall outside all zones)
        XCTAssertLessThanOrEqual(totalFraction, 1.01)
    }
}

final class HabitStreakTests: XCTestCase {

    private func makeDailyHabit() -> Habit {
        Habit(id: UUID(), name: "Test", icon: "star", color: "blue",
              scheduleType: .daily, scheduleParam: 0, category: .general,
              createdAt: Date().addingTimeInterval(-86400 * 30), sortOrder: 0)
    }

    func testEmptyDates() {
        let result = HabitStreak.longestStreak(habit: makeDailyHabit(), completedDates: [])
        XCTAssertEqual(result, 0)
    }

    func testConsecutiveDailyStreak() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let dates: Set<Date> = Set((0..<7).compactMap { cal.date(byAdding: .day, value: -$0, to: today) })

        let result = HabitStreak.longestStreak(habit: makeDailyHabit(), completedDates: dates)
        XCTAssertEqual(result, 7)
    }

    func testBrokenStreak() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        // Days: today, -1, -2, (skip -3), -4, -5
        var dates: Set<Date> = []
        for d in [0, 1, 2, 4, 5] {
            if let date = cal.date(byAdding: .day, value: -d, to: today) {
                dates.insert(date)
            }
        }

        let result = HabitStreak.longestStreak(habit: makeDailyHabit(), completedDates: dates)
        XCTAssertEqual(result, 3) // today, -1, -2
    }
}

final class RecoveryScoreTests: XCTestCase {

    func testBuildBaseline() {
        let days: [RecoveryScore.DayInputs] = (0..<10).map { i in
            RecoveryScore.DayInputs(
                date: Date().addingTimeInterval(Double(-i) * 86400),
                sdnnSamples: [(value: 40 + Double(i), sourceName: "Watch")],
                restingHR: 60 - Double(i) * 0.5,
                restingHRSource: "Watch"
            )
        }

        let baseline = RecoveryScore.buildBaseline(from: days)

        XCTAssertGreaterThan(baseline.meanSDNN, 0)
        XCTAssertGreaterThan(baseline.meanRestingHR, 0)
        XCTAssertEqual(baseline.dayCount, 10)
        XCTAssertFalse(baseline.isLowConfidence)
    }

    func testLowConfidenceBaseline() {
        let days: [RecoveryScore.DayInputs] = (0..<3).map { i in
            RecoveryScore.DayInputs(
                date: Date().addingTimeInterval(Double(-i) * 86400),
                sdnnSamples: [(value: 45, sourceName: "Watch")],
                restingHR: 58,
                restingHRSource: "Watch"
            )
        }

        let baseline = RecoveryScore.buildBaseline(from: days)
        XCTAssertTrue(baseline.isLowConfidence)
    }

    func testEmptyBaseline() {
        let baseline = RecoveryScore.buildBaseline(from: [])
        XCTAssertEqual(baseline.meanSDNN, 0)
        XCTAssertEqual(baseline.dayCount, 0)
    }

    func testStandardDeviationCalculation() {
        // Baseline with varying values should have non-zero SD
        let days: [RecoveryScore.DayInputs] = [
            .init(date: Date(), sdnnSamples: [(value: 30, sourceName: "W")], restingHR: 65, restingHRSource: "W"),
            .init(date: Date().addingTimeInterval(-86400), sdnnSamples: [(value: 50, sourceName: "W")], restingHR: 55, restingHRSource: "W"),
            .init(date: Date().addingTimeInterval(-172800), sdnnSamples: [(value: 40, sourceName: "W")], restingHR: 60, restingHRSource: "W"),
        ]

        let baseline = RecoveryScore.buildBaseline(from: days)
        XCTAssertGreaterThan(baseline.sdSDNN, 0)
        XCTAssertGreaterThan(baseline.sdRestingHR, 0)
    }
}
