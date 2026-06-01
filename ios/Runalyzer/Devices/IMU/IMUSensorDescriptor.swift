import Foundation
import CoreBluetooth

enum IMUSensorDescriptor {
    static let serviceUUID = CBUUID(string: "264f9cc7-8f8a-4aad-878a-d3615d12dccc")

    static let descriptor = DeviceDescriptor(
        id: "imu_sensor",
        displayName: "Runalyzer IMU",
        icon: "figure.run",
        serviceUUIDs: [serviceUUID, CBUUID(string: "180F")],
        driverFactory: { peripheral in
            IMUSensorDriver(peripheral: peripheral)
        }
    )
}
