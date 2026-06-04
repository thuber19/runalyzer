import Foundation
import CoreBluetooth
import Combine
import os
import UIKit

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
    private var driverCancellables: [UUID: AnyCancellable] = [:]  // per-driver, cleaned on disconnect
    private var peripheralDescriptorMap: [UUID: DeviceDescriptor] = [:]  // remember which descriptor matched
    private var retainedPeripherals: [UUID: CBPeripheral] = [:]  // prevent ARC deallocation (C4)
    private var restoredPeripherals: [CBPeripheral] = []  // phase-1 restore buffer (C1/C2/C3)
    private var scanTimer: Timer?
    private var reconnectAttempts: [UUID: Int] = [:]  // M6: track attempts per device

    private static let restoreIdentifier = "runalyzer-central"

    override init() {
        super.init()
        // queue: nil → all CBCentralManagerDelegate and CBPeripheralDelegate callbacks
        // are dispatched on the main queue. @Published mutations are therefore main-thread-safe.
        // didUpdateValueFor adds an extra DispatchQueue.main.async to avoid blocking the BLE
        // stack when writing the next-chunk command synchronously inside the callback.
        centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier]
        )
    }

    // MARK: - Scanning

    func startScanning(duration: TimeInterval = 30) {
        guard centralManager.state == .poweredOn else { return }
        // H4: Background scanning requires explicit service UUIDs — iOS won't deliver callbacks otherwise.
        // In the foreground we scan with nil so devices that don't advertise their service UUID
        // (e.g. the QN Scale, which advertises by name only) are still discovered.
        let isBackground = UIApplication.shared.applicationState == .background
        let serviceUUIDs: [CBUUID]? = isBackground
            ? Self.registeredDevices.flatMap { $0.serviceUUIDs }
            : nil
        centralManager.scanForPeripherals(withServices: serviceUUIDs, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
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
        guard centralManager.state == .poweredOn else { return }  // H1
        peripheralDescriptorMap[device.id] = device.descriptor
        retainedPeripherals[device.id] = device.peripheral  // C4
        centralManager.connect(device.peripheral, options: nil)
    }

    func disconnect(_ deviceID: UUID) {
        guard centralManager.state == .poweredOn else { return }  // H1
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

    func renameDevice(_ deviceID: UUID, name: String) {
        registry.updateDisplayName(deviceID, name: name)
        // Also update active driver if connected
        if let driver = activeDrivers[deviceID] {
            driver.displayName = name
        }
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
            // C3: Process restored peripherals now that BLE is ready
            processRestoredPeripherals()
            startScanning()
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // C1/C2: Phase 1 — just stash peripherals. Don't create drivers yet.
        // We process them in centralManagerDidUpdateState when BLE is actually ready.
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            restoredPeripherals = peripherals
            for peripheral in peripherals {
                retainedPeripherals[peripheral.identifier] = peripheral  // C4: prevent deallocation
                peripheral.delegate = self
            }
        }
    }

    /// C1/C2/C3: Phase 2 — called from centralManagerDidUpdateState(.poweredOn).
    /// Creates drivers for peripherals that are truly connected, disconnects phantoms.
    private func processRestoredPeripherals() {
        let restored = restoredPeripherals
        restoredPeripherals.removeAll()

        for peripheral in restored {
            guard let known = registry.knownDevices.first(where: { $0.id == peripheral.identifier }),
                  let descriptor = Self.registeredDevices.first(where: { $0.id == known.descriptorID }) else {
                // Unknown peripheral from restore — disconnect it
                centralManager.cancelPeripheralConnection(peripheral)
                retainedPeripherals.removeValue(forKey: peripheral.identifier)
                continue
            }

            peripheralDescriptorMap[peripheral.identifier] = descriptor

            if peripheral.state == .connected {
                // Truly connected — create driver and start service discovery
                let driver = descriptor.driverFactory(peripheral)
                driver.connectionState = .connected
                driver.displayName = known.displayName
                activeDrivers[peripheral.identifier] = driver

                if let imu = driver as? IMUSensorDriver { imuDriver = imu }
                if let scale = driver as? QNScaleDriver { scaleDriver = scale }

                forwardDriverChanges(driver, id: peripheral.identifier)
                registry.updateLastSeen(peripheral.identifier)
                peripheral.discoverServices(descriptor.serviceUUIDs)
            } else if peripheral.state == .connecting {
                // Still connecting — let didConnect handle it
            } else {
                // C2: Phantom — disconnected while app was dead
                retainedPeripherals.removeValue(forKey: peripheral.identifier)
                if registry.shouldAutoConnect(peripheral.identifier) {
                    centralManager.connect(peripheral, options: nil)
                    retainedPeripherals[peripheral.identifier] = peripheral
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
            // M4: Only update RSSI if it changed meaningfully — suppresses pointless objectWillChange
            // fires on every advertisement packet when signal is steady.
            if abs(discoveredDevices[idx].rssi - RSSI.intValue) > 3 {
                discoveredDevices[idx].rssi = RSSI.intValue
            }
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

        // Retain peripheral to prevent ARC deallocation (C4)
        retainedPeripherals[peripheral.identifier] = peripheral

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

        // Use saved display name from registry if available
        if let known = registry.knownDevices.first(where: { $0.id == peripheral.identifier }) {
            driver.displayName = known.displayName
        }

        activeDrivers[peripheral.identifier] = driver
        reconnectAttempts.removeValue(forKey: peripheral.identifier)  // M6: reset on success

        // Set typed references
        if let imu = driver as? IMUSensorDriver { imuDriver = imu }
        if let scale = driver as? QNScaleDriver { scaleDriver = scale }

        // M5: Per-driver Combine forwarding, cleaned up on disconnect
        forwardDriverChanges(driver, id: peripheral.identifier)

        registry.updateLastSeen(peripheral.identifier)
        peripheral.delegate = self
        peripheral.discoverServices(descriptor.serviceUUIDs)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier

        if let driver = activeDrivers[id] {
            driver.didDisconnect()
            driver.connectionState = .disconnected
        }

        if activeDrivers[id] is IMUSensorDriver { imuDriver = nil }
        if activeDrivers[id] is QNScaleDriver { scaleDriver = nil }
        activeDrivers.removeValue(forKey: id)
        driverCancellables.removeValue(forKey: id)

        if let idx = discoveredDevices.firstIndex(where: { $0.id == id }) {
            discoveredDevices[idx].isConnected = false
        }

        // M6: Exponential backoff reconnect with a hard retry cap.
        // Attempt 1→1s, 2→2s, 3→4s … capped at 30s. After 10 attempts, give up.
        if registry.shouldAutoConnect(id) {
            let attempt = (reconnectAttempts[id] ?? 0) + 1
            reconnectAttempts[id] = attempt

            if attempt <= 10 {
                let delay = min(pow(2.0, Double(attempt - 1)), 30.0)
                retainedPeripherals[id] = peripheral
                AppLogger.ble.info("Scheduling reconnect for \(id), attempt \(attempt)/10 in \(delay, format: .fixed(precision: 0))s")
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.centralManager.state == .poweredOn else { return }
                    self.centralManager.connect(peripheral, options: nil)
                }
            } else {
                AppLogger.ble.warning("Giving up reconnect for \(id) after 10 attempts")
                reconnectAttempts.removeValue(forKey: id)
                retainedPeripherals.removeValue(forKey: id)
            }
        } else {
            retainedPeripherals.removeValue(forKey: id)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension DeviceCoordinator: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        // Defensive main-thread dispatch: queue is nil (main) but explicit to guard against
        // future queue changes silently breaking @Published mutations inside drivers.
        DispatchQueue.main.async {
            guard let driver = self.activeDrivers[peripheral.identifier] else { return }
            // H2: Surface discovery errors to the driver's connectionState instead of silently ignoring.
            if let error = error {
                driver.connectionState = .error("Service discovery failed: \(error.localizedDescription)")
                return
            }
            driver.didDiscoverServices()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        DispatchQueue.main.async {
            guard let driver = self.activeDrivers[peripheral.identifier] else { return }
            if let error = error {
                driver.connectionState = .error("Characteristic discovery failed: \(error.localizedDescription)")
                return
            }
            driver.didDiscoverCharacteristics(for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let driver = activeDrivers[peripheral.identifier] else { return }
        // Dispatch to next run loop cycle — calling writeValue (cmd 5) synchronously
        // inside a didUpdateValue callback can block the BLE stack from delivering
        // subsequent notifications, causing download stalls.
        DispatchQueue.main.async {
            driver.didUpdateValue(for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        // Rec 2: Route write errors to the driver so it can surface them in the UI.
        if let error, let driver = activeDrivers[peripheral.identifier] {
            driver.didWriteError(error, for: characteristic)
        }
    }
}

// MARK: - Helpers

extension DeviceCoordinator {
    /// Rec 3: Generic per-driver objectWillChange forwarding via observeChanges().
    /// No type-switching — works for any conforming DeviceDriver automatically.
    private func forwardDriverChanges(_ driver: any DeviceDriver, id: UUID) {
        driverCancellables[id] = driver.observeChanges().sink { [weak self] in
            self?.objectWillChange.send()
        }
    }
}
