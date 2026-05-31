# Runalyzer

A wearable IMU sensor for running gait analysis. Records 6-axis motion data (accelerometer + gyroscope) at the hip/tailbone and analyzes cadence, impact force, vertical bounce, and left/right asymmetry.

The system has two parts: a small sensor board that clips to your waistband and records data to onboard flash, and an iOS app that syncs the recordings over Bluetooth and visualizes the results.

## Hardware

- **Seeed XIAO nRF52840 Sense** — the main board (nRF52840 SoC, BLE, 2MB QSPI flash)
- **LSM6DS3TR-C** — onboard 6-axis IMU (accelerometer ±2g, gyroscope ±245 dps)
- **LiPo battery** — any 3.7V LiPo with JST connector (100-400mAh recommended)
- **BQ25100** — onboard charge controller (charges via USB-C)

No extra wiring or soldering needed. Everything is on the XIAO Sense board.

## How it works

1. Start a recording from the iOS app (or the sensor records independently if disconnected)
2. All IMU samples are stored to the onboard 2MB flash at a configurable rate (10-100 Hz, default 25 Hz)
3. At 25 Hz, the flash holds about 2 hours of continuous recording
4. When the phone reconnects after a run, the data syncs automatically over BLE
5. The app analyzes the recording: step detection, cadence, impact per step, left/right foot classification
6. Optionally link an Apple Health workout to compare heart rate, distance, and Apple's step count with the sensor data

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
- iPhone running iOS 16+
- Apple ID (free account works)

### Build & run

1. Open `ios/Runalyzer.xcodeproj`
2. Select your development team in Signing & Capabilities
3. Add capabilities: **HealthKit**, **Background Modes** (Uses Bluetooth LE accessories)
4. Connect your iPhone and hit Run

### Permissions needed

- Bluetooth — to communicate with the sensor
- Health (optional) — to read workout data for comparison

## BLE protocol

The sensor exposes one GATT service with these characteristics:

| UUID suffix | Name | Properties | Description |
|-------------|------|------------|-------------|
| `def1` | IMU Stream | Read, Notify | Live 16-byte packets: `[u32 timestamp, i16 ax,ay,az,gx,gy,gz]` |
| `def2` | Control | Write | Commands: 1=start, 2=stop, 3=erase, 4=begin download, 5=next chunk |
| `def3` | Status | Read, Notify | 20-byte device status (state, samples, rate, battery, capacity, duration) |
| `def4` | Download | Read, Notify | Data chunks: `[u32 offset, N×12B samples]`, end marker: `[0xFF×4]` |
| `def5` | Config | Read, Write | Sample rate in Hz (10-100) |

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

## App state management

The app tracks two independent pieces of state:

- `connected` — whether BLE is physically connected right now (set by CoreBluetooth callbacks, always accurate)
- `appState` — what the user is doing: `.disconnected`, `.idle`, `.recording`, `.stopping`, `.downloading`, or `.error`

These are intentionally independent. The device can be recording while the phone is disconnected (`connected = false`, `appState = .recording`). When the phone reconnects, the app reads the device status and reconciles:

- Device reports `recording` → app shows Stop button
- Device reports `hasData` → app starts auto-download
- Device reports `idle` → app shows Start button

The app also monitors the device status continuously. If the device stops recording unexpectedly (battery died, memory full), the app detects the state change and starts downloading the saved data automatically.
