import SwiftUI
import Combine
import UserNotifications
import GRDB
import os

@main
struct RunalyzerApp: App {
    @StateObject private var coordinator = DeviceCoordinator()
    @StateObject private var metrics = RunMetrics()
    @StateObject private var store: MeasurementStore
    @StateObject private var workoutStore: WorkoutStore
    @StateObject private var healthKit = HealthKitManager()
    @StateObject private var appWiring = AppWiring()
    @StateObject private var sourcePrefs = SourcePreferenceStore()
    @StateObject private var profileProvider: UserProfileProvider
    @StateObject private var habitStore: HabitStore
    @StateObject private var drinkTemplateStore: DrinkTemplateStore
    @StateObject private var fluidIntakeProvider: FluidIntakeProvider
    @StateObject private var checkInProvider: CheckInProvider
    @StateObject private var watchConnectivity = WatchConnectivityManager()
    @StateObject private var saunaSyncProvider: SaunaSyncProvider

    @State private var databaseFailed = false

    init() {
        // Initialize database before stores
        do {
            AppDatabase.shared = try AppDatabase.openDefault()
        } catch {
            // Fall back to in-memory database so the app can still launch
            AppLogger.storage.error("Failed to open database: \(error.localizedDescription). Falling back to in-memory DB.")
            AppDatabase.shared = (try? AppDatabase.inMemory()) ?? AppDatabase.shared
            _databaseFailed = State(initialValue: true)
        }
        let measurementStore = MeasurementStore()
        _store = StateObject(wrappedValue: measurementStore)
        _workoutStore = StateObject(wrappedValue: WorkoutStore())
        _profileProvider = StateObject(wrappedValue: UserProfileProvider())
        _habitStore = StateObject(wrappedValue: HabitStore())
        _drinkTemplateStore = StateObject(wrappedValue: DrinkTemplateStore())
        _fluidIntakeProvider = StateObject(wrappedValue: FluidIntakeProvider(measurementStore: measurementStore))
        _checkInProvider = StateObject(wrappedValue: CheckInProvider(measurementStore: measurementStore))
        _saunaSyncProvider = StateObject(wrappedValue: SaunaSyncProvider(measurementStore: measurementStore))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(coordinator)
                .environmentObject(metrics)
                .environmentObject(store)
                .environmentObject(healthKit)
                .environmentObject(appWiring)
                .environmentObject(sourcePrefs)
                .environmentObject(workoutStore)
                .environmentObject(profileProvider)
                .environmentObject(habitStore)
                .environmentObject(drinkTemplateStore)
                .environmentObject(fluidIntakeProvider)
                .environmentObject(checkInProvider)
                .onAppear {
                    healthKit.requestAuthorization()
                    profileProvider.autoFillFromHealthKit()
                    appWiring.setup(coordinator: coordinator, metrics: metrics,
                                   store: store, workoutStore: workoutStore,
                                   healthKit: healthKit, profileProvider: profileProvider,
                                   habitStore: habitStore)
                    checkInProvider.scheduleNotifications()
                    store.cleanOrphanedRawFiles(workoutStore: workoutStore)
                    watchConnectivity.configure(saunaSyncProvider: saunaSyncProvider)
                    watchConnectivity.activate()
                }
                .alert("Database Error", isPresented: $databaseFailed) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("The database could not be opened. Running with a temporary in-memory database — your data will not be saved until the issue is resolved. Try restarting the app.")
                }
        }
    }
}

/// Manages Combine subscriptions, driver callback wiring, and measurement providers.
/// Adding a new device type requires only a new entry in `handlers` + a new provider.
class AppWiring: ObservableObject {
    private var cancellables = Set<AnyCancellable>()
    private var wiredDriverIDs = Set<UUID>()
    private var driverCancellables: [UUID: AnyCancellable] = [:]

    // Measurement providers — self-contained pipelines
    private(set) var scaleProvider: ScaleMeasurementProvider?
    private var imuProvider: IMUMeasurementProvider?
    private(set) var recoveryProvider: RecoveryMeasurementProvider?
    private(set) var sleepProvider: SleepMeasurementProvider?
    private(set) var metricProvider: HealthKitMetricProvider?
    private(set) var habitProvider: HabitProvider?

    private var profileProvider: UserProfileProvider?
    private var refreshDebounceItem: DispatchWorkItem?

    func setup(coordinator: DeviceCoordinator, metrics: RunMetrics,
               store: MeasurementStore, workoutStore: WorkoutStore,
               healthKit: HealthKitManager, profileProvider: UserProfileProvider,
               habitStore: HabitStore) {
        self.profileProvider = profileProvider

        // Clear previous subscriptions (prevents duplicates if setup called multiple times)
        cancellables.removeAll()
        wiredDriverIDs.removeAll()
        driverCancellables.removeAll()

        // Create MetricIndex (read-only query layer over store)
        let metricIndex = MetricIndex(store: store)

        // Create providers
        let profile = profileProvider
        scaleProvider = ScaleMeasurementProvider(measurementStore: store, profileProvider: profile)
        imuProvider = IMUMeasurementProvider(workoutStore: workoutStore)
        metricProvider = HealthKitMetricProvider(healthKit: healthKit, store: store,
                                                workoutStore: workoutStore, metricIndex: metricIndex)
        recoveryProvider = RecoveryMeasurementProvider(metricIndex: metricIndex, measurementStore: store)
        sleepProvider = SleepMeasurementProvider(metricIndex: metricIndex, measurementStore: store)
        habitProvider = HabitProvider(habitStore: habitStore, workoutStore: workoutStore)

        // Per-descriptor handlers — keyed by DeviceDescriptor.id.
        // To add a new device: add one entry here + create a provider.
        let handlers: [String: (any DeviceDriver) -> AnyCancellable?] = [
            "imu_sensor": Self.imuHandler(metrics: metrics, imuProvider: imuProvider),
            "qn_scale":   Self.scaleHandler(scaleProvider: scaleProvider)
        ]

        // L4: Update app icon badge when IMU has unsynced data
        coordinator.$imuDriver
            .flatMap { driver -> AnyPublisher<Bool, Never> in
                guard let imu = driver else {
                    return Just(false).eraseToAnyPublisher()
                }
                return imu.$deviceStatus
                    .map { $0.state == .hasData && $0.sampleCount > 0 }
                    .eraseToAnyPublisher()
            }
            .receive(on: DispatchQueue.main)
            .sink { hasUnsynced in
                UNUserNotificationCenter.current().setBadgeCount(hasUnsynced ? 1 : 0)
            }
            .store(in: &cancellables)

        coordinator.$activeDrivers
            .sink { [weak self] drivers in
                guard let self else { return }
                let activeIDs = Set(drivers.keys)

                // Wire newly connected drivers
                for (id, driver) in drivers where !self.wiredDriverIDs.contains(id) {
                    self.wiredDriverIDs.insert(id)
                    if let handler = handlers[driver.descriptor.id],
                       let cancellable = handler(driver) {
                        self.driverCancellables[id] = cancellable
                    }
                }

                // Clean up disconnected drivers
                for id in self.wiredDriverIDs where !activeIDs.contains(id) {
                    self.wiredDriverIDs.remove(id)
                    self.driverCancellables.removeValue(forKey: id)
                }
            }
            .store(in: &cancellables)

        // Import metrics from HealthKit first, then compute stress scores
        refreshMetricsAndRecovery()

        // Register HKObserverQuery + background delivery for key types.
        // iOS wakes the app on new samples — triggers the same import pipeline.
        healthKit.enableBackgroundDelivery { [weak self] in
            self?.refreshMetricsAndRecovery()
        }

        // Re-run when app returns to foreground
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in self?.refreshMetricsAndRecovery() }
            .store(in: &cancellables)
    }

    /// Import latest metrics from HealthKit, then compute any missing stress scores.
    /// Debounced to avoid duplicate computations when multiple HealthKit observers
    /// or foreground events fire in quick succession.
    func refreshMetricsAndRecovery() {
        refreshDebounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.metricProvider?.importMissingMetrics { [weak self] in
                self?.recoveryProvider?.computeMissingScores()
                self?.sleepProvider?.computeMissingScores()
                self?.habitProvider?.processAutoFulfillment()
            }
        }
        refreshDebounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: item)
    }

    // MARK: - Wiring factories

    private static func imuHandler(metrics: RunMetrics, imuProvider: IMUMeasurementProvider?)
        -> (any DeviceDriver) -> AnyCancellable? {
        { [weak metrics, weak imuProvider] driver in
            guard let imu = driver as? IMUSensorDriver else { return nil }
            var cancellables = Set<AnyCancellable>()

            imu.packetPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak metrics] packet in
                    metrics?.process(packet)
                }
                .store(in: &cancellables)

            imu.downloadCompletePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak imuProvider, weak imu] result in
                    guard let imu else { return }
                    imuProvider?.handleDownloadComplete(
                        samples: result.samples,
                        sampleRateHz: Int(result.status.sampleRateHz),
                        durationSec: Double(result.status.recordingDurationSec),
                        startUnixMs: result.status.recordingStartUnixMs,
                        events: result.events.isEmpty ? nil : result.events,
                        driver: imu
                    )
                }
                .store(in: &cancellables)

            // Return a single cancellable that keeps both subscriptions alive
            return AnyCancellable { cancellables.removeAll() }
        }
    }


    private static func scaleHandler(scaleProvider: ScaleMeasurementProvider?) -> (any DeviceDriver) -> AnyCancellable? {
        { [weak scaleProvider] driver in
            guard let scale = driver as? QNScaleDriver else { return nil }
            return scale.events
                .receive(on: DispatchQueue.main)
                .sink { event in
                    if case .measurementReady(let m) = event,
                       let reading = m as? ScaleReading {
                        scaleProvider?.handleReading(reading, from: scale)
                    }
                }
        }
    }
}
