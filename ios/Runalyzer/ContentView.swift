import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject var coordinator: DeviceCoordinator
    @EnvironmentObject var appWiring: AppWiring
    @EnvironmentObject var measurementStore: MeasurementStore
    @EnvironmentObject var checkInProvider: CheckInProvider
    @State private var selectedTab = 0
    @State private var showMeasuring = false
    @State private var measureComplete = false
    @State private var spinRotation: Double = 0

    private var scale: QNScaleDriver? { coordinator.scaleDriver }

    var body: some View {
        Group {
            if !checkInProvider.morningCheckInDoneToday {
                MorningCheckInView()
            } else {
                TabView(selection: $selectedTab) {
                    HomeTab()
                        .tabItem { Label(String(localized: "tab.home"), systemImage: "house") }
                        .tag(0)

                    DataTab()
                        .tabItem { Label(String(localized: "tab.data"), systemImage: "cylinder.split.1x2") }
                        .tag(1)

                    SettingsView()
                        .tabItem { Label(String(localized: "tab.settings"), systemImage: "gearshape") }
                        .tag(2)
                }
                .overlay { if showMeasuring { scaleMeasurementOverlay } }
                .onChange(of: scale?.scaleState) { _, newState in
                    guard !measureComplete else { return }

                    switch newState {
                    case .measuring, .stable:
                        if !showMeasuring {
                            withAnimation { showMeasuring = true }
                        }
                    case .complete:
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        withAnimation { measureComplete = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            withAnimation { showMeasuring = false }
                            measureComplete = false
                            selectedTab = 1
                        }
                    case .idle, nil:
                        withAnimation { showMeasuring = false }
                    default:
                        break
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Scale Measurement Overlay

    private var scaleMeasurementOverlay: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()

            VStack(spacing: 20) {
                if measureComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 64))
                        .foregroundColor(.green)
                        .transition(.scale.combined(with: .opacity))
                    Text(String(localized: "measurement.complete.done"))
                        .font(.title2.bold())
                        .foregroundColor(.green)
                    if let w = appWiring.scaleProvider?.lastMeasurement?.weightKg {
                        Text(String(format: "%.2f kg", w))
                            .font(.title3.monospacedDigit())
                    }
                } else {
                    ZStack {
                        Circle()
                            .stroke(Color.gray.opacity(0.2), lineWidth: 6)
                            .frame(width: 80, height: 80)
                        Circle()
                            .trim(from: 0, to: scale?.isStable == true ? 0.85 : 0.25)
                            .stroke(
                                scale?.isStable == true ? Color(hex: 0x4ecca3) : Color.cyan,
                                style: StrokeStyle(lineWidth: 6, lineCap: .round)
                            )
                            .frame(width: 80, height: 80)
                            .rotationEffect(.degrees(spinRotation))
                            .animation(.linear(duration: scale?.isStable == true ? 2 : 1.5)
                                .repeatForever(autoreverses: false), value: spinRotation)
                    }
                    .onAppear { spinRotation = 360 }

                    Text(scale?.liveWeight ?? 0 > 0
                         ? String(format: "%.1f kg", scale?.liveWeight ?? 0)
                         : String(localized: "scale.measuring"))
                        .font(.title2.bold().monospacedDigit())

                    Text(scale?.isStable == true
                         ? String(localized: "scale.locking_in")
                         : String(localized: "scale.hold_still"))
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
            .frame(width: 240, height: 240)
            .background(.ultraThinMaterial)
            .cornerRadius(24)
            .shadow(radius: 20)
            .transition(.scale.combined(with: .opacity))
        }
    }
}
