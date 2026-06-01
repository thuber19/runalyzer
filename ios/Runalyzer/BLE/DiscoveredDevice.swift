import Foundation
import CoreBluetooth

/// A device found during BLE scanning, before pairing.
struct DiscoveredDevice: Identifiable {
    let id: UUID                        // peripheral.identifier
    let peripheral: CBPeripheral
    let descriptor: DeviceDescriptor    // matched device type
    let name: String                    // advertised name or "Unknown"
    var rssi: Int
    var isKnown: Bool                   // already in DeviceRegistry
    var isConnected: Bool = false
}
