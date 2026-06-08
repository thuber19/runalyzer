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

            Section {
                // Max HR
                HStack {
                    Text("Max HR")
                    Spacer()
                    OptionalIntField(placeholder: "\(220 - profile.age)", value: $profile.maxHROverride)
                        .frame(width: 60)
                    Text("bpm").foregroundColor(.gray)
                }
                .listRowBackground(Color(hex: 0x16213e))
                if profile.maxHROverride == nil {
                    Text("Default: 220 − \(profile.age) = \(220 - profile.age) bpm")
                        .font(.caption2).foregroundColor(.gray)
                        .listRowBackground(Color(hex: 0x16213e))
                }

                // Zone boundaries (auto-calculated, overridable)
                let mhr = profile.maxHR
                let lowers = profile.hrZoneLowerBounds
                zoneRow("Zone 1 · Very Light", range: "\(lowers[0])–", value: $profile.hrZone1Max,
                        defaultValue: Int(Double(mhr) * 0.6), pct: "50–60%")
                zoneRow("Zone 2 · Light", range: "\(lowers[1])–", value: $profile.hrZone2Max,
                        defaultValue: Int(Double(mhr) * 0.7), pct: "60–70%")
                zoneRow("Zone 3 · Moderate", range: "\(lowers[2])–", value: $profile.hrZone3Max,
                        defaultValue: Int(Double(mhr) * 0.8), pct: "70–80%")
                zoneRow("Zone 4 · Hard", range: "\(lowers[3])–", value: $profile.hrZone4Max,
                        defaultValue: Int(Double(mhr) * 0.9), pct: "80–90%")
                HStack {
                    Text("Zone 5 · Maximum").font(.subheadline)
                    Spacer()
                    Text("\(lowers[4])–\(mhr) bpm").foregroundColor(.gray)
                    Text("90–100%").font(.caption2).foregroundColor(.gray)
                }
                .listRowBackground(Color(hex: 0x16213e))
            } header: {
                Text("Heart Rate Zones")
            } footer: {
                Text("Based on ACSM Guidelines for Exercise Testing and Prescription (11th ed., 2021). Zones are percentages of max HR. Override individual zone boundaries or leave blank for defaults.")
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

    private func zoneRow(_ label: String, range: String, value: Binding<Int?>, defaultValue: Int, pct: String) -> some View {
        HStack {
            Text(label).font(.subheadline)
            Spacer()
            Text(range).font(.caption).foregroundColor(.gray)
            OptionalIntField(placeholder: "\(defaultValue)", value: value)
                .frame(width: 50)
            Text("bpm").font(.caption2).foregroundColor(.gray)
            Text(pct).font(.caption2).foregroundColor(.gray).frame(width: 50)
        }
        .listRowBackground(Color(hex: 0x16213e))
    }
}

/// TextField that properly handles Optional<Int> — empty field = nil.
private struct OptionalIntField: View {
    let placeholder: String
    @Binding var value: Int?
    @State private var text: String = ""

    var body: some View {
        TextField(placeholder, text: $text)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .onAppear { text = value.map(String.init) ?? "" }
            .onChange(of: text) { _, newText in
                if newText.isEmpty {
                    value = nil
                } else if let n = Int(newText) {
                    value = n
                }
            }
    }
}
