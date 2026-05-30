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
        }
        .preferredColorScheme(.dark)
    }
}
