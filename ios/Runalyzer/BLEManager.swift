import Foundation
import CoreBluetooth
import Combine

// Uses types from IMUDataTypes.swift: IMUPacket, RecordedSample, etc.
// Uses types defined here: DeviceState, DeviceStatus, AppState (legacy, will be removed)

// Legacy type aliases — BLEManager still uses these names
typealias DeviceState = IMUDeviceState
typealias DeviceStatus = IMUDeviceStatus
typealias AppState = IMUAppState
typealias DeviceEvent = IMUDeviceEvent

// ===================== BLE Manager (Legacy — will be replaced by DeviceCoordinator) =====================

class BLEManager: NSObject, ObservableObject {
    // UUIDs
    private let imuServiceUUID   = CBUUID(string: "264f9cc7-8f8a-4aad-878a-d3615d12dccc")
    private let imuCharUUID      = CBUUID(string: "264f9cc7-8f8a-4aad-878a-d3615d12dcc1")
    private let controlCharUUID  = CBUUID(string: "264f9cc7-8f8a-4aad-878a-d3615d12dcc2")
    private let statusCharUUID   = CBUUID(string: "264f9cc7-8f8a-4aad-878a-d3615d12dcc3")
    private let downloadCharUUID = CBUUID(string: "264f9cc7-8f8a-4aad-878a-d3615d12dcc4")
    private let configCharUUID   = CBUUID(string: "264f9cc7-8f8a-4aad-878a-d3615d12dcc5")
    private let timesyncCharUUID = CBUUID(string: "264f9cc7-8f8a-4aad-878a-d3615d12dcc6")
    private let battServiceUUID  = CBUUID(string: "180F")
    private let battCharUUID     = CBUUID(string: "2A19")

    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var controlChar: CBCharacteristic?
    private var statusChar: CBCharacteristic?
    private var downloadChar: CBCharacteristic?
    private var configChar: CBCharacteristic?
    private var timesyncChar: CBCharacteristic?

    // Published state
    @Published var connected = false
    @Published var deviceStatus = DeviceStatus()
    @Published var appState: AppState = .disconnected
    @Published var downloadProgress: Float = 0

    // Callbacks
    var onPacket: ((IMUPacket) -> Void)?
    var onBattery: ((Int) -> Void)?
    var onDownloadComplete: (([RecordedSample], DeviceStatus, [DeviceEvent]) -> Void)?

    // Download state (private)
    private var downloadedSamples: [RecordedSample] = []
    private var downloadedEvents: [DeviceEvent] = []
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
        // Block if device has unsynced data that hasn't been downloaded yet
        if deviceStatus.state == .hasData && deviceStatus.sampleCount > 0 && appState != .downloading {
            print("Cannot start: device has unsynced data. Download first.")
            return
        }
        // Block if download is in progress
        if appState == .downloading {
            print("Cannot start: download in progress. Wait for sync to complete.")
            return
        }
        guard appState != .recording && appState != .stopping else { return }
        appState = .recording
        UserDefaults.standard.set(true, forKey: wasRecordingKey)
        sendCommand(1) // firmware erases old data and starts
    }

    func stopRecording() {
        guard appState == .recording else { return }
        appState = .stopping
        UserDefaults.standard.set(false, forKey: wasRecordingKey)
        sendCommand(2)

        // M7: timeout if device never transitions to hasData
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.appState == .stopping else { return }
            print("Stopping state timeout — forcing idle")
            self.appState = .idle
        }
    }

    func eraseData() {
        sendCommand(3)
    }

    func syncTime() {
        guard let char = timesyncChar, let p = peripheral else { return }
        let unixMs = UInt64(Date().timeIntervalSince1970 * 1000)
        var data = Data(count: 8)
        data.withUnsafeMutableBytes { buf in
            buf.storeBytes(of: unixMs, as: UInt64.self)
        }
        p.writeValue(data, for: char, type: .withResponse)
        print("Time synced: \(unixMs)")
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
        downloadedEvents.removeAll()
        downloadRetryCount = 0
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

    // H5: Increased timeout to 30s with retry
    private var downloadRetryCount = 0

    private func resetDownloadTimeout() {
        downloadTimeoutTimer?.invalidate()
        downloadTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { [weak self] _ in
            guard let self, self.appState == .downloading else { return }
            self.downloadRetryCount += 1
            if self.downloadRetryCount < 3 {
                print("Download timeout — retry \(self.downloadRetryCount)/3")
                self.requestNextChunk()
            } else {
                print("Download failed after 3 retries")
                self.downloadedSamples.removeAll()
                self.downloadedEvents.removeAll()
                self.downloadRetryCount = 0
                self.appState = .idle
            }
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
            let flags = buf.loadUnaligned(fromByteOffset: 7, as: UInt8.self)
            deviceStatus.isCharging = (flags & 0x01) != 0
            deviceStatus.isTimeSynced = (flags & 0x02) != 0
            deviceStatus.maxSamples = buf.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
            deviceStatus.recordingDurationSec = buf.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
            if data.count >= 24 {
                deviceStatus.recordingStartUnixMs = buf.loadUnaligned(fromByteOffset: 16, as: UInt64.self)
            }
            if data.count >= 26 {
                deviceStatus.protocolVersion = buf.loadUnaligned(fromByteOffset: 24, as: UInt8.self)
                deviceStatus.headerVersion = buf.loadUnaligned(fromByteOffset: 25, as: UInt8.self)
            }
        }
        onBattery?(Int(deviceStatus.batteryPercent))

        // First status after connect — full reconcile
        if !firstStatusReceived {
            firstStatusReceived = true

            // Check protocol compatibility
            if deviceStatus.protocolVersion > 0 && deviceStatus.protocolVersion != DeviceStatus.expectedProtocolVersion {
                print("WARNING: protocol version mismatch — device=\(deviceStatus.protocolVersion) app=\(DeviceStatus.expectedProtocolVersion)")
                appState = .error("Firmware update required (v\(deviceStatus.protocolVersion) vs v\(DeviceStatus.expectedProtocolVersion))")
                return
            }
            reconcileState()
            return
        }

        // Continuous state monitoring — catch device-side changes
        // Device stopped recording unexpectedly (battery, memory full)
        if appState == .recording && deviceStatus.state != .recording {
            UserDefaults.standard.set(false, forKey: wasRecordingKey)
            if deviceStatus.state == .hasData && deviceStatus.sampleCount > 0 {
                print("Device stopped recording — has data, starting download")
                startDownload()
            } else {
                appState = .idle
            }
        }

        // Auto-download after user stopped recording
        if deviceStatus.state == .hasData && deviceStatus.sampleCount > 0 && appState == .stopping {
            startDownload()
        }

        // Device erased — go back to idle
        if deviceStatus.state == .idle && appState != .recording {
            if appState == .downloading || appState == .stopping {
                appState = .idle
            }
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
            let events = downloadedEvents
            print("Download complete: \(samples.count) samples, \(events.count) events")

            appState = .idle
            onDownloadComplete?(samples, status, events)
            downloadedSamples.removeAll()
            downloadedEvents.removeAll()
            return
        }

        // Event log packet: marker = 0xFFFFFFFE
        if data.count >= 5 {
            let marker = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
            if marker == 0xFFFFFFFE {
                let count = Int(data[4])
                downloadedEvents.removeAll()
                for i in 0..<count {
                    let off = 5 + (i * 5)
                    guard off + 5 <= data.count else { break }
                    let reason = data[off]
                    let ts = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off + 1, as: UInt32.self) }
                    downloadedEvents.append(DeviceEvent(reason: reason, offsetMs: ts))
                }
                print("Received \(downloadedEvents.count) events")
                requestNextChunk()
                return
            }
        }

        guard data.count >= 16 else { return } // at least 4 byte header + 1 sample (12 bytes)

        // Parse: [4 bytes offset] + [N * 12 bytes samples (no timestamp)]
        let sampleBytes = data.count - 4
        let sampleSize = 12
        let numSamples = sampleBytes / sampleSize
        guard numSamples > 0 else { return }

        let reportedOffset = data.withUnsafeBytes { buf in
            buf.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
        }
        let expectedOffset = UInt32(downloadedSamples.count)
        if reportedOffset != expectedOffset {
            print("WARNING: offset mismatch — expected \(expectedOffset), got \(reportedOffset)")
        }

        // Reconstruct timestamps from sample index and rate
        let rate = max(1, UInt32(deviceStatus.sampleRateHz))
        let intervalMs = 1000 / rate

        data.withUnsafeBytes { buf in
            for i in 0..<numSamples {
                let off = 4 + (i * sampleSize)
                guard off + sampleSize <= data.count else { break }
                let sampleIndex = UInt32(downloadedSamples.count)
                let timestamp = sampleIndex * intervalMs  // derived timestamp
                downloadedSamples.append(RecordedSample(
                    timestamp: timestamp,
                    ax: buf.loadUnaligned(fromByteOffset: off, as: Int16.self),
                    ay: buf.loadUnaligned(fromByteOffset: off + 2, as: Int16.self),
                    az: buf.loadUnaligned(fromByteOffset: off + 4, as: Int16.self),
                    gx: buf.loadUnaligned(fromByteOffset: off + 6, as: Int16.self),
                    gy: buf.loadUnaligned(fromByteOffset: off + 8, as: Int16.self),
                    gz: buf.loadUnaligned(fromByteOffset: off + 10, as: Int16.self)
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
        controlChar = nil; statusChar = nil; downloadChar = nil; configChar = nil; timesyncChar = nil
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
            case timesyncCharUUID:
                timesyncChar = char
                syncTime()
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
