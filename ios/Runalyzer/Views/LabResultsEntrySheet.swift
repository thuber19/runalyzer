import SwiftUI

/// Manual entry sheet for blood work / lab results.
/// Each biomarker is optional — user fills in whatever values they have from their lab report.
struct LabResultsEntrySheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var measurementStore: MeasurementStore

    @State private var date = Date()
    @State private var labName = ""

    // Lipid panel
    @State private var totalCholesterol = ""
    @State private var ldl = ""
    @State private var hdl = ""
    @State private var triglycerides = ""

    // Metabolic
    @State private var glucose = ""
    @State private var hemoglobinA1C = ""
    @State private var creatinine = ""

    // Iron & vitamins
    @State private var ferritin = ""
    @State private var iron = ""
    @State private var vitaminD = ""
    @State private var vitaminB12 = ""

    // Blood count
    @State private var hemoglobin = ""

    // Hormones & inflammation
    @State private var tsh = ""
    @State private var cortisol = ""
    @State private var testosterone = ""
    @State private var crp = ""

    private var hasAnyValue: Bool {
        [totalCholesterol, ldl, hdl, triglycerides, glucose, hemoglobinA1C,
         creatinine, ferritin, iron, vitaminD, vitaminB12, hemoglobin,
         tsh, cortisol, testosterone, crp].contains { !$0.isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Lab Info") {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    TextField("Lab / Provider (optional)", text: $labName)
                }

                Section("Lipid Panel") {
                    labField("Total Cholesterol", value: $totalCholesterol, unit: "mg/dL")
                    labField("LDL", value: $ldl, unit: "mg/dL")
                    labField("HDL", value: $hdl, unit: "mg/dL")
                    labField("Triglycerides", value: $triglycerides, unit: "mg/dL")
                }

                Section("Metabolic") {
                    labField("Glucose (fasting)", value: $glucose, unit: "mg/dL")
                    labField("HbA1C", value: $hemoglobinA1C, unit: "%")
                    labField("Creatinine", value: $creatinine, unit: "mg/dL")
                }

                Section("Iron & Vitamins") {
                    labField("Ferritin", value: $ferritin, unit: "ng/mL")
                    labField("Iron", value: $iron, unit: "mcg/dL")
                    labField("Vitamin D", value: $vitaminD, unit: "ng/mL")
                    labField("Vitamin B12", value: $vitaminB12, unit: "pg/mL")
                }

                Section("Blood Count") {
                    labField("Hemoglobin", value: $hemoglobin, unit: "g/dL")
                }

                Section("Hormones & Inflammation") {
                    labField("TSH", value: $tsh, unit: "mIU/L")
                    labField("Cortisol", value: $cortisol, unit: "mcg/dL")
                    labField("Testosterone", value: $testosterone, unit: "ng/dL")
                    labField("CRP", value: $crp, unit: "mg/L")
                }
            }
            .navigationTitle("Add Lab Results")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveResults() }
                        .disabled(!hasAnyValue)
                        .bold()
                }
            }
        }
    }

    // MARK: - Components

    private func labField(_ label: String, value: Binding<String>, unit: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(unit, text: value)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
            Text(unit)
                .font(.caption)
                .foregroundColor(.gray)
                .frame(width: 50, alignment: .leading)
        }
    }

    // MARK: - Save

    private func saveResults() {
        var dataPoints: [DataPoint] = []
        let ts = date
        let src = DataSource.device("lab-manual")

        func add(_ text: String, type: String, unit: String) {
            guard let v = Double(text.replacingOccurrences(of: ",", with: ".")) else { return }
            dataPoints.append(DataPoint(
                timestamp: ts, endTimestamp: nil,
                type: type, value: v, unit: unit,
                source: src, role: .primary
            ))
        }

        // Lipid panel
        add(totalCholesterol, type: DataType.totalCholesterol, unit: "mg/dL")
        add(ldl, type: DataType.ldlCholesterol, unit: "mg/dL")
        add(hdl, type: DataType.hdlCholesterol, unit: "mg/dL")
        add(triglycerides, type: DataType.triglycerides, unit: "mg/dL")

        // Metabolic
        add(glucose, type: DataType.glucose, unit: "mg/dL")
        add(hemoglobinA1C, type: DataType.hemoglobinA1C, unit: "%")
        add(creatinine, type: DataType.creatinine, unit: "mg/dL")

        // Iron & vitamins
        add(ferritin, type: DataType.ferritin, unit: "ng/mL")
        add(iron, type: DataType.iron, unit: "mcg/dL")
        add(vitaminD, type: DataType.vitaminD, unit: "ng/mL")
        add(vitaminB12, type: DataType.vitaminB12, unit: "pg/mL")

        // Blood count
        add(hemoglobin, type: DataType.hemoglobin, unit: "g/dL")

        // Hormones & inflammation
        add(tsh, type: DataType.tsh, unit: "mIU/L")
        add(cortisol, type: DataType.cortisol, unit: "mcg/dL")
        add(testosterone, type: DataType.testosterone, unit: "ng/dL")
        add(crp, type: DataType.crp, unit: "mg/L")

        guard !dataPoints.isEmpty else { return }

        let sourceName = labName.isEmpty ? "Lab Results" : labName
        let source = MeasurementSource.device(type: "lab_test", name: sourceName, serial: nil)

        let measurement = SensorMeasurement(
            id: UUID(), date: date, type: .labResults,
            sources: [source], dataPoints: dataPoints, rawDataFiles: []
        )

        _ = measurementStore.save(measurement)
        dismiss()
    }
}
