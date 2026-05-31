import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            LiveDashboardView()
                .tabItem {
                    Label("Live", systemImage: "waveform.path.ecg")
                }

            SessionListView()
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }

            HealthView()
                .tabItem {
                    Label("Health", systemImage: "heart.fill")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
        .preferredColorScheme(.dark)
    }
}
