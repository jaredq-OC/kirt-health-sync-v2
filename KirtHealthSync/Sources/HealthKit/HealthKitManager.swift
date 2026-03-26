import Foundation
import HealthKit
import FirebaseFirestore
import BackgroundTasks

class HealthKitManager {
    static let shared = HealthKitManager()

    private let healthStore = HKHealthStore()
    private let db = Firestore.firestore()

    // HealthKit data types to sync
    private let typesToRead: Set<HKObjectType> = [
        HKObjectType.quantityType(forIdentifier: .stepCount)!,
        HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
        HKObjectType.quantityType(forIdentifier: .basalEnergyBurned)!,
        HKObjectType.quantityType(forIdentifier: .bodyMass)!,
        HKObjectType.quantityType(forIdentifier: .height)!,
        HKObjectType.quantityType(forIdentifier: .heartRate)!,
        HKObjectType.quantityType(forIdentifier: .restingHeartRate)!,
        HKObjectType.quantityType(forIdentifier: .walkingHeartRateAverage)!,
        HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!,
        HKObjectType.workoutType(),
        HKObjectType.quantityType(forIdentifier: .dietaryEnergyConsumed)!,
        HKObjectType.quantityType(forIdentifier: .dietaryProtein)!,
        HKObjectType.quantityType(forIdentifier: .dietaryCarbohydrates)!,
        HKObjectType.quantityType(forIdentifier: .dietaryFatTotal)!,
        HKObjectType.quantityType(forIdentifier: .dietaryFiber)!,
        HKObjectType.quantityType(forIdentifier: .dietarySugar)!,
        HKObjectType.quantityType(forIdentifier: .dietarySodium)!,
    ]

    private let typesToWrite: Set<HKSampleType> = [
        HKObjectType.quantityType(forIdentifier: .bodyMass)!,
    ]

    // Background task identifier
    private let backgroundTaskIdentifier = "com.kirt.healthsync.backgroundsync"

    private init() {
        registerBackgroundTask()
    }

    // MARK: - Authorization

    func requestAuthorization(completion: @escaping (Bool, Error?) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            completion(false, NSError(domain: "HealthKit", code: -1, userInfo: [NSLocalizedDescriptionKey: "HealthKit is not available on this device"]))
            return
        }

        healthStore.requestAuthorization(toShare: typesToWrite, read: typesToRead) { success, error in
            DispatchQueue.main.async {
                completion(success, error)
            }
        }
    }

    // MARK: - Background Sync

    func startBackgroundSync() {
        // Schedule immediate sync
        syncHealthData()

        // Schedule recurring background fetch every 15 minutes
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskIdentifier, using: nil) { task in
            self.handleBackgroundTask(task: task as! BGProcessingTask)
        }

        scheduleBackgroundTask()
    }

    private func scheduleBackgroundTask() {
        let request = BGProcessingTaskRequest(identifier: backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 minutes

        do {
            try BGTaskScheduler.shared.submit(request)
            print("Background task scheduled")
        } catch {
            print("Failed to schedule background task: \(error)")
        }
    }

    private func handleBackgroundTask(task: BGProcessingTask) {
        scheduleBackgroundTask() // Reschedule

        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }

        syncHealthData { success in
            task.setTaskCompleted(success: success)
        }
    }

    private func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskIdentifier, using: nil) { task in
            self.handleBackgroundTask(task: task as! BGProcessingTask)
        }
    }

    // MARK: - Data Sync

    func syncHealthData(completion: ((Bool) -> Void)? = nil) {
        let group = DispatchGroup()
        var syncSuccess = true

        // Sync each data type
        let dataTypes: [(String, (Date, Date, @escaping (Any?, Error?) -> Void) -> Void)] = [
            ("steps", syncSteps),
            ("sleep", syncSleep),
            ("weight", syncWeight),
            ("workouts", syncWorkouts),
            ("nutrition", syncNutrition),
            ("heartRate", syncRestingHeartRate),
        ]

        for (name, syncFunc) in dataTypes {
            group.enter()
            let startDate = Calendar.current.date(byAdding: .hour, value: -1, to: Date()) ?? Date()
            let endDate = Date()

            syncFunc(startDate, endDate) { result, error in
                if let error = error {
                    print("Sync error for \(name): \(error)")
                    syncSuccess = false
                } else {
                    print("Synced \(name): \(result ?? "ok")")
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion?(syncSuccess)
        }
    }

    // MARK: - Sync Functions

    private func syncSteps(_ startDate: Date, _ endDate: Date, completion: @escaping (Any?, Error?) -> Void) {
        guard let stepType = HKObjectType.quantityType(forIdentifier: .stepCount) else {
            completion(nil, NSError(domain: "HealthKit", code: -2, userInfo: nil))
            return
        }

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let query = HKStatisticsQuery(quantityType: stepType, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, result, error in
            if let error = error {
                completion(nil, error)
                return
            }

            let steps = result?.sumQuantity()?.doubleValue(for: .count()) ?? 0

            let data: [String: Any] = [
                "value": steps,
                "unit": "count",
                "startDate": ISO8601DateFormatter().string(from: startDate),
                "endDate": ISO8601DateFormatter().string(from: endDate),
                "timestamp": FieldValue.serverTimestamp()
            ]

            self.db.collection("healthData").document("steps_\(Int(Date().timeIntervalSince1970))").setData(data) { error in
                completion(error == nil ? "\(steps) steps" : nil, error)
            }
        }

        healthStore.execute(query)
    }

    private func syncSleep(_ startDate: Date, _ endDate: Date, completion: @escaping (Any?, Error?) -> Void) {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            completion(nil, nil)
            return
        }

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let query = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, results, error in
            if let error = error {
                completion(nil, error)
                return
            }

            var totalSleepMinutes: Double = 0
            var sleepStages: [String: Double] = [:]

            for sample in results ?? [] {
                if let categorySample = sample as? HKCategorySample {
                    let minutes = categorySample.endDate.timeIntervalSince(categorySample.startDate) / 60
                    totalSleepMinutes += minutes

                    let stageName: String
                    if #available(iOS 16.0, *) {
                        switch categorySample.value {
                        case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
                            stageName = "asleep"
                        case HKCategoryValueSleepAnalysis.asleepCore.rawValue:
                            stageName = "asleepCore"
                        case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
                            stageName = "asleepDeep"
                        case HKCategoryValueSleepAnalysis.awake.rawValue:
                            stageName = "awake"
                        case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                            stageName = "asleepREM"
                        default:
                            stageName = "unknown"
                        }
                    } else {
                        switch categorySample.value {
                        case HKCategoryValueSleepAnalysis.asleep.rawValue:
                            stageName = "asleep"
                        case HKCategoryValueSleepAnalysis.awake.rawValue:
                            stageName = "awake"
                        default:
                            stageName = "unknown"
                        }
                    }
                    sleepStages[stageName] = (sleepStages[stageName] ?? 0) + minutes
                }
            }

            let data: [String: Any] = [
                "totalMinutes": totalSleepMinutes,
                "stages": sleepStages,
                "startDate": ISO8601DateFormatter().string(from: startDate),
                "endDate": ISO8601DateFormatter().string(from: endDate),
                "timestamp": FieldValue.serverTimestamp()
            ]

            self.db.collection("healthData").document("sleep_\(Int(Date().timeIntervalSince1970))").setData(data) { error in
                completion(error == nil ? "\(Int(totalSleepMinutes)) min" : nil, error)
            }
        }

        healthStore.execute(query)
    }

    private func syncWeight(_ startDate: Date, _ endDate: Date, completion: @escaping (Any?, Error?) -> Void) {
        guard let weightType = HKObjectType.quantityType(forIdentifier: .bodyMass) else {
            completion(nil, nil)
            return
        }

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(sampleType: weightType, predicate: predicate, limit: 1, sortDescriptors: [sortDescriptor]) { _, results, error in
            if let error = error {
                completion(nil, error)
                return
            }

            guard let weightSample = results?.first as? HKQuantitySample else {
                completion(nil, nil)
                return
            }

            let weight = weightSample.quantity.doubleValue(for: .pound())

            let data: [String: Any] = [
                "value": weight,
                "unit": "lb",
                "startDate": ISO8601DateFormatter().string(from: weightSample.startDate),
                "timestamp": FieldValue.serverTimestamp()
            ]

            self.db.collection("healthData").document("weight_\(Int(weightSample.startDate.timeIntervalSince1970))").setData(data) { error in
                completion(error == nil ? "\(weight) lb" : nil, error)
            }
        }

        healthStore.execute(query)
    }

    private func syncWorkouts(_ startDate: Date, _ endDate: Date, completion: @escaping (Any?, Error?) -> Void) {
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sortDescriptor]) { _, results, error in
            if let error = error {
                completion(nil, error)
                return
            }

            guard let workouts = results as? [HKWorkout] else {
                completion(nil, nil)
                return
            }

            for workout in workouts {
                let data: [String: Any] = [
                    "activityType": String(describing: workout.workoutActivityType),
                    "duration": workout.duration,
                    "startDate": ISO8601DateFormatter().string(from: workout.startDate),
                    "endDate": ISO8601DateFormatter().string(from: workout.endDate),
                    "energyBurned": workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()) ?? 0,
                    "timestamp": FieldValue.serverTimestamp()
                ]

                self.db.collection("healthData").document("workout_\(Int(workout.startDate.timeIntervalSince1970))").setData(data)
            }

            completion("\(workouts.count) workouts", nil)
        }

        healthStore.execute(query)
    }

    private func syncNutrition(_ startDate: Date, _ endDate: Date, completion: @escaping (Any?, Error?) -> Void) {
        let nutritionTypes: [HKQuantityTypeIdentifier] = [
            .dietaryEnergyConsumed, .dietaryProtein, .dietaryCarbohydrates,
            .dietaryFatTotal, .dietaryFiber, .dietarySugar, .dietarySodium
        ]

        var nutritionData: [String: Double] = [:]
        let group = DispatchGroup()

        for nutrient in nutritionTypes {
            group.enter()
            guard let type = HKObjectType.quantityType(forIdentifier: nutrient) else {
                group.leave()
                continue
            }

            let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, result, error in
                if let sum = result?.sumQuantity() {
                    nutritionData[nutrient.rawValue] = sum.doubleValue(for: .gram())
                }
                group.leave()
            }
            healthStore.execute(query)
        }

        group.notify(queue: .main) {
            let data: [String: Any] = [
                "nutrients": nutritionData,
                "startDate": ISO8601DateFormatter().string(from: startDate),
                "endDate": ISO8601DateFormatter().string(from: endDate),
                "timestamp": FieldValue.serverTimestamp()
            ]

            self.db.collection("healthData").document("nutrition_\(Int(Date().timeIntervalSince1970))").setData(data) { error in
                completion(error == nil ? "nutrition logged" : nil, error)
            }
        }
    }

    private func syncRestingHeartRate(_ startDate: Date, _ endDate: Date, completion: @escaping (Any?, Error?) -> Void) {
        guard let hrType = HKObjectType.quantityType(forIdentifier: .restingHeartRate) else {
            completion(nil, nil)
            return
        }

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(sampleType: hrType, predicate: predicate, limit: 1, sortDescriptors: [sortDescriptor]) { _, results, error in
            if let error = error {
                completion(nil, error)
                return
            }

            guard let hrSample = results?.first as? HKQuantitySample else {
                completion(nil, nil)
                return
            }

            let hr = hrSample.quantity.doubleValue(for: HKUnit(from: "count/min"))

            let data: [String: Any] = [
                "value": hr,
                "unit": "count/min",
                "startDate": ISO8601DateFormatter().string(from: hrSample.startDate),
                "timestamp": FieldValue.serverTimestamp()
            ]

            self.db.collection("healthData").document("restingHR_\(Int(hrSample.startDate.timeIntervalSince1970))").setData(data) { error in
                completion(error == nil ? "\(Int(hr)) bpm" : nil, error)
            }
        }

        healthStore.execute(query)
    }
}
