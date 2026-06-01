import SwiftUI

/// Scan, pair, manage, and forget devices.
struct DeviceListView: View {
    @EnvironmentObject var coordinator: DeviceCoordinator

    @State private var renameDeviceID: UUID?
    @State private var renameText = ""
    @State private var showForgetConfirm = false
    @State private var forgetDeviceID: UUID?

    var body: some View {
        List {
            // Connected devices
            if !coordinator.activeDrivers.isEmpty {
                Section("Connected") {
                    ForEach(Array(coordinator.activeDrivers.values), id: \.id) { driver in
                        connectedRow(driver)
                    }
                }
            }

            // Known (paired) but not connected
            let offlineKnown = coordinator.registry.knownDevices.filter { known in
                !coordinator.activeDrivers.keys.contains(known.id)
            }
            if !offlineKnown.isEmpty {
                Section("Paired (offline)") {
                    ForEach(offlineKnown) { device in
                        knownRow(device)
                    }
                }
            }

            // Discovered (not paired)
            let unpaired = coordinator.discoveredDevices.filter { !$0.isKnown }
            if !unpaired.isEmpty {
                Section("Nearby") {
                    ForEach(unpaired) { device in
                        discoveredRow(device)
                    }
                }
            }

            // Scan controls
            Section {
                if coordinator.isScanning {
                    HStack {
                        ProgressView().padding(.trailing, 8)
                        Text("Scanning for devices...")
                    }
                } else {
                    Button(action: { coordinator.startScanning() }) {
                        Label("Scan for Devices", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
            }
        }
        .navigationTitle("Devices")
        .onAppear {
            if !coordinator.isScanning {
                coordinator.startScanning()
            }
        }
        .alert("Rename Device", isPresented: Binding(
            get: { renameDeviceID != nil },
            set: { if !$0 { renameDeviceID = nil } }
        )) {
            TextField("Device name", text: $renameText)
            Button("Cancel", role: .cancel) { renameDeviceID = nil }
            Button("Save") {
                if let id = renameDeviceID, !renameText.isEmpty {
                    coordinator.registry.updateDisplayName(id, name: renameText)
                }
                renameDeviceID = nil
            }
        }
        .alert("Forget Device?", isPresented: $showForgetConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Forget", role: .destructive) {
                if let id = forgetDeviceID {
                    coordinator.forget(id)
                }
            }
        } message: {
            Text("The device will need to be re-paired next time.")
        }
    }

    // MARK: - Row Views

    private func connectedRow(_ driver: any DeviceDriver) -> some View {
        HStack {
            Image(systemName: driver.descriptor.icon)
                .foregroundColor(.green)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(driver.displayName).font(.body)
                Text(driver.descriptor.displayName)
                    .font(.caption).foregroundColor(.gray)
            }
            Spacer()
            Circle().fill(.green).frame(width: 8, height: 8)
        }
        .swipeActions(edge: .trailing) {
            Button("Disconnect") {
                coordinator.disconnect(driver.id)
            }
            .tint(.orange)

            Button("Rename") {
                renameText = driver.displayName
                renameDeviceID = driver.id
            }
            .tint(.blue)
        }
    }

    private func knownRow(_ device: KnownDevice) -> some View {
        let desc = DeviceCoordinator.registeredDevices.first(where: { $0.id == device.descriptorID })
        return HStack {
            Image(systemName: desc?.icon ?? "questionmark.circle")
                .foregroundColor(.gray)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName).font(.body)
                Text(desc?.displayName ?? device.descriptorID)
                    .font(.caption).foregroundColor(.gray)
                Text("Last seen: \(device.lastSeen, style: .relative) ago")
                    .font(.caption2).foregroundColor(.gray.opacity(0.6))
            }
            Spacer()
            if device.autoConnect {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundColor(.gray)
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Forget", role: .destructive) {
                forgetDeviceID = device.id
                showForgetConfirm = true
            }

            Button("Rename") {
                renameText = device.displayName
                renameDeviceID = device.id
            }
            .tint(.blue)
        }
    }

    private func discoveredRow(_ device: DiscoveredDevice) -> some View {
        Button(action: {
            coordinator.pair(device)
        }) {
            HStack {
                Image(systemName: device.descriptor.icon)
                    .foregroundColor(.cyan)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.body)
                    Text(device.descriptor.displayName)
                        .font(.caption).foregroundColor(.gray)
                }
                Spacer()
                Text("RSSI \(device.rssi)")
                    .font(.caption2).foregroundColor(.gray)
                Image(systemName: "plus.circle.fill")
                    .foregroundColor(.cyan)
            }
        }
    }
}
