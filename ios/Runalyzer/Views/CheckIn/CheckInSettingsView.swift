import SwiftUI

/// Settings for check-in reminders and hydration goal.
struct CheckInSettingsView: View {
    @EnvironmentObject var checkInProvider: CheckInProvider

    @AppStorage("checkin_morning_enabled") private var morningEnabled = true
    @AppStorage("checkin_morning_hour") private var morningHour = 7
    @AppStorage("checkin_morning_minute") private var morningMinute = 0
    @AppStorage("checkin_evening_enabled") private var eveningEnabled = false
    @AppStorage("checkin_evening_hour") private var eveningHour = 20
    @AppStorage("checkin_evening_minute") private var eveningMinute = 0
    @AppStorage("hydration_goal_ml") private var hydrationGoal = 2500

    private var morningTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(from: DateComponents(hour: morningHour, minute: morningMinute)) ?? Date()
            },
            set: { newDate in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                morningHour = comps.hour ?? 7
                morningMinute = comps.minute ?? 0
                checkInProvider.updateScheduledNotifications()
            }
        )
    }

    private var eveningTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(from: DateComponents(hour: eveningHour, minute: eveningMinute)) ?? Date()
            },
            set: { newDate in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                eveningHour = comps.hour ?? 20
                eveningMinute = comps.minute ?? 0
                checkInProvider.updateScheduledNotifications()
            }
        )
    }

    var body: some View {
        Form {
            Section("Morning Check-in") {
                Toggle("Reminder", isOn: $morningEnabled)
                    .onChange(of: morningEnabled) { _, _ in
                        checkInProvider.updateScheduledNotifications()
                    }
                if morningEnabled {
                    DatePicker("Time", selection: morningTime, displayedComponents: .hourAndMinute)
                }
            }

            Section("Evening Check-in") {
                Toggle("Reminder", isOn: $eveningEnabled)
                    .onChange(of: eveningEnabled) { _, _ in
                        checkInProvider.updateScheduledNotifications()
                    }
                if eveningEnabled {
                    DatePicker("Time", selection: eveningTime, displayedComponents: .hourAndMinute)
                }
            }

            Section("Hydration") {
                Stepper("Daily Goal: \(hydrationGoal) mL", value: $hydrationGoal, in: 500...5000, step: 250)
            }
        }
        .navigationTitle("Check-in Settings")
    }
}
