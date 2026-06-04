import SwiftUI

struct AlgorithmsView: View {
    var body: some View {
        List {
            Section {
                Text("Runalyzer uses published scientific equations to derive health metrics from raw sensor data. Below are the algorithms, their sources, and what they calculate.")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .listRowBackground(Color(hex: 0x16213e))
            }

            // Body Composition
            Section("Body Composition (from Scale)") {
                AlgorithmCard(
                    name: "Fat-Free Mass (FFM)",
                    id: "sun_et_al_2003",
                    inputs: "Weight (kg), Impedance (Ω), Height (cm), Age, Sex",
                    output: "Fat-free mass (kg), Body fat %, Fat mass (kg)",
                    method: """
                    Uses bioelectrical impedance analysis (BIA) with the resistance index (height²/impedance) \
                    to estimate fat-free mass. Body fat is derived as weight minus FFM.

                    Male: FFM = -10.68 + 0.65 × (ht²/R) + 0.26 × wt + 0.02 × R
                    Female: FFM = -9.53 + 0.69 × (ht²/R) + 0.17 × wt + 0.02 × R
                    """,
                    citation: "Sun SS, Chumlea WC, Heymsfield SB, et al. Development of bioelectrical impedance analysis prediction equations for body composition with the use of a multicomponent model for use in epidemiologic surveys.",
                    journal: "Am J Clin Nutr. 2003;77(2):331-340"
                )

                AlgorithmCard(
                    name: "Total Body Water (TBW)",
                    id: "sun_et_al_2003_tbw",
                    inputs: "Weight (kg), Impedance (Ω), Height (cm), Sex",
                    output: "Body water %",
                    method: """
                    Companion equation to the FFM model, estimates total body water from the same BIA measurements.

                    Male: TBW = 1.20 + 0.45 × (ht²/R) + 0.18 × wt
                    Female: TBW = 3.75 + 0.45 × (ht²/R) + 0.11 × wt
                    """,
                    citation: "Sun SS, Chumlea WC, Heymsfield SB, et al.",
                    journal: "Am J Clin Nutr. 2003;77(2):331-340"
                )

                AlgorithmCard(
                    name: "Skeletal Muscle Mass (SMM)",
                    id: "janssen_et_al_2000",
                    inputs: "Impedance (Ω), Height (cm), Age, Sex",
                    output: "Muscle mass (kg), Muscle %",
                    method: """
                    Estimates appendicular skeletal muscle mass using the resistance index, \
                    adjusted for age and sex.

                    SMM = 0.401 × (ht²/R) + 3.825 × sex - 0.071 × age + 5.102
                    (sex: male = 1, female = 0)
                    """,
                    citation: "Janssen I, Heymsfield SB, Baumgartner RN, Ross R. Estimation of skeletal muscle mass by bioelectrical impedance analysis.",
                    journal: "J Appl Physiol. 2000;89(2):465-471"
                )

                AlgorithmCard(
                    name: "Basal Metabolic Rate (BMR)",
                    id: "mifflin_st_jeor_1990",
                    inputs: "Weight (kg), Height (cm), Age, Sex",
                    output: "BMR (kcal/day)",
                    method: """
                    Estimates resting energy expenditure. Does not require impedance — \
                    uses anthropometric data only. Widely considered the most accurate \
                    predictive BMR equation for healthy adults.

                    Male: BMR = 10 × wt + 6.25 × ht - 5 × age + 5
                    Female: BMR = 10 × wt + 6.25 × ht - 5 × age - 161
                    """,
                    citation: "Mifflin MD, St Jeor ST, Hill LA, Scott BJ, Daugherty SA, Koh YO. A new predictive equation for resting energy expenditure in healthy individuals.",
                    journal: "Am J Clin Nutr. 1990;51(2):241-247"
                )

                AlgorithmCard(
                    name: "Body Mass Index (BMI)",
                    id: "bmi_standard",
                    inputs: "Weight (kg), Height (cm)",
                    output: "BMI (kg/m²)",
                    method: "BMI = weight / (height in meters)²\n\nStandard WHO formula. No impedance required.",
                    citation: "World Health Organization. Body mass index classification.",
                    journal: "WHO Technical Report Series, No. 894"
                )
            }

            // Running Enrichment
            Section("Running Analysis (IMU + Apple Watch)") {
                AlgorithmCard(
                    name: "Session Enrichment",
                    id: "session_enrichment_v1",
                    inputs: "IMU session (cadence, steps, duration) + Apple Watch workout (HR, distance, calories)",
                    output: "Pace (min/km), Step length (m), Running economy (beats/km), Aerobic load (AU)",
                    method: """
                    Combines IMU and Watch data into a unified session record.

                    Pace = duration_min / distance_km
                    Step length = (distance_km × 1000) / total_steps
                    Running economy = avg_HR × pace  (beats/km — lower is more aerobically efficient)
                    Aerobic load = avg_HR × duration_min  (simple training stress proxy)
                    """,
                    citation: "Running economy concept adapted from standard exercise physiology literature.",
                    journal: "Fletcher JR, et al. Running economy from a muscle energetics perspective. Front Physiol. 2017;8:433"
                )
            }

            // Daytime Stress
            Section("Daytime Stress (from Apple Watch)") {
                AlgorithmCard(
                    name: "Daytime Stress Index",
                    id: "daytime_stress_v1",
                    inputs: "Daytime HRV (SDNN, 06:00–23:00), Apple Watch resting HR",
                    output: "Stress index 0–100 (higher = more stressed), plus HRV and RHR sub-components",
                    method: """
                    Each signal is compared against a personal 30-day rolling baseline. \
                    Scores reflect YOUR deviation from YOUR norm — not population averages.

                    HRV component (60% weight):
                      deviation = (baseline_SDNN − day_SDNN) / baseline_SDNN
                      score = clamp((deviation + 0.30) / 0.60 × 100, 0, 100)
                      Maps: SDNN 30% above baseline → 0, SDNN 30% below baseline → 100

                    RHR component (40% weight):
                      deviation = (day_RHR − baseline_RHR) / baseline_RHR
                      score = clamp((deviation + 0.10) / 0.20 × 100, 0, 100)
                      Maps: RHR 10% below baseline → 0, RHR 10% above baseline → 100

                    Data sourced from Apple Watch passive background HRV measurements (every ~2h \
                    during sedentary rest) and Apple Watch nightly resting HR computation. \
                    Workouts and sleep are automatically excluded by the time window filter and \
                    because Apple Watch does not record background HRV during active workouts.

                    Minimum 5 baseline days required for meaningful scoring. \
                    Confidence reported as a separate data point.
                    """,
                    citation: "Zanetti S et al. Assessing Garmin Stress Level Score Against Heart Rate Variability Measurements. Stress and Health. 2025. | Cosoli G et al. Wearable Derived Cardiovascular Responses to Stressors. PMC 2023.",
                    journal: "MDPI Sensors 2022;22(1):151 | Stress and Health 2025 | PMC10237460"
                )
            }

            // IMU Analysis
            Section("Gait Analysis (from IMU Sensor)") {
                AlgorithmCard(
                    name: "Step Detection",
                    id: "step_detection_v1",
                    inputs: "6-axis IMU data (accelerometer + gyroscope)",
                    output: "Step timestamps, Total steps, Cadence (spm)",
                    method: """
                    1. Compute acceleration magnitude (orientation-independent)
                    2. Remove gravity (subtract 1g baseline)
                    3. Low-pass filter (EMA, α=0.1, ~1.6Hz cutoff at 100Hz)
                    4. Dynamic threshold from signal standard deviation (0.6 × σ)
                    5. Peak detection with minimum 250ms interval between steps
                    6. Cadence calculated in 10-second sliding windows
                    """,
                    citation: "Custom implementation based on standard accelerometer-based step detection literature.",
                    journal: "Inspired by Zhao N. Full-featured pedometer design realized with 3-axis digital accelerometer. Analog Dialogue. 2010;44(6)"
                )

                AlgorithmCard(
                    name: "Left/Right Foot Classification",
                    id: "side_detection_v1",
                    inputs: "Gyroscope data at detected step peaks",
                    output: "Side A / Side B classification per step",
                    method: """
                    1. Find the gyroscope axis with highest variance (dominant pelvic rotation axis)
                    2. Low-pass filter the dominant axis
                    3. At each detected step, average the filtered gyro over a ±10 sample window
                    4. Positive average → Side A, Negative → Side B

                    The sensor orientation is arbitrary, so sides are labeled A/B rather than left/right. \
                    A calibration step ("start with right foot") maps A/B to actual feet.
                    """,
                    citation: "Based on pelvic rotation patterns during gait.",
                    journal: "Kavanagh JJ, Menz HB. Accelerometry: a technique for quantifying movement patterns during walking. Gait Posture. 2008;28(1):1-15"
                )
            }

            // Disclaimer
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Important", systemImage: "exclamationmark.triangle")
                        .font(.subheadline.bold())
                        .foregroundColor(.orange)
                    Text("""
                    Body composition values are estimates derived from published BIA equations. \
                    These equations were developed from hand-to-foot impedance measurements in specific study populations. \
                    Foot-to-foot scales (like the QN-Scale) may produce different absolute values. \
                    Use these numbers to track trends over time, not as absolute clinical measurements.

                    Step detection accuracy depends on sensor placement and activity type. \
                    The algorithm is tuned for walking and running with the sensor at the hip/tailbone.
                    """)
                    .font(.caption)
                    .foregroundColor(.gray)
                }
                .listRowBackground(Color(hex: 0x16213e))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(hex: 0x1a1a2e))
        .navigationTitle("Algorithms")
    }
}

// MARK: - Algorithm Card

struct AlgorithmCard: View {
    let name: String
    let id: String
    let inputs: String
    let output: String
    let method: String
    let citation: String
    let journal: String

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { withAnimation { expanded.toggle() } }) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.subheadline.bold())
                        Text(id).font(.caption2).foregroundColor(.cyan)
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.gray)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    Group {
                        Text("Inputs").font(.caption.bold()).foregroundColor(.gray)
                        Text(inputs).font(.caption)
                    }
                    Group {
                        Text("Output").font(.caption.bold()).foregroundColor(.gray)
                        Text(output).font(.caption)
                    }
                    Group {
                        Text("Method").font(.caption.bold()).foregroundColor(.gray)
                        Text(method).font(.caption).foregroundColor(.secondary)
                    }
                    Divider()
                    Group {
                        Text("Reference").font(.caption.bold()).foregroundColor(.gray)
                        Text(citation).font(.caption2).italic()
                        Text(journal).font(.caption2).foregroundColor(.cyan)
                    }
                }
                .padding(.top, 4)
            }
        }
        .listRowBackground(Color(hex: 0x16213e))
    }
}
