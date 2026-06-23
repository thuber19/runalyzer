# Project: Runalyzer

iOS + firmware app for health tracking. Connects BLE sensors (IMU gait sensor, body fat scale), imports HealthKit data, computes recovery scores, and tracks health habits.

## Quick Reference
- **iOS 17+ / SwiftUI / Swift 5.9+** — Xcode project at `ios/Runalyzer.xcodeproj`
- **Database**: GRDB.swift 7.x with SQLCipher encryption (`sqlcipher/GRDB.swift` fork)
- **Firmware**: Arduino sketch at `firmware/runalyzer/runalyzer.ino`
- **Concurrency model**: Combine-based (`@StateObject` + `ObservableObject` + `@Published`) — do NOT migrate to `@Observable`
- **DI**: `@EnvironmentObject` throughout the view hierarchy

## Key Directories
- `ios/Runalyzer/Providers/` — self-contained pipelines (trigger → data → algorithm → save)
- `ios/Runalyzer/Algorithms/` — pure computation (BodyComposition, RecoveryScore, RunMetrics, HabitStreak)
- `ios/Runalyzer/Storage/` — GRDB persistence layer (dumb CRUD stores + data models)
- `ios/Runalyzer/BLE/` — device coordinator, driver protocol, registry
- `ios/Runalyzer/Devices/` — per-device BLE drivers (IMU, Scale) — protocol only, no business logic
- `ios/Runalyzer/Services/` — MetricIndex (SQL queries), MetricAggregator

## Architecture

### Provider Pattern (core rule)
Providers own the full pipeline: **trigger → data → algorithm → save**.
- Stores (`MeasurementStore`, `WorkoutStore`, `HabitStore`) are **dumb persistence** — CRUD only.
- Drivers are **BLE-only** — they emit raw data, never fetch profiles or call algorithms.
- Algorithms are **pure computation** — no state, no I/O, no DB access.
- Providers call stores and algorithms; stores/drivers/algorithms never call providers.

### AppWiring
`AppWiring` (in `RunalyzerApp.swift`) wires BLE driver callbacks to providers via Combine. Also triggers auto-fulfillment and recovery computation on app foreground.

### Data Flow
1. **BLE devices** → `DeviceCoordinator` → `AppWiring` → providers
2. **HealthKit** → `HealthKitMetricProvider` → `RecoveryMeasurementProvider`
3. **Habits** → `HabitProvider` checks workouts for auto-fulfillment
4. **Providers** → stores (GRDB)
5. **Views** read from stores via `@EnvironmentObject`

### Database (encrypted GRDB/SQLCipher)
- Encryption key in Keychain, passed via `usePassphrase()` on every DB open
- Tables: `measurement`, `data_point`, `measurement_source`, `workout`, `workout_data_point`, `user_profile`, `habit`, `habit_log`
- `MetricIndex` provides read-only SQL queries over measurements

### Scale Measurement Flow
Scale driver emits raw `ScaleReading` (weight + impedance) → `ScaleMeasurementProvider` fetches profile from `UserProfileProvider` → calls `BodyComposition.calculate()` → saves to `MeasurementStore`. A measurement overlay in `ContentView` shows progress and navigates to Data tab on completion.

## DO NOT
- Put business logic in stores (they are dumb CRUD)
- Put profile lookups, algorithms, or DB access in BLE drivers
- Migrate to `@Observable` — the codebase uses Combine (`@StateObject`/`@Published`)
- Use force unwrapping (`!`) without justification
- Use `print()` for error logging — use `AppLogger`

## New Feature Checklist
1. Check `TODO.md` for backlog context
2. Identify which provider(s) and store(s) are involved
3. Follow the provider pattern: trigger → data → algorithm → save
4. Keep stores thin, drivers dumb, algorithms pure
5. Add new tables via `DatabaseMigrator` versioned migrations in `AppDatabase.swift`
