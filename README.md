# Runalyzer

A personal health device hub that connects to BLE sensors, imports HealthKit data, and tracks health habits. Currently supports:

- **IMU Gait Sensor** — 6-axis motion data for running analysis (cadence, impact, left/right asymmetry)
- **QN Body Fat Scale** — weight + bioimpedance for body composition (fat %, muscle mass, BMI, BMR)
- **HealthKit Integration** — heart rate, HRV, resting HR, steps, sleep stages, workouts
- **Recovery Score** — daily readiness computed from overnight HRV and resting heart rate
- **Health Habits** — recurring habits with flexible schedules, auto-fulfillment from workouts, and streak tracking

The app is designed for multiple device types — adding new BLE sensors requires only a driver + descriptor, no changes to existing code.

## Supported Devices

### IMU Gait Sensor (Seeed XIAO nRF52840 Sense)

- **Seeed XIAO nRF52840 Sense** — the main board (nRF52840 SoC, BLE, 2MB QSPI flash)
- **LSM6DS3TR-C** — onboard 6-axis IMU (accelerometer ±2g, gyroscope ±245 dps)
- **LiPo battery** — any 3.7V LiPo with JST connector (100-400mAh recommended)
- **BQ25100** — onboard charge controller (charges via USB-C)

No extra wiring or soldering needed. Everything is on the XIAO Sense board.

### QN Body Fat Scale

Any QN-protocol BLE scale (sold under Renpho, Etekcity, and other brands). The app connects via the FFF0 service, runs the vendor handshake, and reads weight + bioimpedance. Body composition is calculated using published BIA equations (Sun et al., Janssen et al., Mifflin-St Jeor).

## Architecture

```
BLE Drivers (protocol only — no business logic)
├── IMUSensorDriver    → emits raw IMU samples
└── QNScaleDriver      → emits raw weight + impedance

Providers (own the full pipeline: trigger → data → algorithm → save)
├── ScaleMeasurementProvider   → profile + BodyComposition algorithm → DB
├── IMUMeasurementProvider     → RunMetrics.analyzeRecording() → DB
├── HealthKitMetricProvider    → imports from HealthKit → DB
├── RecoveryMeasurementProvider → RecoveryScore.compute() → DB
├── UserProfileProvider        → HealthKit auto-fill + DB persistence
└── HabitProvider              → auto-fulfillment from workouts + streak stats

Algorithms (pure computation, no state, no I/O)
├── BodyComposition     → BIA body comp equations
├── RecoveryScore       → HRV/RHR recovery scoring
├── RunMetrics          → IMU step detection + gait analysis
└── HabitStreak         → streak + compliance computation

Stores (dumb CRUD, GRDB ValueObservation for reactive updates)
├── MeasurementStore    → metrics, body comp, derived scores
├── WorkoutStore        → HealthKit + IMU workouts
└── HabitStore          → habits + daily logs

Database: GRDB/SQLCipher (encrypted SQLite)
├── Encryption key stored in Keychain
├── Tables: measurement, data_point, workout, workout_data_point,
│           measurement_source, user_profile, habit, habit_log
└── Export/import via sqlcipher_export
```

Adding a new device type requires only:
1. Create a `DeviceDriver` conforming class
2. Create a `DeviceDescriptor`
3. Register it in `DeviceCoordinator.registeredDevices`
4. Create a provider that handles the driver's events

## How it works

### IMU Gait Sensor

1. Start a recording from the iOS app (or the sensor records independently if disconnected)
2. All IMU samples are stored to the onboard 2MB flash at a configurable rate (10-100 Hz, default 25 Hz)
3. At 25 Hz, the flash holds about 2 hours of continuous recording
4. When the phone reconnects after a run, the data syncs automatically over BLE
5. The app analyzes the recording: step detection, cadence, impact per step, left/right foot classification

### Body Fat Scale

1. Step on the scale — the app detects the BLE advertisement and connects automatically
2. A measurement overlay appears on screen showing live weight and progress
3. When the reading stabilizes, the provider fetches your profile, runs body composition algorithms, and saves to the database
4. The overlay shows a checkmark, then navigates to the Data tab where the measurement appears

### Health Habits

- Define recurring habits with flexible schedules: daily, every N days, X times per week, or specific weekdays
- Link habits to workout activity types for auto-fulfillment (e.g., "Run 3x/week" auto-checks when a Run workout is recorded)
- Manual habits for things that can't be auto-detected (supplements, meditation, stretching)
- Streak tracking and weekly/monthly compliance bars on the dashboard

## LED indicators

| LED | Meaning |
|-----|---------|
| Blue blinking | Advertising / idle |
| Solid green | Phone connected |
| Red blinking | Recording |
| Solid red 2s → off | Low battery shutdown |

## Repo structure

```
firmware/       Arduino sketch for the XIAO nRF52840 Sense
ios/            iOS app (SwiftUI, requires Xcode 15+)
```

## Firmware setup

### Requirements

- Arduino IDE
- Board package: **Seeed nRF52 mbed-enabled Boards** (add `https://files.seeedstudio.com/arduino/package_seeeduino_boards_index.json` to Board Manager URLs)
- Board: **Seeed XIAO nRF52840 Sense**
- Library: **ArduinoBLE** (install via Library Manager)

### Upload

1. Open `firmware/runalyzer.ino` in Arduino IDE
2. Select board and port
3. Upload (if port not found, double-tap the reset button to enter bootloader)

## iOS app setup

### Requirements

- Xcode 15+
- iPhone running iOS 17+
- Apple ID (free account works)

### Build & run

1. Open `ios/Runalyzer.xcodeproj`
2. Select your development team in Signing & Capabilities
3. Add capabilities: **HealthKit**, **Background Modes** (Uses Bluetooth LE accessories)
4. Connect your iPhone and hit Run

### Dependencies

- [GRDB.swift (SQLCipher fork)](https://github.com/sqlcipher/GRDB.swift) — encrypted SQLite database via SPM

### Permissions needed

- Bluetooth — to communicate with BLE sensors
- Health — to read heart rate, HRV, steps, sleep, workouts, height, and biological sex

## Security

The database is encrypted at rest using SQLCipher (AES-256). The encryption key is a randomly generated 256-bit key stored in the iOS Keychain. User profile data (height, age, sex) is stored in the encrypted database, not in UserDefaults or plaintext files.

## BLE protocol

The IMU sensor exposes one GATT service with these characteristics:

Service UUID: `264f9cc7-8f8a-4aad-878a-d3615d12dccc`

| UUID (last 4) | Name | Properties | Description |
|----------------|------|------------|-------------|
| `dcc1` | IMU Stream | Read, Notify | Live 16-byte packets: `[u32 timestamp, i16 ax,ay,az,gx,gy,gz]` |
| `dcc2` | Control | Write | Commands: 1=start, 2=stop, 3=erase, 4=begin download, 5=next chunk |
| `dcc3` | Status | Read, Notify | 28-byte device status (state, samples, rate, battery, capacity, duration, start time) |
| `dcc4` | Download | Read, Notify | Data chunks: `[u32 offset, N×12B samples]`, end marker: `[0xFF×4]` |
| `dcc5` | Config | Read, Write | Sample rate in Hz (10-100) |
| `dcc6` | Time Sync | Write | 8-byte Unix timestamp (ms) — synced from phone on connect |

Download uses a request-response protocol (command 5 requests each chunk) for reliable transfer. Samples stored on flash are 12 bytes each (6 axes, no timestamp). Timestamps are reconstructed from the sample index and recording rate during download.

## Recording capacity

| Sample rate | Max duration |
|-------------|-------------|
| 25 Hz | ~2.8 hours |
| 50 Hz | ~1.4 hours |
| 100 Hz | ~42 minutes |

## Data safety

The firmware protects recordings against data loss in several ways:

- **Periodic flush**: The RAM write buffer is flushed to flash every 10 seconds. If the battery dies unexpectedly, at most 10 seconds of data is lost.
- **Low battery shutdown**: At 10% battery, the firmware gracefully stops recording, flushes all buffered data, writes the session header, and enters deep sleep. Data is preserved and will sync on next power-up.
- **Memory full auto-stop**: At 95% flash capacity, recording stops automatically to avoid running out of space mid-write.
- **Power-loss recovery**: If power is lost during recording, the `isRecording` flag in the flash header persists. On reboot, the firmware resumes accepting that the session ended at the last flush point. The data up to that point is available for download.
