import Foundation
import Combine

/// A saved device the user has paired with.
struct KnownDevice: Codable, Identifiable {
    let id: UUID                    // CBPeripheral.identifier
    let descriptorID: String        // DeviceDescriptor.id
    var displayName: String         // user-customizable label
    var lastSeen: Date
    var autoConnect: Bool = true
}

/// Persists known/paired devices across app launches.
class DeviceRegistry: ObservableObject {
    @Published var knownDevices: [KnownDevice] = []

    private let key = "runalyzer_known_devices"

    init() {
        load()
    }

    func save(_ device: KnownDevice) {
        if let idx = knownDevices.firstIndex(where: { $0.id == device.id }) {
            knownDevices[idx] = device
        } else {
            knownDevices.append(device)
        }
        persist()
    }

    func forget(_ id: UUID) {
        knownDevices.removeAll { $0.id == id }
        persist()
    }

    func isKnown(_ peripheralID: UUID) -> Bool {
        knownDevices.contains { $0.id == peripheralID }
    }

    func shouldAutoConnect(_ peripheralID: UUID) -> Bool {
        knownDevices.first(where: { $0.id == peripheralID })?.autoConnect ?? false
    }

    func updateLastSeen(_ id: UUID) {
        guard let idx = knownDevices.firstIndex(where: { $0.id == id }) else { return }
        knownDevices[idx].lastSeen = Date()
        persist()
    }

    func updateDisplayName(_ id: UUID, name: String) {
        guard let idx = knownDevices.firstIndex(where: { $0.id == id }) else { return }
        knownDevices[idx].displayName = name
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(knownDevices) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let devices = try? JSONDecoder().decode([KnownDevice].self, from: data) else { return }
        knownDevices = devices
    }
}
