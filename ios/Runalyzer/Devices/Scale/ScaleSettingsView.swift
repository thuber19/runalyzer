import SwiftUI

struct ScaleSettingsView: View {
    @State private var profile = UserProfile.load()
    @State private var saved = false

    var body: some View {
        Form {
            Section("Body Measurements") {
                HStack {
                    Text("Height")
                    Spacer()
                    TextField("cm", value: $profile.heightCm, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                    Text("cm").foregroundColor(.gray)
                }
                .listRowBackground(Color(hex: 0x16213e))

                HStack {
                    Text("Age")
                    Spacer()
                    TextField("years", value: $profile.age, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                    Text("years").foregroundColor(.gray)
                }
                .listRowBackground(Color(hex: 0x16213e))

                Picker("Sex", selection: $profile.sex) {
                    ForEach(UserProfile.Sex.allCases, id: \.self) { sex in
                        Text(sex.label).tag(sex)
                    }
                }
                .listRowBackground(Color(hex: 0x16213e))
            }

            Section("Heart Rate Zones") {
                let defaults = defaultZones
                hrZoneRow("Zone 1 max", value: $profile.hrZone1Max, defaultValue: defaults[0])
                hrZoneRow("Zone 2 max", value: $profile.hrZone2Max, defaultValue: defaults[1])
                hrZoneRow("Zone 3 max", value: $profile.hrZone3Max, defaultValue: defaults[2])
                hrZoneRow("Zone 4 max", value: $profile.hrZone4Max, defaultValue: defaults[3])
                HStack {
                    Text("Max HR")
                    Spacer()
                    TextField("\(220 - profile.age)", value: $profile.maxHROverride, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                    Text("bpm").foregroundColor(.gray)
                }
                .listRowBackground(Color(hex: 0x16213e))
                if profile.maxHROverride == nil {
                    Text("Default: 220 − \(profile.age) = \(220 - profile.age) bpm")
                        .font(.caption2).foregroundColor(.gray)
                        .listRowBackground(Color(hex: 0x16213e))
                }
            }

            Section {
                Button(action: {
                    profile.save()
                    saved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
                }) {
                    HStack {
                        Text("Save Profile")
                        Spacer()
                        if saved {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        }
                    }
                }
                .listRowBackground(Color(hex: 0x16213e))
            } footer: {
                Text("Body measurements are used for body composition. HR zones default to standard percentages of 220 − age and can be customized.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(hex: 0x1a1a2e))
        .navigationTitle("Body Profile")
    }

    /// Default zone boundaries based on current age
    private var defaultZones: [Int] {
        let mhr = Double(profile.maxHR)
        return [Int(mhr * 0.6), Int(mhr * 0.7), Int(mhr * 0.8), Int(mhr * 0.9)]
    }

    private func hrZoneRow(_ label: String, value: Binding<Int?>, defaultValue: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("\(defaultValue)", value: value, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 60)
            Text("bpm").foregroundColor(.gray)
        }
        .listRowBackground(Color(hex: 0x16213e))
    }
}
