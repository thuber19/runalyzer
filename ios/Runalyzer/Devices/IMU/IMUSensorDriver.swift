import Foundation
import CoreBluetooth
import Combine

/// Driver for the Runalyzer IMU gait sensor.
/// Handles the full BLE protocol: time sync, recording control, status parsing, download.
class IMUSensorDriver: NSObject, DeviceDriver, ObservableObject {

    // MARK: - DeviceDriver conformance

    let descriptor: DeviceDescriptor = IMUSensorDescriptor.descriptor
    nonisolated let id: UUID
    var displayName: String
    @Published var connectionState: DeviceConnectionState = .disconnected
    let peripheral: CBPeripheral
    let events = PassthroughSubject<DriverEvent, Never>()

    // MARK: - IMU-specific published state

    @Published var deviceStatus = IMUDeviceStatus()
    @Published var appState: IMUAppState = .disconnected
    @Published var downloadProgress: Float = 0

    // MARK: - Callbacks (for backward compat during migration, will become Combine)

    var onPacket: ((IMUPacket) -> Void)?
    var onDownloadComplete: (([RecordedSample], IMUDeviceStatus, [IMUDeviceEvent]) -> Void)?

    // MARK: - BLE UUIDs

    private let imuServiceUUID   = CBUUID(string: "264f9cc7-8f8a-4aad-878a-d3615d12dccc")
    private let imuCharUUID      = CBUUID(string: "264f9cc7-8f8a-4aad-878a-d3615d12dcc1")
    private let controlCharUUID  = CBUUID(string: "264f9cc7-8f8a-4aad-878a-d3615d12dcc2")
    private let statusCharUUID   = CBUUID(string: "264f9cc7-8f8a-4aad-878a-d3615d12dcc3")
    private let downloadCharUUID = CBUUID(string: "264f9cc7-8f8a-4aad-878a-d3615d12dcc4")
    private let configCharUUID   = CBUUID(string: "264f9cc7-8f8a-4aad-878a-d3615d12dcc5")
    private let timesyncCharUUID = CBUUID(string: "264f9cc7-8f8a-4aad-878a-d3615d12dcc6")
    private let battCharUUID     = CBUUID(string: "2A19")

    // MARK: - Characteristic references

    private var controlChar: CBCharacteristic?
    private var statusChar: CBCharacteristic?
    private var downloadChar: CBCharacteristic?
    private var configChar: CBCharacteristic?
    private var timesyncChar: CBCharacteristic?

    // MARK: - Download state

    private var downloadedSamples: [RecordedSample] = []
    private var downloadedEvents: [IMUDeviceEvent] = []
    private var expectedDownloadCount: UInt32 = 0
    private var downloadTimeoutTimer: Timer?
    private var downloadRetryCount = 0
    private var firstStatusReceived = false

    // MARK: - Persisted state

    private let wasRecordingKey = "runalyzer_wasRecording"

    static let expectedProtocolVersion: UInt8 = 1

    // MARK: - Init

    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
        self.id = peripheral.identifier
        self.displayName = peripheral.name ?? "Runalyzer IMU"
        super.init()
    }

    // MARK: - DeviceDriver lifecycle

    func didDiscoverServices() {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func didDiscoverCharacteristics(for service: CBService) {
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

    func didUpdateValue(for characteristic: CBCharacteristic) {
        guard let data = characteristic.value else { return }
        // Debug: log which characteristic updated
        if characteristic.uuid != imuCharUUID {
            print("IMU didUpdateValue: \(characteristic.uuid) (\(data.count) bytes)")
        }
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
            if let pct = data.first {
                events.send(.battery(Int(pct)))
            }
        default: break
        }
    }

    func didDisconnect() {
        controlChar = nil; statusChar = nil; downloadChar = nil
        configChar = nil; timesyncChar = nil
        downloadTimeoutTimer?.invalidate()

        let previousState = appState
        if previousState == .downloading {
            downloadedSamples.removeAll()
            downloadProgress = 0
        }
        if previousState != .recording {
            appState = .disconnected
        }
    }

    // MARK: - Public Commands

    func startRecording() {
        if deviceStatus.state == .hasData && deviceStatus.sampleCount > 0 && appState != .downloading {
            return
        }
        if appState == .downloading { return }
        guard appState != .recording && appState != .stopping else { return }
        appState = .recording
        UserDefaults.standard.set(true, forKey: wasRecordingKey)
        sendCommand(1)
    }

    func stopRecording() {
        guard appState == .recording else { return }
        appState = .stopping
        UserDefaults.standard.set(false, forKey: wasRecordingKey)
        sendCommand(2)

        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.appState == .stopping else { return }
            self.appState = .idle
        }
    }

    func eraseData() {
        sendCommand(3)
    }

    func syncTime() {
        guard peripheral.state == .connected, let char = timesyncChar else { return }  // H2
        let unixMs = UInt64(Date().timeIntervalSince1970 * 1000)
        var data = Data(count: 8)
        data.withUnsafeMutableBytes { buf in
            buf.storeBytes(of: unixMs, as: UInt64.self)
        }
        peripheral.writeValue(data, for: char, type: .withResponse)
    }

    func setSampleRate(_ hz: UInt8) {
        guard peripheral.state == .connected, let char = configChar else { return }  // H2
        peripheral.writeValue(Data([hz]), for: char, type: .withResponse)
    }

    // MARK: - Private: Commands

    private func sendCommand(_ cmd: UInt8) {
        guard peripheral.state == .connected else {  // H2
            print("IMU: sendCommand(\(cmd)) FAILED — peripheral not connected")
            return
        }
        guard let char = controlChar else {
            print("IMU: sendCommand(\(cmd)) FAILED — controlChar is nil")
            return
        }
        print("IMU: sendCommand(\(cmd))")
        peripheral.writeValue(Data([cmd]), for: char, type: .withResponse)
    }

    // MARK: - Private: Download

    private func startDownload() {
        downloadedSamples.removeAll()
        downloadedEvents.removeAll()
        downloadRetryCount = 0
        expectedDownloadCount = deviceStatus.sampleCount
        downloadProgress = 0
        appState = .downloading
        print("IMU: startDownload — \(expectedDownloadCount) samples")
        sendCommand(4)
        resetDownloadTimeout()
    }

    private func requestNextChunk() {
        sendCommand(5)
        resetDownloadTimeout()
    }

    private func resetDownloadTimeout() {
        downloadTimeoutTimer?.invalidate()
        downloadTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            guard let self, self.appState == .downloading else { return }
            self.downloadRetryCount += 1
            print("IMU: download timeout, retry \(self.downloadRetryCount)/5")
            if self.downloadRetryCount < 5 {
                self.requestNextChunk()
            } else {
                print("IMU: download failed after 5 retries")
                self.downloadedSamples.removeAll()
                self.downloadedEvents.removeAll()
                self.downloadRetryCount = 0
                self.appState = .idle
            }
        }
    }

    // MARK: - Private: Parsing

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

    private func parseStatus(_ data: Data) {
        guard data.count >= 16 else { return }
        data.withUnsafeBytes { buf in
            deviceStatus.state = IMUDeviceState(rawValue: buf.loadUnaligned(fromByteOffset: 0, as: UInt8.self)) ?? .idle
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

        events.send(.battery(Int(deviceStatus.batteryPercent)))

        if !firstStatusReceived {
            firstStatusReceived = true
            if deviceStatus.protocolVersion > 0 && deviceStatus.protocolVersion != Self.expectedProtocolVersion {
                appState = .error("Firmware update required")
                return
            }
            reconcileState()
            return
        }

        // Continuous monitoring
        if appState == .recording && deviceStatus.state != .recording {
            UserDefaults.standard.set(false, forKey: wasRecordingKey)
            if deviceStatus.state == .hasData && deviceStatus.sampleCount > 0 {
                startDownload()
            } else {
                appState = .idle
            }
        }

        if deviceStatus.state == .hasData && deviceStatus.sampleCount > 0 && appState == .stopping {
            startDownload()
        }

        if deviceStatus.state == .idle && appState != .recording {
            if appState == .downloading || appState == .stopping {
                appState = .idle
            }
        }
    }

    private func reconcileState() {
        print("IMU reconcile: device=\(deviceStatus.state) appState=\(appState) controlChar=\(controlChar != nil) downloadChar=\(downloadChar != nil)")
        switch deviceStatus.state {
        case .recording:
            appState = .recording
            UserDefaults.standard.set(true, forKey: wasRecordingKey)
        case .hasData:
            UserDefaults.standard.set(false, forKey: wasRecordingKey)
            if appState != .downloading { startDownload() }
        case .idle:
            UserDefaults.standard.set(false, forKey: wasRecordingKey)
            appState = .idle
        case .downloading:
            appState = .downloading
        }
    }

    private func parseDownloadChunk(_ data: Data) {
        // End marker
        if data.count == 4 && data.allSatisfy({ $0 == 0xFF }) {
            downloadTimeoutTimer?.invalidate()
            downloadTimeoutTimer = nil
            downloadProgress = 1.0

            let samples = downloadedSamples
            let status = deviceStatus
            let evts = downloadedEvents

            appState = .idle
            onDownloadComplete?(samples, status, evts)
            downloadedSamples.removeAll()
            downloadedEvents.removeAll()
            return
        }

        // Event log packet
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
                    downloadedEvents.append(IMUDeviceEvent(reason: reason, offsetMs: ts))
                }
                requestNextChunk()
                return
            }
        }

        guard data.count >= 16 else { return }

        let sampleSize = 12
        let numSamples = (data.count - 4) / sampleSize
        guard numSamples > 0 else { return }

        let rate = max(1, UInt32(deviceStatus.sampleRateHz))
        let intervalMs = 1000 / rate

        data.withUnsafeBytes { buf in
            for i in 0..<numSamples {
                let off = 4 + (i * sampleSize)
                guard off + sampleSize <= data.count else { break }
                let sampleIndex = UInt32(downloadedSamples.count)
                downloadedSamples.append(RecordedSample(
                    timestamp: sampleIndex * intervalMs,
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

        requestNextChunk()
    }
}
