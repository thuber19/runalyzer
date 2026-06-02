import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            RunalyzerTab()
                .tabItem {
                    Label("Runalyzer", systemImage: "waveform.path.ecg")
                }

            BodyTab()
                .tabItem {
                    Label("Body", systemImage: "scalemass")
                }

            DataTab()
                .tabItem {
                    Label("Data", systemImage: "cylinder.split.1x2")
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
