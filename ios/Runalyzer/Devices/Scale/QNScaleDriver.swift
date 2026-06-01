import Foundation
import CoreBluetooth
import Combine

/// Driver for QN-Scale body fat scales.
/// Implements the vendor handshake protocol and collects weight + bioimpedance readings.
class QNScaleDriver: NSObject, DeviceDriver, ObservableObject {

    // MARK: - DeviceDriver conformance

    let descriptor: DeviceDescriptor = QNScaleDescriptor.descriptor
    nonisolated let id: UUID
    var displayName: String
    @Published var connectionState: DeviceConnectionState = .disconnected
    let peripheral: CBPeripheral
    let events = PassthroughSubject<DriverEvent, Never>()

    // MARK: - Scale-specific state

    enum ScaleState: String {
        case idle = "Idle"
        case waitingForInfo = "Connecting..."
        case configured = "Configured"
        case measuring = "Measuring..."
        case stable = "Stable reading"
        case complete = "Complete"
    }

    @Published var scaleState: ScaleState = .idle
    @Published var liveWeight: Double = 0
    @Published var isStable = false
    @Published var lastMeasurement: ScaleMeasurement?

    // MARK: - BLE

    private let serviceUUID = CBUUID(string: "FFF0")
    private let notifyUUID  = CBUUID(string: "0000FFF1-0000-1000-8000-00805F9B34FB")
    private let writeUUID   = CBUUID(string: "0000FFF2-0000-1000-8000-00805F9B34FB")

    private var writeChar: CBCharacteristic?
    private var ptype: UInt8 = 0

    // MARK: - Measurement collection

    private var stableWeights: [Double] = []
    private var stableImpedances: [Double] = []
    private var stableStartTime: Date?
    private let collectDuration: TimeInterval = 5.0  // seconds to collect stable readings

    // MARK: - Protocol constants

    private let unitKg: UInt8 = 0x01
    private let qnEpoch: UInt32 = 946_702_800  // 2000-01-01 in Unix time

    // MARK: - Init

    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
        self.id = peripheral.identifier
        self.displayName = peripheral.name ?? "QN-Scale"
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
            if char.uuid == notifyUUID || char.uuid == CBUUID(string: "FFF1") {
                peripheral.setNotifyValue(true, for: char)
                scaleState = .waitingForInfo
            } else if char.uuid == writeUUID || char.uuid == CBUUID(string: "FFF2") {
                writeChar = char
            }
        }
    }

    func didUpdateValue(for characteristic: CBCharacteristic) {
        guard let data = characteristic.value, !data.isEmpty else { return }
        let opcode = data[0]

        switch opcode {
        case 0x12:
            handleInfo(data)
        case 0x14:
            handleAck(data)
        case 0x10:
            handleData(data)
        default:
            break
        }
    }

    func didDisconnect() {
        writeChar = nil
        scaleState = .idle
        stableWeights.removeAll()
        stableImpedances.removeAll()
    }

    // MARK: - Protocol Handlers

    private func handleInfo(_ data: Data) {
        // Extract ptype from frame
        if data.count > 2 {
            ptype = data[2]
        }

        // Reply: 0x13 config frame
        let config: [UInt8] = [0x13, 0x09, ptype, unitKg, 0x10, 0x00, 0x00, 0x00]
        writeWithChecksum(config)

        // Reply: 0x02 time sync (no checksum on this one)
        let timeBytes = qnTimeBytes()
        let timeFrame: [UInt8] = [0x02] + timeBytes
        writeRaw(timeFrame)

        scaleState = .configured
    }

    private func handleAck(_ data: Data) {
        // Reply: 0x20 time confirmation frame
        let timeBytes = qnTimeBytes()
        let frame: [UInt8] = [0x20, 0x08, ptype] + timeBytes
        writeWithChecksum(frame)

        scaleState = .measuring
        events.send(.status("Step on the scale..."))
    }

    private func handleData(_ data: Data) {
        guard data.count >= 10 else { return }

        let isSettled = data[5] == 1

        // Decode weight: bytes[3..4] big-endian / 100
        let weightRaw = (UInt16(data[3]) << 8) | UInt16(data[4])
        var weight = Double(weightRaw) / 100.0
        if weight >= 250 { weight /= 10.0 }  // vendor scale-factor correction

        liveWeight = weight

        if isSettled {
            scaleState = .stable
            isStable = true

            stableWeights.append(weight)

            // Impedance channels
            let ch1 = (UInt16(data[6]) << 8) | UInt16(data[7])
            let ch2 = (UInt16(data[8]) << 8) | UInt16(data[9])
            if ch1 > 0 { stableImpedances.append(Double(ch1)) }
            if ch2 > 0 { stableImpedances.append(Double(ch2)) }

            // Start collection timer on first stable frame
            if stableStartTime == nil {
                stableStartTime = Date()
                DispatchQueue.main.asyncAfter(deadline: .now() + collectDuration) { [weak self] in
                    self?.finalizeMeasurement()
                }
            }
        } else {
            scaleState = .measuring
            isStable = false
        }
    }

    // MARK: - Finalize

    private func finalizeMeasurement() {
        guard !stableWeights.isEmpty else { return }

        let weight = median(stableWeights)
        let impedance = stableImpedances.isEmpty ? 500.0 : median(stableImpedances)  // fallback if no impedance

        let profile = UserProfile.load()
        let measurement = ScaleMeasurement.from(
            weightKg: weight,
            impedanceOhm: impedance,
            profile: profile,
            deviceName: displayName
        )

        lastMeasurement = measurement
        scaleState = .complete

        events.send(.measurementReady(measurement))
        events.send(.status("Measurement complete"))

        // Reset for next measurement
        stableWeights.removeAll()
        stableImpedances.removeAll()
        stableStartTime = nil
    }

    // MARK: - Helpers

    private func qnTimeBytes() -> [UInt8] {
        let t = UInt32(Date().timeIntervalSince1970) - qnEpoch
        return [UInt8(t & 0xFF), UInt8((t >> 8) & 0xFF), UInt8((t >> 16) & 0xFF), UInt8((t >> 24) & 0xFF)]
    }

    private func writeWithChecksum(_ body: [UInt8]) {
        let checksum = UInt8(body.reduce(0) { ($0 + Int($1)) } & 0xFF)
        let frame = Data(body + [checksum])
        writeRaw(Array(frame))
    }

    private func writeRaw(_ bytes: [UInt8]) {
        guard let char = writeChar else { return }
        peripheral.writeValue(Data(bytes), for: char, type: .withResponse)
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let count = sorted.count
        if count == 0 { return 0 }
        if count % 2 == 0 {
            return (sorted[count/2 - 1] + sorted[count/2]) / 2.0
        }
        return sorted[count/2]
    }
}
