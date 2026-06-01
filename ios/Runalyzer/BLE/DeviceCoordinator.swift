import Foundation
import CoreBluetooth
import Combine

/// Central coordinator for all BLE device management.
/// Owns the single CBCentralManager, routes to device-specific drivers.
class DeviceCoordinator: NSObject, ObservableObject {

    // All registered device types — add new descriptors here
    static let registeredDevices: [DeviceDescriptor] = [
        IMUSensorDescriptor.descriptor,
        QNScaleDescriptor.descriptor,
    ]

    // Published state
    @Published var bluetoothState: CBManagerState = .unknown
    @Published var isScanning = false
    @Published var discoveredDevices: [DiscoveredDevice] = []
    @Published private(set) var activeDrivers: [UUID: any DeviceDriver] = [:]

    // Sub-managers
    let registry = DeviceRegistry()

    // Private
    private var centralManager: CBCentralManager!
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Scanning

    func startScanning() {
        guard centralManager.state == .poweredOn else { return }
        discoveredDevices.removeAll()
        let allServiceUUIDs = Self.registeredDevices.flatMap(\.serviceUUIDs)
        centralManager.scanForPeripherals(
            withServices: allServiceUUIDs.isEmpty ? nil : allServiceUUIDs,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        isScanning = true
    }

    func stopScanning() {
        centralManager.stopScan()
        isScanning = false
    }

    // MARK: - Connection

    func connect(_ device: DiscoveredDevice) {
        centralManager.connect(device.peripheral, options: nil)
        // Update discovered device state
        if let idx = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
            discoveredDevices[idx].isConnected = true
        }
    }

    func disconnect(_ deviceID: UUID) {
        guard let driver = activeDrivers[deviceID] else { return }
        centralManager.cancelPeripheralConnection(driver.peripheral)
    }

    // MARK: - Pairing

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

    // MARK: - Driver Access

    /// Get a specific driver type for a connected device.
    func driver<T: DeviceDriver>(ofType type: T.Type) -> T? {
        activeDrivers.values.first(where: { $0 is T }) as? T
    }

    /// Get all drivers of a specific type.
    func drivers<T: DeviceDriver>(ofType type: T.Type) -> [T] {
        activeDrivers.values.compactMap { $0 as? T }
    }

    // MARK: - Private: Driver Creation

    private func createDriver(for peripheral: CBPeripheral, descriptor: DeviceDescriptor) -> any DeviceDriver {
        let driver = descriptor.driverFactory(peripheral)
        return driver
    }

    private func matchDescriptor(for advertisedServices: [CBUUID]) -> DeviceDescriptor? {
        Self.registeredDevices.first { descriptor in
            descriptor.serviceUUIDs.contains(where: advertisedServices.contains)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension DeviceCoordinator: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        if central.state == .poweredOn {
            // Auto-connect known devices
            startScanning()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Unknown"

        guard let descriptor = matchDescriptor(for: advertisedServices) else { return }

        let isKnown = registry.isKnown(peripheral.identifier)

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

        // Auto-connect if known
        if isKnown && registry.shouldAutoConnect(peripheral.identifier) {
            if activeDrivers[peripheral.identifier] == nil {
                central.connect(peripheral, options: nil)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // Find the descriptor for this peripheral
        let discovered = discoveredDevices.first(where: { $0.id == peripheral.identifier })
        guard let descriptor = discovered?.descriptor else { return }

        // Create driver
        let driver = createDriver(for: peripheral, descriptor: descriptor)
        driver.connectionState = .connected
        activeDrivers[peripheral.identifier] = driver

        // Update registry
        registry.updateLastSeen(peripheral.identifier)

        // Set delegate and discover services
        peripheral.delegate = self
        peripheral.discoverServices(descriptor.serviceUUIDs)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if let driver = activeDrivers[peripheral.identifier] {
            driver.didDisconnect()
            driver.connectionState = .disconnected
        }
        activeDrivers.removeValue(forKey: peripheral.identifier)

        // Update discovered list
        if let idx = discoveredDevices.firstIndex(where: { $0.id == peripheral.identifier }) {
            discoveredDevices[idx].isConnected = false
        }

        // Auto-reconnect if known
        if registry.shouldAutoConnect(peripheral.identifier) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.startScanning()
            }
        }
    }
}

// MARK: - CBPeripheralDelegate (routes to drivers)

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
        DispatchQueue.main.async { [weak driver] in
            driver?.didUpdateValue(for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        // Drivers can handle write confirmations if needed
    }
}
