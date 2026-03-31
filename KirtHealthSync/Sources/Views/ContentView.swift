import SwiftUI
import FirebaseCore
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

                Section(header: Text("Last Sync")) {
                    Text(viewModel.lastSyncTime)
                        .foregroundColor(.secondary)
                    Button("Sync Now") {
                        viewModel.syncNow()
                    }
                    .disabled(viewModel.isLoading)
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

    private let db: Firestore? = {
        // Skip Firestore in test environment (XCTest environment is set by the test runner)
        if ProcessInfo.processInfo.environment["XCTest"] != nil { return nil }
        if ProcessInfo.processInfo.arguments.contains("--uitesting") { return nil }
        guard FirebaseApp.app() != nil else { return nil }
        return Firestore.firestore()
    }()

    private var todayDateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    func loadData() {
        guard let db = db else { return }
        let docPath = "kirt/daily/\(todayDateString)"
        var docRef: DocumentReference? = nil
        do {
            docRef = try db.document(docPath)
        } catch {
            print("[HealthDataViewModel] Firestore document reference error: \(error)")
            return
        }
        docRef?.getDocument { [weak self] snapshot, error in
            guard let self = self else { return }
            guard let doc = snapshot, doc.exists else {
                let formatter = DateFormatter()
                formatter.dateStyle = .short
                formatter.timeStyle = .short
                Task { @MainActor in self.lastSyncTime = formatter.string(from: Date()) }
                return
            }

            let data = doc.data() ?? [:]

            // Parse Phase 2 schema — metrics map
            if let metrics = data["metrics"] as? [String: Any] {
                if let steps = metrics["steps"] as? [String: Any],
                   let total = steps["total"] as? Int {
                    Task { @MainActor in self.todaySteps = total }
                }
                if let sleep = metrics["sleep"] as? [String: Any],
                   let totalMinutes = sleep["totalMinutes"] as? Int {
                    Task { @MainActor in self.todaySleepMinutes = totalMinutes }
                }
                if let weight = metrics["weight"] as? [String: Any],
                   let value = weight["value"] as? Double {
                    Task { @MainActor in self.latestWeight = value }
                }
                if let heartRate = metrics["heartRate"] as? [String: Any],
                   let resting = heartRate["resting"] as? Int {
                    Task { @MainActor in self.latestRestingHR = resting }
                }
                if let nutrition = metrics["nutrition"] as? [String: Any] {
                    Task { @MainActor in
                        self.nutritionData = NutritionData(
                            calories: nutrition["dietaryEnergyConsumed"] as? Double ?? 0,
                            protein: nutrition["dietaryProtein"] as? Double ?? 0,
                            carbs: nutrition["dietaryCarbohydrates"] as? Double ?? 0,
                            fat: nutrition["dietaryFatTotal"] as? Double ?? 0
                        )
                    }
                }
                if let workouts = metrics["workouts"] as? [[String: Any]] {
                    Task { @MainActor in
                        self.recentWorkouts = workouts.compactMap { w in
                            guard let activityType = w["activityType"] as? String,
                                  let duration = w["duration"] as? Double,
                                  let energyBurned = w["energyBurned"] as? Double else { return nil }
                            return WorkoutItem(activityType: activityType, duration: duration, energyBurned: energyBurned)
                        }
                    }
                }
            }

            // Fallback: syncedAt timestamp
            if let syncedAt = data["syncedAt"] as? Timestamp {
                let formatter = DateFormatter()
                formatter.dateStyle = .short
                formatter.timeStyle = .short
                Task { @MainActor in self.lastSyncTime = formatter.string(from: syncedAt.dateValue()) }
            } else {
                let formatter = DateFormatter()
                formatter.dateStyle = .short
                formatter.timeStyle = .short
                Task { @MainActor in self.lastSyncTime = formatter.string(from: Date()) }
            }
        }
    }

    func syncNow() {
        isLoading = true
        HealthKitManager.shared.syncHealthData { [weak self] result in
            Task { @MainActor in
                self?.isLoading = false
                self?.recentWorkouts.removeAll()
                self?.loadData()
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
