import SwiftUI
import FirebaseFirestore

struct ContentView: View {
    @StateObject private var viewModel = HealthDataViewModel()

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Today's Summary")) {
                    HStack { Text("Steps"); Spacer(); Text("\(viewModel.todaySteps)").foregroundColor(.secondary) }
                    HStack { Text("Sleep"); Spacer(); Text("\(viewModel.todaySleepMinutes) min").foregroundColor(.secondary) }
                    HStack { Text("Weight"); Spacer(); Text(String(format: "%.1f kg", viewModel.latestWeight)).foregroundColor(.secondary) }
                    HStack { Text("Resting HR"); Spacer(); Text("\(viewModel.latestRestingHR) bpm").foregroundColor(.secondary) }
                }

                Section(header: Text("Nutrition")) {
                    HStack { Text("Calories"); Spacer(); Text(String(format: "%.0f kcal", viewModel.nutritionData.calories)).foregroundColor(.secondary) }
                    HStack { Text("Protein"); Spacer(); Text(String(format: "%.1f g", viewModel.nutritionData.protein)).foregroundColor(.secondary) }
                    HStack { Text("Carbs"); Spacer(); Text(String(format: "%.1f g", viewModel.nutritionData.carbs)).foregroundColor(.secondary) }
                    HStack { Text("Fat"); Spacer(); Text(String(format: "%.1f g", viewModel.nutritionData.fat)).foregroundColor(.secondary) }
                }

                Section(header: Text("Debug")) {
                    Text(viewModel.lastSyncTime)
                        .foregroundColor(.secondary)
                    HStack {
                        Button("Reset Anchors") {
                            HealthKitManager.shared.resetAllAnchors()
                        }
                        .foregroundColor(.orange)
                        Button("Mock Direct") {
                            viewModel.addMockDataDirectToFirestore()
                        }
                        .foregroundColor(.purple)
                        .disabled(viewModel.isLoading)
                        Spacer()
                        Button("Sync Now") {
                            viewModel.syncNow()
                        }
                        .disabled(viewModel.isLoading)
                    }
                }

                Section(header: Text("Recent Workouts")) {
                    if viewModel.recentWorkouts.isEmpty {
                        Text("No workouts logged")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(viewModel.recentWorkouts) { workout in
                            VStack(alignment: .leading) {
                                Text(workout.activityType)
                                    .font(.headline)
                                Text("\(Int(workout.duration)) min • \(Int(workout.energyBurned)) kcal")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Kirt Health Sync")
            .onAppear {
                viewModel.loadData()
            }
        }
    }
}

@MainActor
class HealthDataViewModel: ObservableObject {
    @Published var todaySteps: Int = 0
    @Published var todaySleepMinutes: Int = 0
    @Published var latestWeight: Double = 0
    @Published var latestRestingHR: Int = 0
    @Published var lastSyncTime: String = "Never"
    @Published var recentWorkouts: [WorkoutItem] = []
    @Published var nutritionData: NutritionData = NutritionData()
    @Published var isLoading: Bool = false

    private let db = Firestore.firestore()

    private var todayPath: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        return "kirt/daily/daily/\(today)"
    }

    func loadData() {
        db.document(todayPath).getDocument { [weak self] snapshot, error in
            guard let self = self, let doc = snapshot, doc.exists else {
                Task { @MainActor in self?.lastSyncTime = "No data yet" }
                return
            }

            guard let data = doc.data() else { return }
            let metrics = data["metrics"] as? [String: Any] ?? [:]

            Task { @MainActor in
                if let steps = metrics["steps"] as? [String: Any], let total = steps["total"] as? Int {
                    self.todaySteps = total
                }
                if let sleep = metrics["sleep"] as? [String: Any], let total = sleep["totalMinutes"] as? Int {
                    self.todaySleepMinutes = total
                }
                if let weight = metrics["weight"] as? [String: Any], let value = weight["value"] as? Double {
                    self.latestWeight = value
                }
                if let hr = metrics["restingHeartRate"] as? [String: Any], let value = hr["resting"] as? Int {
                    self.latestRestingHR = value
                }
                if let nutrition = metrics["nutrition"] as? [String: Any] {
                    self.nutritionData = NutritionData(
                        calories: nutrition["energy"] as? Double ?? 0,
                        protein: nutrition["protein"] as? Double ?? 0,
                        carbs: nutrition["carbs"] as? Double ?? 0,
                        fat: nutrition["fat"] as? Double ?? 0
                    )
                }
                if let workouts = metrics["workouts"] as? [[String: Any]] {
                    for w in workouts {
                        if let activity = w["type"] as? String,
                           let duration = w["duration"] as? Double,
                           let calories = w["calories"] as? Double {
                            self.recentWorkouts.append(WorkoutItem(activityType: activity, duration: duration, energyBurned: calories))
                        }
                    }
                }

                let formatter = DateFormatter()
                formatter.dateStyle = .short
                formatter.timeStyle = .short
                self.lastSyncTime = formatter.string(from: Date())
            }
        }
    }

    func syncNow() {
        isLoading = true
        HealthKitManager.shared.syncHealthData { [weak self] _ in
            Task { @MainActor in
                self?.isLoading = false
                self?.recentWorkouts.removeAll()
                self?.loadData()
            }
        }
    }

    func addMockData() {
        isLoading = true
        HealthKitManager.shared.writeDebugMockData { [weak self] success, error in
            Task { @MainActor in
                self?.isLoading = false
                if success {
                    self?.lastSyncTime = "Mock data added — tap Sync Now"
                } else {
                    self?.lastSyncTime = "Mock data failed: \(error?.localizedDescription ?? "unknown")"
                }
            }
        }
    }

    /// Writes mock data directly to Firestore (bypasses HK for UITest).
    func addMockDataDirectToFirestore() {
        isLoading = true
        HealthKitManager.shared.writeMockDataDirectToFirestore { [weak self] success, error in
            Task { @MainActor in
                self?.isLoading = false
                if success {
                    self?.lastSyncTime = "Direct mock written — tap Sync Now"
                } else {
                    self?.lastSyncTime = "Direct mock failed: \(error?.localizedDescription ?? "unknown")"
                }
            }
        }
    }
}

struct WorkoutItem: Identifiable {
    let id = UUID()
    let activityType: String
    let duration: TimeInterval
    let energyBurned: Double
}

struct NutritionData {
    var calories: Double = 0
    var protein: Double = 0
    var carbs: Double = 0
    var fat: Double = 0
}
