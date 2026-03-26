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
        // Activity
        HKObjectType.quantityType(forIdentifier: .stepCount)!,
        HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
        HKObjectType.quantityType(forIdentifier: .basalEnergyBurned)!,
        HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)!,
        HKObjectType.quantityType(forIdentifier: .distanceRunning)!,
        HKObjectType.quantityType(forIdentifier: .distanceSwimming)!,
        HKObjectType.quantityType(forIdentifier: .swimmingStrokeCount)!,
        HKObjectType.quantityType(forIdentifier: .vo2Max)!,
        // Body Measurements
        HKObjectType.quantityType(forIdentifier: .bodyMass)!,
        HKObjectType.quantityType(forIdentifier: .height)!,
        HKObjectType.quantityType(forIdentifier: .bodyFatPercentage)!,
        HKObjectType.quantityType(forIdentifier: .leanBodyMass)!,
        HKObjectType.quantityType(forIdentifier: .bodyMassIndex)!,
        // Heart
        HKObjectType.quantityType(forIdentifier: .heartRate)!,
        HKObjectType.quantityType(forIdentifier: .restingHeartRate)!,
        HKObjectType.quantityType(forIdentifier: .walkingHeartRateAverage)!,
        HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
        HKObjectType.quantityType(forIdentifier: .cardioFitnessLevel)!,
        HKObjectType.categoryType(forIdentifier: .electrocardiogram)!,
        HKObjectType.workoutType(),
        // Sleep
        HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!,
        HKObjectType.categoryType(forIdentifier: .mindfulnessSession)!,
        // Vitals
        HKObjectType.quantityType(forIdentifier: .respiratoryRate)!,
        HKObjectType.quantityType(forIdentifier: .bloodGlucose)!,
        HKObjectType.quantityType(forIdentifier: .bloodPressureSystolic)!,
        HKObjectType.quantityType(forIdentifier: .bloodPressureDiastolic)!,
        HKObjectType.quantityType(forIdentifier: .oxygenSaturation)!,
        // Running Metrics
        HKObjectType.quantityType(forIdentifier: .runningSpeed)!,
        HKObjectType.quantityType(forIdentifier: .runningPower)!,
        // Audio
        HKObjectType.quantityType(forIdentifier: .headphoneAudioExposure)!,
        // Nutrition
        HKObjectType.quantityType(forIdentifier: .dietaryEnergyConsumed)!,
        HKObjectType.quantityType(forIdentifier: .dietaryProtein)!,
        HKObjectType.quantityType(forIdentifier: .dietaryCarbohydrates)!,
        HKObjectType.quantityType(forIdentifier: .dietaryFatTotal)!,
        HKObjectType.quantityType(forIdentifier: .dietaryFiber)!,
        HKObjectType.quantityType(forIdentifier: .dietarySugar)!,
        HKObjectType.quantityType(forIdentifier: .dietarySodium)!,
        HKObjectType.quantityType(forIdentifier: .dietaryWater)!,
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
    }    // MARK: - Cardio Fitness

    private func syncCardioFitness(_ startDate: Date, _ endDate: Date, completion: @escaping (Any?, Error?) -> Void) {
        guard let fitnessType = HKObjectType.quantityType(forIdentifier: .cardioFitnessLevel) else {
            completion(nil, nil)
            return
        }

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(sampleType: fitnessType, predicate: predicate, limit: 1, sortDescriptors: [sortDescriptor]) { _, results, error in
            if let error = error {
                completion(nil, error)
                return
            }

            guard let fitnessSample = results?.first as? HKQuantitySample else {
                completion(nil, nil)
                return
            }

            let vo2 = fitnessSample.quantity.doubleValue(for: HKUnit.literUnit(with: .milli).unitDivided(by: .gramUnit(with: .kilo)))

            let data: [String: Any] = [
                "value": vo2,
                "unit": "ml/(kg.min)",
                "startDate": ISO8601DateFormatter().string(from: fitnessSample.startDate),
                "timestamp": FieldValue.serverTimestamp()
            ]

            self.db.collection("healthData").document("cardio_\(Int(fitnessSample.startDate.timeIntervalSince1970))").setData(data) { error in
                completion(error == nil ? String(format: "%.1f VO2", vo2) : nil, error)
            }
        }

        healthStore.execute(query)
    }

    private func syncMindfulness(_ startDate: Date, _ endDate: Date, completion: @escaping (Any?, Error?) -> Void) {
        guard let mindType = HKObjectType.categoryType(forIdentifier: .mindfulnessSession) else {
            completion(nil, nil)
            return
        }

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(sampleType: mindType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sortDescriptor]) { _, results, error in
            if let error = error {
                completion(nil, error)
                return
            }

            guard let samples = results as? [HKCategorySample], !samples.isEmpty else {
                completion(nil, nil)
                return
            }

            let totalMinutes = samples.reduce(0.0) { total, sample in
                total + sample.endDate.timeIntervalSince(sample.startDate) / 60.0
            }

            let data: [String: Any] = [
                "value": totalMinutes,
                "unit": "minutes",
                "sessionCount": samples.count,
                "startDate": ISO8601DateFormatter().string(from: samples.first!.startDate),
                "endDate": ISO8601DateFormatter().string(from: samples.last!.endDate),
                "timestamp": FieldValue.serverTimestamp()
            ]

            self.db.collection("healthData").document("mindfulness_\(Int(Date().timeIntervalSince1970))").setData(data) { error in
                completion(error == nil ? "\(Int(totalMinutes)) min" : nil, error)
            }
        }

        healthStore.execute(query)
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
            ("cardioFitness", syncCardioFitness),
            ("mindfulness", syncMindfulness),
            ("respiratory", syncRespiratoryRate),
            ("bloodGlucose", syncBloodGlucose),
            ("bloodPressure", syncBloodPressure),
            ("oxygenSaturation", syncOxygenSaturation),
            ("hrv", syncHRV),
            ("runningMetrics", syncRunningMetrics),
            ("swimming", syncSwimming),
            ("bodyComposition", syncBodyComposition),
            ("water", syncWater),
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
                        // iOS 15: only asleep/awake are available
                        switch categorySample.value {
                        case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
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


    // MARK: - Respiratory

    private func syncRespiratoryRate(_ startDate: Date, _ endDate: Date, completion: @escaping (Any?, Error?) -> Void) {
        guard let type = HKObjectType.quantityType(forIdentifier: .respiratoryRate) else {
            completion(nil, nil); return
        }
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 1, sortDescriptors: [sortDescriptor]) { _, results, error in
            if let error = error { completion(nil, error); return }
            guard let sample = results?.first as? HKQuantitySample else { completion(nil, nil); return }
            let value = sample.quantity.doubleValue(for: HKUnit(from: "count/min"))
            let data: [String: Any] = [
                "value": value, "unit": "breaths/min",
                "startDate": ISO8601DateFormatter().string(from: sample.startDate),
                "timestamp": FieldValue.serverTimestamp()
            ]
            self.db.collection("healthData").document("respiratory_\(Int(sample.startDate.timeIntervalSince1970))").setData(data) { error in
                completion(error == nil ? "\(String(format: "%.1f", value)) brpm" : nil, error)
            }
        }
        healthStore.execute(query)
    }

    // MARK: - Blood Metrics

    private func syncBloodGlucose(_ startDate: Date, _ endDate: Date, completion: @escaping (Any?, Error?) -> Void) {
        guard let type = HKObjectType.quantityType(forIdentifier: .bloodGlucose) else {
            completion(nil, nil); return
        }
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 1, sortDescriptors: [sortDescriptor]) { _, results, error in
            if let error = error { completion(nil, error); return }
            guard let sample = results?.first as? HKQuantitySample else { completion(nil, nil); return }
            let value = sample.quantity.doubleValue(for: HKUnit(dimension: .millimolePerLiter))
            let data: [String: Any] = [
                "value": value, "unit": "mmol/L",
                "startDate": ISO8601DateFormatter().string(from: sample.startDate),
                "timestamp": FieldValue.serverTimestamp()
            ]
            self.db.collection("healthData").document("glucose_\(Int(sample.startDate.timeIntervalSince1970))").setData(data) { error in
                completion(error == nil ? String(format: "%.1f mmol/L", value) : nil, error)
            }
        }
        healthStore.execute(query)
    }

    private func syncBloodPressure(_ startDate: Date, _ endDate: Date, completion: @escaping (Any?, Error?) -> Void) {
        guard let systolicType = HKObjectType.quantityType(forIdentifier: .bloodPressureSystolic),
              let diastolicType = HKObjectType.quantityType(forIdentifier: .bloodPressureDiastolic) else {
            completion(nil, nil); return
        }
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(sampleType: systolicType, predicate: predicate, limit: 1, sortDescriptors: [sortDescriptor]) { _, results, error in
            if let error = error { completion(nil, error); return }
            guard let systolic = results?.first as? HKQuantitySample else { completion(nil, nil); return }
            let systValue = systolic.quantity.doubleValue(for: .millimeterOfMercury())
            let diastolicQuery = HKSampleQuery(sampleType: diastolicType, predicate: predicate, limit: 1, sortDescriptors: sortDescriptor) { _, dResults, _ in
                var diastValue: Double = 0
                if let diast = dResults?.first as? HKQuantitySample {
                    diastValue = diast.quantity.doubleValue(for: .millimeterOfMercury())
                }
                let data: [String: Any] = [
                    "systolic": systValue, "diastolic": diastValue, "unit": "mmHg",
                    "startDate": ISO8601DateFormatter().string(from: systolic.startDate),
                    "timestamp": FieldValue.serverTimestamp()
                ]
                self.db.collection("healthData").document("bp_\(Int(systolic.startDate.timeIntervalSince1970))").setData(data) { error in
                    completion(error == nil ? "\(Int(systValue))/\(Int(diastValue)) mmHg" : nil, error)
                }
            }
            self.healthStore.execute(diastolicQuery)
        }
        healthStore.execute(query)
    }

    private func syncOxygenSaturation(_ startDate: Date, _ endDate: Date, completion: @escaping (Any?, Error?) -> Void) {
        guard let type = HKObjectType.quantityType(forIdentifier: .oxygenSaturation) else {
            completion(nil, nil); return
        }
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 1, sortDescriptors: [sortDescriptor]) { _, results, error in
            if let error = error { completion(nil, error); return }
            guard let sample = results?.first as? HKQuantitySample else { completion(nil, nil); return }
            let value = sample.quantity.doubleValue(for: .percent())
            let data: [String: Any] = [
                "value": value * 100, "unit": "%",
                "startDate": ISO8601DateFormatter().string(from: sample.startDate),
                "timestamp": FieldValue.serverTimestamp()
            ]
            self.db.collection("healthData").document("spO2_\(Int(sample.startDate.timeIntervalSince1970))").setData(data) { error in
                completion(error == nil ? String(format: "%.0f%%", value * 100) : nil, error)
            }
        }
        healthStore.execute(query)
    }

    // MARK: - HRV & ECG

    private func syncHRV(_ startDate: Date, _ endDate: Date, completion: @escaping (Any?, Error?) -> Void) {
        guard let type = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else {
            completion(nil, nil); return
        }
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 1, sortDescriptors: [sortDescriptor]) { _, results, error in
            if let error = error { completion(nil, error); return }
            guard let sample = results?.first as? HKQuantitySample else { completion(nil, nil); return }
            let value = sample.quantity.doubleValue(for: .secondUnit(with: .milli))
            let data: [String: Any] = [
                "value": value, "unit": "ms",
                "startDate": ISO8601DateFormatter().string(from: sample.startDate),
                "timestamp": FieldValue.serverTimestamp()
            ]
            self.db.collection("healthData").document("hrv_\(Int(sample.startDate.timeIntervalSince1970))").setData(data) { error in
                completion(error == nil ? String(format: "%.1f ms", value) : nil, error)
            }
        }
        healthStore.execute(query)
    }

    // MARK: - Running

    private func syncRunningMetrics(_ startDate: Date, _ endDate: Date, completion: @escaping (Any?, Error?) -> Void) {
        guard let speedType = HKObjectType.quantityType(forIdentifier: .runningSpeed),
              let powerType = HKObjectType.quantityType(forIdentifier: .runningPower) else {
            completion(nil, nil); return
        }
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        var results: [String: Any] = [:]
        let group = DispatchGroup()

        group.enter()
        let speedQuery = HKSampleQuery(sampleType: speedType, predicate: predicate, limit: 1, sortDescriptors: [sortDescriptor]) { _, samples, _ in
            if let s = samples?.first as? HKQuantitySample {
                let speed = s.quantity.doubleValue(for: HKUnit(from: "m/s"))
                results["speed"] = speed
            }
            group.leave()
        }
        healthStore.execute(speedQuery)

        group.enter()
        let powerQuery = HKSampleQuery(sampleType: powerType, predicate: predicate, limit: 1, sortDescriptors: [sortDescriptor]) { _, samples, _ in
            if let p = samples?.first as? HKQuantitySample {
                let power = p.quantity.doubleValue(for: .watt())
                results["power"] = power
            }
            group.leave()
        }
        healthStore.execute(powerQuery)

        group.notify(queue: .main) {
            if results.isEmpty { completion(nil, nil); return }
            let data: [String: Any] = [
                "speed": results["speed"] ?? 0,
                "power": results["power"] ?? 0,
                "unit": "m/s, W",
                "startDate": ISO8601DateFormatter().string(from: startDate),
                "timestamp": FieldValue.serverTimestamp()
            ]
            self.db.collection("healthData").document("running_\(Int(Date().timeIntervalSince1970))").setData(data) { error in
                let speed = results["speed"] as? Double ?? 0
                let power = results["power"] as? Double ?? 0
                completion(error == nil ? "speed \(String(format: "%.1f", speed)) m/s, power \(Int(power)) W" : nil, error)
            }
        }
    }

    // MARK: - Swimming

    private func syncSwimming(_ startDate: Date, _ endDate: Date, completion: @escaping (Any?, Error?) -> Void) {
        guard let distType = HKObjectType.quantityType(forIdentifier: .distanceSwimming),
              let strokeType = HKObjectType.quantityType(forIdentifier: .swimmingStrokeCount) else {
            completion(nil, nil); return
        }
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)

        var results: [String: Any] = [:]
        let group = DispatchGroup()

        group.enter()
        let distQuery = HKSampleQuery(sampleType: distType, predicate: predicate, limit: 1, sortDescriptors: nil) { _, samples, _ in
            if let d = samples?.first as? HKQuantitySample {
                let dist = d.quantity.doubleValue(for: .meter())
                results["distance"] = dist
            }
            group.leave()
        }
        healthStore.execute(distQuery)

        group.enter()
        let strokeQuery = HKSampleQuery(sampleType: strokeType, predicate: predicate, limit: 1, sortDescriptors: nil) { _, samples, _ in
            if let s = samples?.first as? HKQuantitySample {
                let strokes = s.quantity.doubleValue(for: .count())
                results["strokes"] = Int(strokes)
            }
            group.leave()
        }
        healthStore.execute(strokeQuery)

        group.notify(queue: .main) {
            if results.isEmpty { completion(nil, nil); return }
            let data: [String: Any] = [
                "distance": results["distance"] ?? 0,
                "strokes": results["strokes"] ?? 0,
                "unit": "m, count",
                "startDate": ISO8601DateFormatter().string(from: startDate),
                "timestamp": FieldValue.serverTimestamp()
            ]
            self.db.collection("healthData").document("swimming_\(Int(Date().timeIntervalSince1970))").setData(data) { error in
                completion(error == nil ? "dist \(Int(results["distance"] as? Double ?? 0))m, strokes \(results["strokes"] ?? 0)" : nil, error)
            }
        }
    }

    // MARK: - Body Composition

    private func syncBodyComposition(_ startDate: Date, _ endDate: Date, completion: @escaping (Any?, Error?) -> Void) {
        let types: [(String, HKQuantityTypeIdentifier)] = [
            ("bodyFat", .bodyFatPercentage),
            ("leanMass", .leanBodyMass),
            ("bmi", .bodyMassIndex),
        ]
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        var results: [String: Any] = [:]
        let group = DispatchGroup()

        for (name, identifier) in types {
            guard let qType = HKObjectType.quantityType(forIdentifier: identifier) else { continue }
            group.enter()
            let query = HKSampleQuery(sampleType: qType, predicate: predicate, limit: 1, sortDescriptors: nil) { _, samples, _ in
                if let s = samples?.first as? HKQuantitySample {
                    let value = s.quantity.doubleValue(for: .percent())
                    results[name] = value
                }
                group.leave()
            }
            healthStore.execute(query)
        }

        group.notify(queue: .main) {
            if results.isEmpty { completion(nil, nil); return }
            let data: [String: Any] = [
                "bodyFatPercentage": results["bodyFat"] ?? 0,
                "leanBodyMass": results["leanMass"] ?? 0,
                "bmi": results["bmi"] ?? 0,
                "startDate": ISO8601DateFormatter().string(from: startDate),
                "timestamp": FieldValue.serverTimestamp()
            ]
            self.db.collection("healthData").document("bodyComp_\(Int(Date().timeIntervalSince1970))").setData(data) { error in
                completion(error == nil ? "bodyFat \(String(format: "%.1f", results["bodyFat"] as? Double ?? 0))%, BMI \(String(format: "%.1f", results["bmi"] as? Double ?? 0))" : nil, error)
            }
        }
    }

    // MARK: - Water

    private func syncWater(_ startDate: Date, _ endDate: Date, completion: @escaping (Any?, Error?) -> Void) {
        guard let type = HKObjectType.quantityType(forIdentifier: .dietaryWater) else {
            completion(nil, nil); return
        }
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, result, error in
            if let error = error { completion(nil, error); return }
            let liters = result?.sumQuantity()?.doubleValue(for: .liter()) ?? 0
            let data: [String: Any] = [
                "value": liters, "unit": "L",
                "startDate": ISO8601DateFormatter().string(from: startDate),
                "timestamp": FieldValue.serverTimestamp()
            ]
            self.db.collection("healthData").document("water_\(Int(Date().timeIntervalSince1970))").setData(data) { error in
                completion(error == nil ? String(format: "%.1f L", liters) : nil, error)
            }
        }
        healthStore.execute(query)
    }

