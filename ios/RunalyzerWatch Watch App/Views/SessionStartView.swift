import SwiftUI

/// Root view: start a new wellness session or see recent sessions.
struct SessionStartView: View {
    @EnvironmentObject var sessionStore: WatchSessionStore
    @EnvironmentObject var workoutManager: WorkoutManager
    @EnvironmentObject var syncManager: WatchSyncManager

    @State private var activeSession: WellnessSession?
    @State private var navigationPath = NavigationPath()
    @State private var lastRoundEndDate: Date?
    enum Destination: Hashable {
        case pickRound
        case activeRound
        case summary
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                VStack(spacing: 12) {
                    // HealthKit auth warning
                    if workoutManager.authorizationDenied {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                            Text("Health access required. Open Settings → Health → Runalyzer.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.15)))
                    }

                    // Start button
                    Button {
                        startSession()
                    } label: {
                        Label("Start Wellness", systemImage: "flame.fill")
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)

                    // Recent sessions
                    if !sessionStore.sessions.isEmpty {
                        Section {
                            ForEach(sessionStore.sessions.prefix(5)) { session in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.date, style: .date)
                                            .font(.caption)
                                        Text("\(session.rounds.count) rounds · \(formatDuration(session.totalDurationSec))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if !session.synced {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                        } header: {
                            Text("Recent")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            .navigationTitle("Wellness")
            .navigationDestination(for: Destination.self) { dest in
                switch dest {
                case .pickRound:
                    RoundTypePickerView(
                        restStartDate: lastRoundEndDate,
                        onEndSession: { endSession() }
                    ) { type in
                        startRound(type: type)
                    }
                case .activeRound:
                    if let round = activeSession?.activeRound,
                       let session = activeSession {
                        ActiveRoundView(
                            round: round,
                            roundNumber: session.rounds.count
                        ) {
                            stopRound()
                        }
                    }
                case .summary:
                    if let session = activeSession {
                        SessionSummaryView(session: session) {
                            finishSession()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Session Lifecycle

    private func startSession() {
        activeSession = WellnessSession()
        lastRoundEndDate = nil
        workoutManager.start()
        navigationPath.append(Destination.pickRound)
    }

    private func startRound(type: WellnessRoundType) {
        activeSession?.startRound(type: type)
        lastRoundEndDate = nil
        workoutManager.enableWaterLock()
        var path = NavigationPath()
        path.append(Destination.activeRound)
        navigationPath = path
    }

    private func stopRound() {
        activeSession?.stopCurrentRound()
        lastRoundEndDate = Date()
        var path = NavigationPath()
        path.append(Destination.pickRound)
        navigationPath = path
    }

    private func endSession() {
        guard var session = activeSession else { return }
        session.stopCurrentRound()
        activeSession = session
        lastRoundEndDate = nil
        sessionStore.save(session)
        syncManager.syncSession(session)
        workoutManager.stop()
        var path = NavigationPath()
        path.append(Destination.summary)
        navigationPath = path
    }

    private func finishSession() {
        activeSession = nil
        lastRoundEndDate = nil
        navigationPath = NavigationPath()
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}
