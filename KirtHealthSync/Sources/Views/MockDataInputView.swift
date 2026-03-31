import SwiftUI
import FirebaseFirestore

#if DEBUG
/// Debug-only mock data injection UI.
/// Allows manual injection of test metric values directly into Firestore
/// at the kirt/daily/daily/{date} path with source: "MOCK_DATA".
/// Excluded from release builds via #if DEBUG.
struct MockDataInputView: View {
    @Environment(\.dismiss) private var dismiss

    // Metric selection
    @State private var selectedMetric: MockMetric = .steps

    // Values per metric
    @State private var stepsValue: String = "8420"
    @State private var sleepMinutes: String = "420"
    @State private var weightKg: String = "82.5"
    @State private var heartRateBpm: String = "58"
    @State private var caloriesKcal: String = "2150"
    @State private var proteinG: String = "148"
    @State private var carbsG: String = "215"
    @State private var fatG: String = "72"

    // Workout fields
    @State private var workoutType: String = "Cycling"
    @State private var workoutDuration: String = "45"
    @State private var workoutCalories: String = "320"

    // Firestore write state
    @State private var isInjecting: Bool = false
    @State private var injectMessage: String = ""
    @State private var injectSuccess: Bool = false

    enum MockMetric: String, CaseIterable, Identifiable {
        case steps = "Steps"
        case sleep = "Sleep"
        case weight = "Weight"
        case heartRate = "Heart Rate"
        case calories = "Calories"
        case workouts = "Workouts"
        case nutrition = "Nutrition"

        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Metric")) {
                    Picker("Metric", selection: $selectedMetric) {
                        ForEach(MockMetric.allCases) { metric in
                            Text(metric.rawValue).tag(metric)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section(header: Text("Value")) {
                    switch selectedMetric {
                    case .steps:
                        TextField("Steps count", text: $stepsValue)
                            .keyboardType(.numberPad)
                    case .sleep:
                        TextField("Sleep minutes", text: $sleepMinutes)
                            .keyboardType(.numberPad)
                    case .weight:
                        TextField("Weight (kg)", text: $weightKg)
                            .keyboardType(.decimalPad)
                    case .heartRate:
                        TextField("Heart rate (bpm)", text: $heartRateBpm)
                            .keyboardType(.numberPad)
                    case .calories:
                        TextField("Calories (kcal)", text: $caloriesKcal)
                            .keyboardType(.numberPad)
                    case .workouts:
                        TextField("Workout type", text: $workoutType)
                        TextField("Duration (min)", text: $workoutDuration)
                            .keyboardType(.numberPad)
                        TextField("Calories burned", text: $workoutCalories)
                            .keyboardType(.numberPad)
                    case .nutrition:
                        TextField("Protein (g)", text: $proteinG)
                            .keyboardType(.decimalPad)
                        TextField("Carbs (g)", text: $carbsG)
                            .keyboardType(.decimalPad)
                        TextField("Fat (g)", text: $fatG)
                            .keyboardType(.decimalPad)
                    }
                }

                Section {
                    Button(action: injectData) {
                        HStack {
                            Text("Inject to Firestore")
                            Spacer()
                            if isInjecting {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isInjecting)
                    .foregroundColor(.blue)

                    if !injectMessage.isEmpty {
                        Text(injectMessage)
                            .foregroundColor(injectSuccess ? .green : .red)
                            .font(.caption)
                    }
                } header: {
                    Text("Action")
                } footer: {
                    Text("Writes to kirt/daily/daily/{today} with source: MOCK_DATA")
                }

                Section(header: Text("Current Mock Data (in-memory only)")) {
                    Text("Tap 'Load Mock Data' in the main screen to preview values in the UI without writing to Firestore.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Inject Mock Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func injectData() {
        isInjecting = true
        injectMessage = ""
        injectSuccess = false

        let today = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let todayStr = String(today)

        // Build Firestore document
        var document: [String: Any] = [
            "date": todayStr,
            "source": "MOCK_DATA",
            "syncedAt": FieldValue.serverTimestamp(),
        ]

        switch selectedMetric {
        case .steps:
            document["metrics"] = [
                "steps": ["total": Double(stepsValue) ?? 0, "unit": "count"]
            ]
        case .sleep:
            document["metrics"] = [
                "sleep": ["totalMinutes": Double(sleepMinutes) ?? 0, "unit": "min"]
            ]
        case .weight:
            document["metrics"] = [
                "weight": ["latest": Double(weightKg) ?? 0, "unit": "kg"]
            ]
        case .heartRate:
            document["metrics"] = [
                "heartRate": ["latest": Double(heartRateBpm) ?? 0, "unit": "count/min"]
            ]
        case .calories:
            document["metrics"] = [
                "nutrition": ["total": Double(caloriesKcal) ?? 0, "unit": "kcal"]
            ]
        case .workouts:
            let duration = Double(workoutDuration) ?? 0
            let cal = Double(workoutCalories) ?? 0
            document["metrics"] = [
                "workouts": [
                    [
                        "type": workoutType,
                        "duration": duration,
                        "energyBurned": cal,
                        "startDate": ISO8601DateFormatter().string(from: Date()),
                        "endDate": ISO8601DateFormatter().string(from: Date().addingTimeInterval(duration * 60)),
                    ]
                ]
            ]
        case .nutrition:
            document["metrics"] = [
                "nutrition": [
                    "protein": ["total": Double(proteinG) ?? 0, "unit": "g"],
                    "carbs": ["total": Double(carbsG) ?? 0, "unit": "g"],
                    "fat": ["total": Double(fatG) ?? 0, "unit": "g"],
                ]
            ]
        }

        // Write to kirt/daily/daily/{today}
        let db = Firestore.firestore()
        db.collection("kirt").document("daily").collection("daily").document(todayStr).setData(document, merge: true) { error in
            DispatchQueue.main.async {
                isInjecting = false
                if let error = error {
                    injectMessage = "Error: \(error.localizedDescription)"
                    injectSuccess = false
                } else {
                    injectMessage = "Injected \(selectedMetric.rawValue) = \(getValueString()) → kirt/daily/daily/\(todayStr)"
                    injectSuccess = true
                }
            }
        }
    }

    private func getValueString() -> String {
        switch selectedMetric {
        case .steps: return stepsValue
        case .sleep: return sleepMinutes
        case .weight: return weightKg
        case .heartRate: return heartRateBpm
        case .calories: return caloriesKcal
        case .workouts: return "\(workoutType) \(workoutDuration)min"
        case .nutrition: return "P:\(proteinG)g C:\(carbsG)g F:\(fatG)g"
        }
    }
}
#endif
