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

                HStack {
                    Text("Age")
                    Spacer()
                    TextField("years", value: $profile.age, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                    Text("years").foregroundColor(.gray)
                }

                Picker("Sex", selection: $profile.sex) {
                    ForEach(UserProfile.Sex.allCases, id: \.self) { sex in
                        Text(sex.label).tag(sex)
                    }
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
            } footer: {
                Text("These values are used to calculate body fat, muscle mass, and other metrics from the scale's impedance measurement.")
            }
        }
        .navigationTitle("Body Profile")
    }
}
