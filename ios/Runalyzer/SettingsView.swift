import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var coordinator: DeviceCoordinator

    var body: some View {
        NavigationStack {
            List {
                // Devices
                Section("Devices") {
                    NavigationLink(destination: DeviceListView()) {
                        Label("Manage Devices", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }

                // User Profile (for body composition)
                Section("Profile") {
                    NavigationLink(destination: ScaleSettingsView()) {
                        Label("Body Profile", systemImage: "person.fill")
                    }
                }

                // Science
                Section("Science") {
                    NavigationLink(destination: AlgorithmsView()) {
                        Label("Algorithms & References", systemImage: "function")
                    }
                }

                // About
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0").foregroundColor(.gray)
                    }
                    HStack {
                        Text("Devices supported")
                        Spacer()
                        Text("IMU Sensor, QN Scale").foregroundColor(.gray)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
