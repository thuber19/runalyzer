import Foundation
import CoreBluetooth

/// Static description of a device type. One per device kind.
/// Used for scanning, discovery UI, and driver instantiation.
struct DeviceDescriptor: Identifiable {
    let id: String                      // e.g. "imu_sensor", "qn_scale"
    let displayName: String             // e.g. "IMU Gait Sensor"
    let icon: String                    // SF Symbol name
    let serviceUUIDs: [CBUUID]          // advertised services to scan for
    let driverFactory: (CBPeripheral) -> any DeviceDriver

    static func == (lhs: DeviceDescriptor, rhs: DeviceDescriptor) -> Bool { lhs.id == rhs.id }
}
