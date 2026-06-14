import SwiftUI

@main
struct RunalyzerWatchApp: App {
    @StateObject private var sessionStore = WatchSessionStore()
    @StateObject private var workoutManager = WorkoutManager()
    @StateObject private var syncManager = WatchSyncManager()

    var body: some Scene {
        WindowGroup {
            SessionStartView()
                .environmentObject(sessionStore)
                .environmentObject(workoutManager)
                .environmentObject(syncManager)
        }
    }
}
