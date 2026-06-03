import Foundation
import CoreBluetooth
import Combine

/// Connection state for any device.
enum DeviceConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)

    static func == (lhs: DeviceConnectionState, rhs: DeviceConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected), (.connecting, .connecting), (.connected, .connected): return true
        case (.error(let a), .error(let b)): return a == b
        default: return false
        }
    }
}

/// Events emitted by device drivers to the coordinator.
enum DriverEvent {
    case battery(Int)                       // 0-100%
    case status(String)                     // human-readable status text
    case measurementReady(Any)  // final result to store (ScaleMeasurement, etc.)
}

/// The protocol every device driver must conform to.
/// One instance per connected peripheral.
protocol DeviceDriver: AnyObject, ObservableObject {
    /// The descriptor that created this driver.
    var descriptor: DeviceDescriptor { get }

    /// Unique ID (matches peripheral.identifier).
    nonisolated var id: UUID { get }

    /// User-visible name.
    var displayName: String { get set }

    /// Current connection state.
    var connectionState: DeviceConnectionState { get set }

    /// The CBPeripheral this driver manages.
    var peripheral: CBPeripheral { get }

    // --- Lifecycle ---

    /// Called after services are discovered. Driver discovers characteristics + subscribes.
    func didDiscoverServices()

    /// Called after characteristics are discovered for a service.
    func didDiscoverCharacteristics(for service: CBService)

    /// Called when a characteristic value updates (notification or read response).
    func didUpdateValue(for characteristic: CBCharacteristic)

    /// Called when the peripheral disconnects.
    func didDisconnect()

    /// Called when a write to a characteristic fails. Rec 2: surfaces write errors through
    /// the driver so views can show actionable feedback rather than silent log lines.
    func didWriteError(_ error: Error, for characteristic: CBCharacteristic)

    /// Returns a type-erased publisher that fires whenever the driver's state changes.
    /// Rec 3: allows DeviceCoordinator to forward objectWillChange generically without
    /// type-switching for each device kind.
    func observeChanges() -> AnyPublisher<Void, Never>

    // --- Events ---

    /// Publisher that emits driver events.
    var events: PassthroughSubject<DriverEvent, Never> { get }
}
