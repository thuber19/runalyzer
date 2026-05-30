import Foundation
import CoreBluetooth
import Combine

struct IMUPacket {
    let timestamp: UInt32
    let ax: Int16
    let ay: Int16
    let az: Int16
    let gx: Int16
    let gy: Int16
    let gz: Int16

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
        return sqrtf(a.x * a.x + a.y * a.y + a.z * a.z)
    }
    var gyroMagnitude: Float {
        let g = gyroDPS
        return sqrtf(g.x * g.x + g.y * g.y + g.z * g.z)
    }
}

enum BLEState: String {
    case disconnected = "Disconnected"
    case scanning = "Scanning..."
    case connecting = "Connecting..."
    case connected = "Connected"
}

class BLEManager: NSObject, ObservableObject {
    private let imuServiceUUID = CBUUID(string: "12345678-1234-5678-1234-56789abcdef0")
    private let imuCharUUID = CBUUID(string: "12345678-1234-5678-1234-56789abcdef1")
    private let battServiceUUID = CBUUID(string: "180F")
    private let battCharUUID = CBUUID(string: "2A19")

    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var batteryChar: CBCharacteristic?
    private var batteryTimer: Timer?

    @Published var state: BLEState = .disconnected
    @Published var rssi: Int = 0

    var onPacket: ((IMUPacket) -> Void)?
    var onBattery: ((Int) -> Void)?

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    func startScanning() {
        guard centralManager.state == .poweredOn else { return }
        state = .scanning
        centralManager.scanForPeripherals(withServices: [imuServiceUUID], options: nil)
    }

    func disconnect() {
        batteryTimer?.invalidate()
        batteryTimer = nil
        if let p = peripheral {
            centralManager.cancelPeripheralConnection(p)
        }
        state = .disconnected
    }

    private func parsePacket(_ data: Data) -> IMUPacket? {
        guard data.count >= 16 else { return nil }
        return data.withUnsafeBytes { buf in
            let ts = buf.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            let ax = buf.loadUnaligned(fromByteOffset: 4, as: Int16.self)
            let ay = buf.loadUnaligned(fromByteOffset: 6, as: Int16.self)
            let az = buf.loadUnaligned(fromByteOffset: 8, as: Int16.self)
            let gx = buf.loadUnaligned(fromByteOffset: 10, as: Int16.self)
            let gy = buf.loadUnaligned(fromByteOffset: 12, as: Int16.self)
            let gz = buf.loadUnaligned(fromByteOffset: 14, as: Int16.self)
            return IMUPacket(timestamp: ts, ax: ax, ay: ay, az: az, gx: gx, gy: gy, gz: gz)
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            startScanning()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        self.peripheral = peripheral
        self.rssi = RSSI.intValue
        state = .connecting
        central.stopScan()
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        state = .connected
        peripheral.delegate = self
        peripheral.discoverServices([imuServiceUUID, battServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        state = .disconnected
        batteryTimer?.invalidate()
        batteryTimer = nil
        // Auto-reconnect
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
            if char.uuid == imuCharUUID {
                peripheral.setNotifyValue(true, for: char)
            } else if char.uuid == battCharUUID {
                batteryChar = char
                peripheral.readValue(for: char)
                // Poll battery every 30s
                batteryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                    guard let self, let bc = self.batteryChar else { return }
                    peripheral.readValue(for: bc)
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }

        if characteristic.uuid == imuCharUUID, let packet = parsePacket(data) {
            DispatchQueue.main.async {
                self.onPacket?(packet)
            }
        } else if characteristic.uuid == battCharUUID, let first = data.first {
            DispatchQueue.main.async {
                self.onBattery?(Int(first))
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        rssi = RSSI.intValue
    }
}
