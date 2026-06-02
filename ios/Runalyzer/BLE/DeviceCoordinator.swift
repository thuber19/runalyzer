import Foundation
import CoreBluetooth
import Combine

/// Central coordinator for all BLE device management.
/// Single CBCentralManager, routes to device-specific drivers.
class DeviceCoordinator: NSObject, ObservableObject {

    static let registeredDevices: [DeviceDescriptor] = [
        IMUSensorDescriptor.descriptor,
        QNScaleDescriptor.descriptor,
    ]

    // Published state
    @Published var bluetoothState: CBManagerState = .unknown
    @Published var isScanning = false
    @Published var discoveredDevices: [DiscoveredDevice] = []
    @Published private(set) var activeDrivers: [UUID: any DeviceDriver] = [:]

    // Typed driver references for views to observe
    @Published var imuDriver: IMUSensorDriver?
    @Published var scaleDriver: QNScaleDriver?

    let registry = DeviceRegistry()

    private var centralManager: CBCentralManager!
    private var cancellables = Set<AnyCancellable>()
    private var peripheralDescriptorMap: [UUID: DeviceDescriptor] = [:]  // remember which descriptor matched
    private var scanTimer: Timer?

    private static let restoreIdentifier = "runalyzer-central"

    override init() {
        super.init()
        centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier]
        )
    }

    // MARK: - Scanning

    func startScanning(duration: TimeInterval = 30) {
        guard centralManager.state == .poweredOn else { return }
        // Don't clear discovered — accumulate
        // Scan for all registered service UUIDs, plus nil to catch devices that don't advertise services
        centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        isScanning = true

        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.stopScanning()
        }
    }

    func stopScanning() {
        centralManager.stopScan()
        isScanning = false
        scanTimer?.invalidate()
        scanTimer = nil
    }

    // MARK: - Connection

    func connect(_ device: DiscoveredDevice) {
        peripheralDescriptorMap[device.id] = device.descriptor
        centralManager.connect(device.peripheral, options: nil)
    }

    func disconnect(_ deviceID: UUID) {
        guard let driver = activeDrivers[deviceID] else { return }
        centralManager.cancelPeripheralConnection(driver.peripheral)
    }

    func pair(_ device: DiscoveredDevice, displayName: String? = nil) {
        let known = KnownDevice(
            id: device.id,
            descriptorID: device.descriptor.id,
            displayName: displayName ?? device.name,
            lastSeen: Date(),
            autoConnect: true
        )
        registry.save(known)
        connect(device)
    }

    func forget(_ deviceID: UUID) {
        disconnect(deviceID)
        registry.forget(deviceID)
    }

    // MARK: - Descriptor Matching

    private func matchDescriptor(for peripheral: CBPeripheral, advertisementData: [String: Any]) -> DeviceDescriptor? {
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""

        // Match by advertised service UUID
        for descriptor in Self.registeredDevices {
            if descriptor.serviceUUIDs.contains(where: { advertisedServices.contains($0) }) {
                return descriptor
            }
        }

        // Match by name patterns
        let lowName = name.lowercased()
        if lowName.contains("runalyzer") { return IMUSensorDescriptor.descriptor }
        if lowName.contains("qn-scale") || lowName.contains("qn_scale") { return QNScaleDescriptor.descriptor }

        return nil
    }
}

// MARK: - CBCentralManagerDelegate

extension DeviceCoordinator: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        if central.state == .poweredOn {
            startScanning()
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // Recover peripherals that were connected before the app was killed
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for peripheral in peripherals {
                // Try to match descriptor from registry
                if let known = registry.knownDevices.first(where: { $0.id == peripheral.identifier }) {
                    if let descriptor = Self.registeredDevices.first(where: { $0.id == known.descriptorID }) {
                        peripheralDescriptorMap[peripheral.identifier] = descriptor
                        let driver = descriptor.driverFactory(peripheral)
                        driver.connectionState = .connected
                        activeDrivers[peripheral.identifier] = driver

                        if let imu = driver as? IMUSensorDriver { imuDriver = imu }
                        if let scale = driver as? QNScaleDriver { scaleDriver = scale }

                        peripheral.delegate = self
                        peripheral.discoverServices(descriptor.serviceUUIDs)
                    }
                }
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let descriptor = matchDescriptor(for: peripheral, advertisementData: advertisementData) else { return }

        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Unknown"
        let isKnown = registry.isKnown(peripheral.identifier)

        // Remember descriptor for this peripheral
        peripheralDescriptorMap[peripheral.identifier] = descriptor

        // Update or add to discovered list
        if let idx = discoveredDevices.firstIndex(where: { $0.id == peripheral.identifier }) {
            discoveredDevices[idx].rssi = RSSI.intValue
        } else {
            discoveredDevices.append(DiscoveredDevice(
                id: peripheral.identifier,
                peripheral: peripheral,
                descriptor: descriptor,
                name: name,
                rssi: RSSI.intValue,
                isKnown: isKnown
            ))
        }

        // Auto-connect known devices
        if isKnown && registry.shouldAutoConnect(peripheral.identifier) {
            if activeDrivers[peripheral.identifier] == nil {
                peripheralDescriptorMap[peripheral.identifier] = descriptor
                central.connect(peripheral, options: nil)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let descriptor = peripheralDescriptorMap[peripheral.identifier] else { return }

        let driver = descriptor.driverFactory(peripheral)
        driver.connectionState = .connected
        activeDrivers[peripheral.identifier] = driver

        // Set typed references
        if let imu = driver as? IMUSensorDriver { imuDriver = imu }
        if let scale = driver as? QNScaleDriver { scaleDriver = scale }

        // Forward driver's objectWillChange to coordinator so views refresh
        if let imuDriver = driver as? IMUSensorDriver {
            imuDriver.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }.store(in: &cancellables)
        } else if let scaleDriver = driver as? QNScaleDriver {
            scaleDriver.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }.store(in: &cancellables)
        }

        registry.updateLastSeen(peripheral.identifier)
        peripheral.delegate = self
        peripheral.discoverServices(descriptor.serviceUUIDs)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if let driver = activeDrivers[peripheral.identifier] {
            driver.didDisconnect()
            driver.connectionState = .disconnected
        }

        if activeDrivers[peripheral.identifier] is IMUSensorDriver { imuDriver = nil }
        if activeDrivers[peripheral.identifier] is QNScaleDriver { scaleDriver = nil }
        activeDrivers.removeValue(forKey: peripheral.identifier)

        if let idx = discoveredDevices.firstIndex(where: { $0.id == peripheral.identifier }) {
            discoveredDevices[idx].isConnected = false
        }

        // Auto-reconnect
        if registry.shouldAutoConnect(peripheral.identifier) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.startScanning()
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension DeviceCoordinator: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let driver = activeDrivers[peripheral.identifier] else { return }
        driver.didDiscoverServices()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let driver = activeDrivers[peripheral.identifier] else { return }
        driver.didDiscoverCharacteristics(for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let driver = activeDrivers[peripheral.identifier] else { return }
        // Dispatch to next run loop cycle to let BLE stack breathe between chunks
        DispatchQueue.main.async {
            driver.didUpdateValue(for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        // Drivers handle write confirmations internally if needed
    }
}
