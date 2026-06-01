import Foundation
import CoreBluetooth

enum QNScaleDescriptor {
    static let serviceUUID = CBUUID(string: "FFF0")

    static let descriptor = DeviceDescriptor(
        id: "qn_scale",
        displayName: "Body Fat Scale",
        icon: "scalemass",
        serviceUUIDs: [serviceUUID],
        driverFactory: { peripheral in
            QNScaleDriver(peripheral: peripheral)
        }
    )
}
