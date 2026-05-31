import Foundation
import CoreBluetooth
import Combine

// ===================== Data Types =====================

struct IMUPacket {
    let timestamp: UInt32
    let ax, ay, az: Int16
    let gx, gy, gz: Int16

    static let accelScale: Float = 2.0 / 32768.0
    static let gyroScale: Float = 245.0 / 32768.0

    var accelG: (x: Float, y: Float, z: Float) {
        (Float(ax) * Self.accelScale, Float(ay) * Self.accelScale, Float(az) * Self.accelScale)
    }
    var gyroDPS: (x: Float, y: Float, z: Float) {
        (Float(gx) * Self.gyroScale, Float(gy) * Self.gyroScale, Float(gz) * Self.gyroScale)
    }
    var accelMagnitude: Float {
        let a = accelG
        return sqrtf(a.x*a.x + a.y*a.y + a.z*a.z)
    }
    var gyroMagnitude: Float {
        let g = gyroDPS
        return sqrtf(g.x*g.x + g.y*g.y + g.z*g.z)
    }
}

// What the firmware reports
enum DeviceState: UInt8 {
    case idle = 0, recording = 1, hasData = 2, downloading = 3
}

struct DeviceStatus {
    var state: DeviceState = .idle
    var sampleCount: UInt32 = 0
    var sampleRateHz: UInt8 = 25
    var batteryPercent: UInt8 = 0
    var isCharging: Bool = false
    var maxSamples: UInt32 = 0
    var recordingDurationSec: UInt32 = 0

    var durationString: String {
        let m = recordingDurationSec / 60
        let s = recordingDurationSec % 60
        return String(format: "%d:%02d", m, s)
    }
    var maxDurationAtRate: String {
        guard sampleRateHz > 0, maxSamples > 0 else { return "--" }
        let sec = maxSamples / UInt32(sampleRateHz)
        let h = sec / 3600; let m = (sec % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

// App's own state — single source of truth for UI
enum AppState: Equatable {
    case disconnected
    case idle
    case recording
    case stopping       // sent stop, waiting for hasData
    case downloading    // syncing data from device
    case error(String)

    static func == (lhs: AppState, rhs: AppState) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected),
             (.idle, .idle),
             (.recording, .recording),
             (.stopping, .stopping),
             (.downloading, .downloading): return true
        case (.error(let a), .error(let b)): return a == b
        default: return false
        }
    }
}

// ===================== BLE Manager =====================

class BLEManager: NSObject, ObservableObject {
    // UUIDs
    private let imuServiceUUID   = CBUUID(string: "12345678-1234-5678-1234-56789abcdef0")
    private let imuCharUUID      = CBUUID(string: "12345678-1234-5678-1234-56789abcdef1")
    private let controlCharUUID  = CBUUID(string: "12345678-1234-5678-1234-56789abcdef2")
    private let statusCharUUID   = CBUUID(string: "12345678-1234-5678-1234-56789abcdef3")
    private let downloadCharUUID = CBUUID(string: "12345678-1234-5678-1234-56789abcdef4")
    private let configCharUUID   = CBUUID(string: "12345678-1234-5678-1234-56789abcdef5")
    private let battServiceUUID  = CBUUID(string: "180F")
    private let battCharUUID     = CBUUID(string: "2A19")

    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var controlChar: CBCharacteristic?
    private var statusChar: CBCharacteristic?
    private var downloadChar: CBCharacteristic?
    private var configChar: CBCharacteristic?

    // Published state
    @Published var connected = false
    @Published var deviceStatus = DeviceStatus()
    @Published var appState: AppState = .disconnected
    @Published var downloadProgress: Float = 0

    // Callbacks
    var onPacket: ((IMUPacket) -> Void)?
    var onBattery: ((Int) -> Void)?
    var onDownloadComplete: (([RecordedSample], DeviceStatus) -> Void)?

    // Download state (private)
    private var downloadedSamples: [RecordedSample] = []
    private var expectedDownloadCount: UInt32 = 0
    private var downloadTimeoutTimer: Timer?
    private var firstStatusReceived = false

    // Persisted state
    private let wasRecordingKey = "runalyzer_wasRecording"

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Public Commands

    func startScanning() {
        guard centralManager.state == .poweredOn else { return }
        centralManager.scanForPeripherals(withServices: [imuServiceUUID], options: nil)
    }

    func disconnect() {
        if let p = peripheral { centralManager.cancelPeripheralConnection(p) }
    }

    func startRecording() {
        guard appState == .idle else { return }
        appState = .recording
        UserDefaults.standard.set(true, forKey: wasRecordingKey)
        sendCommand(1)
    }

    func stopRecording() {
        guard appState == .recording else { return }
        appState = .stopping
        UserDefaults.standard.set(false, forKey: wasRecordingKey)
        sendCommand(2)
    }

    func eraseData() {
        sendCommand(3)
    }

    func setSampleRate(_ hz: UInt8) {
        guard let char = configChar, let p = peripheral else { return }
        p.writeValue(Data([hz]), for: char, type: .withResponse)
    }

    // MARK: - Private

    private func sendCommand(_ cmd: UInt8) {
        guard let char = controlChar, let p = peripheral else { return }
        p.writeValue(Data([cmd]), for: char, type: .withResponse)
    }

    private func startDownload() {
        downloadedSamples.removeAll()
        expectedDownloadCount = deviceStatus.sampleCount
        downloadProgress = 0
        appState = .downloading
        print("Starting download: \(expectedDownloadCount) samples")
        sendCommand(4) // firmware sends first chunk immediately
        resetDownloadTimeout()
    }

    private func requestNextChunk() {
        sendCommand(5)
        resetDownloadTimeout()
    }

    private func resetDownloadTimeout() {
        downloadTimeoutTimer?.invalidate()
        downloadTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            guard let self, self.appState == .downloading else { return }
            print("Download timeout")
            self.downloadedSamples.removeAll()
            self.appState = .idle
        }
    }

    // MARK: - Status Parsing

    private func parseStatus(_ data: Data) {
        guard data.count >= 16 else { return }
        data.withUnsafeBytes { buf in
            deviceStatus.state = DeviceState(rawValue: buf.loadUnaligned(fromByteOffset: 0, as: UInt8.self)) ?? .idle
            deviceStatus.sampleCount = buf.loadUnaligned(fromByteOffset: 1, as: UInt32.self)
            deviceStatus.sampleRateHz = buf.loadUnaligned(fromByteOffset: 5, as: UInt8.self)
            deviceStatus.batteryPercent = buf.loadUnaligned(fromByteOffset: 6, as: UInt8.self)
            deviceStatus.isCharging = buf.loadUnaligned(fromByteOffset: 7, as: UInt8.self) == 1
            deviceStatus.maxSamples = buf.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
            deviceStatus.recordingDurationSec = buf.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
        }
        onBattery?(Int(deviceStatus.batteryPercent))

        // First status after connect — reconcile app state with device
        if !firstStatusReceived {
            firstStatusReceived = true
            reconcileState()
        }

        // Auto-download: only on first transition to hasData from stopping
        // Don't keep retrying — user can manually retry from Settings
        if deviceStatus.state == .hasData && deviceStatus.sampleCount > 0 && appState == .stopping {
            startDownload()
        }

        // Device erased successfully — go back to idle
        if deviceStatus.state == .idle && (appState == .downloading || appState == .error("Download timed out")) {
            appState = .idle
        }
    }

    private func reconcileState() {
        let wasRecording = UserDefaults.standard.bool(forKey: wasRecordingKey)
        print("Reconcile: device=\(deviceStatus.state) wasRecording=\(wasRecording) appState=\(appState)")

        switch deviceStatus.state {
        case .recording:
            appState = .recording
            UserDefaults.standard.set(true, forKey: wasRecordingKey)
        case .hasData:
            UserDefaults.standard.set(false, forKey: wasRecordingKey)
            // Auto-download on reconnect (device has unsynced data)
            if appState != .downloading {
                startDownload()
            }
        case .idle:
            UserDefaults.standard.set(false, forKey: wasRecordingKey)
            appState = .idle
        case .downloading:
            // Shouldn't happen on fresh connect, treat as hasData
            appState = .downloading
        }
    }

    // MARK: - Download Parsing

    private func parseDownloadChunk(_ data: Data) {
        // End marker: 4 bytes all 0xFF
        if data.count == 4 && data.allSatisfy({ $0 == 0xFF }) {
            downloadTimeoutTimer?.invalidate()
            downloadTimeoutTimer = nil
            downloadProgress = 1.0

            let samples = downloadedSamples
            let status = deviceStatus
            print("Download complete: \(samples.count) samples received")

            appState = .idle
            onDownloadComplete?(samples, status)
            downloadedSamples.removeAll()
            return
        }

        guard data.count >= 20 else { return } // at least 4 byte header + 1 sample

        // Parse: [4 bytes offset] + [N * 16 bytes samples]
        let sampleBytes = data.count - 4
        let numSamples = sampleBytes / 16
        guard numSamples > 0 else { return }

        // Validate offset matches expected position
        let reportedOffset = data.withUnsafeBytes { buf in
            buf.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
        }
        let expectedOffset = UInt32(downloadedSamples.count)
        if reportedOffset != expectedOffset {
            print("WARNING: offset mismatch — expected \(expectedOffset), got \(reportedOffset)")
        }

        data.withUnsafeBytes { buf in
            for i in 0..<numSamples {
                let off = 4 + (i * 16)
                guard off + 16 <= data.count else { break }
                downloadedSamples.append(RecordedSample(
                    timestamp: buf.loadUnaligned(fromByteOffset: off, as: UInt32.self),
                    ax: buf.loadUnaligned(fromByteOffset: off + 4, as: Int16.self),
                    ay: buf.loadUnaligned(fromByteOffset: off + 6, as: Int16.self),
                    az: buf.loadUnaligned(fromByteOffset: off + 8, as: Int16.self),
                    gx: buf.loadUnaligned(fromByteOffset: off + 10, as: Int16.self),
                    gy: buf.loadUnaligned(fromByteOffset: off + 12, as: Int16.self),
                    gz: buf.loadUnaligned(fromByteOffset: off + 14, as: Int16.self)
                ))
            }
        }

        if expectedDownloadCount > 0 {
            downloadProgress = Float(downloadedSamples.count) / Float(expectedDownloadCount)
        }

        // Request next chunk
        requestNextChunk()
    }

    // MARK: - IMU Packet Parsing

    private func parseIMUPacket(_ data: Data) -> IMUPacket? {
        guard data.count >= 16 else { return nil }
        return data.withUnsafeBytes { buf in
            IMUPacket(
                timestamp: buf.loadUnaligned(fromByteOffset: 0, as: UInt32.self),
                ax: buf.loadUnaligned(fromByteOffset: 4, as: Int16.self),
                ay: buf.loadUnaligned(fromByteOffset: 6, as: Int16.self),
                az: buf.loadUnaligned(fromByteOffset: 8, as: Int16.self),
                gx: buf.loadUnaligned(fromByteOffset: 10, as: Int16.self),
                gy: buf.loadUnaligned(fromByteOffset: 12, as: Int16.self),
                gz: buf.loadUnaligned(fromByteOffset: 14, as: Int16.self)
            )
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { startScanning() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        self.peripheral = peripheral
        central.stopScan()
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connected = true
        firstStatusReceived = false
        peripheral.delegate = self
        peripheral.discoverServices([imuServiceUUID, battServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connected = false
        controlChar = nil; statusChar = nil; downloadChar = nil; configChar = nil
        downloadTimeoutTimer?.invalidate()

        let previousState = appState

        // Clean up download if in progress
        if previousState == .downloading {
            downloadedSamples.removeAll()
            downloadProgress = 0
        }

        // Don't reset appState if recording — device continues independently
        if previousState != .recording {
            appState = .disconnected
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.startScanning()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for char in service.characteristics ?? [] {
            switch char.uuid {
            case imuCharUUID:
                peripheral.setNotifyValue(true, for: char)
            case controlCharUUID:
                controlChar = char
            case statusCharUUID:
                statusChar = char
                peripheral.setNotifyValue(true, for: char)
                peripheral.readValue(for: char)
            case downloadCharUUID:
                downloadChar = char
                peripheral.setNotifyValue(true, for: char)
            case configCharUUID:
                configChar = char
                peripheral.readValue(for: char)
            case battCharUUID:
                peripheral.readValue(for: char)
            default: break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch characteristic.uuid {
            case imuCharUUID:
                if let pkt = parseIMUPacket(data) { onPacket?(pkt) }
            case statusCharUUID:
                parseStatus(data)
            case downloadCharUUID:
                parseDownloadChunk(data)
            case configCharUUID:
                if let hz = data.first { deviceStatus.sampleRateHz = hz }
            case battCharUUID:
                if let pct = data.first { onBattery?(Int(pct)) }
            default: break
            }
        }
    }
}
