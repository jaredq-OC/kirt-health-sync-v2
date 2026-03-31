import Foundation
import HealthKit
import FirebaseCore
import FirebaseFirestore
import BackgroundTasks

class HealthKitManager {
    static let shared = HealthKitManager()

    private let healthStore = HKHealthStore()

    // MARK: - Firestore reference (lazy, guarded against suspended Firebase)
    // Uses a separate _dbInit sentinel to track whether Firestore has been
    // safely initialized without throwing.
    private static var _dbInitAttempted = false
    private static var _dbInstance: Firestore? = nil

    private var db: Firestore? {
        get {
            if AppDelegate.isUITesting { return nil }
            if HealthKitManager._dbInitAttempted { return HealthKitManager._dbInstance }
            HealthKitManager._dbInitAttempted = true
            // Use ObjC helper that catches NSException from Firebase SDK
            HealthKitManager._dbInstance = FIRSafeInit.safeFirestore()
            return HealthKitManager._dbInstance
        }
    }

    // MARK: - UserDefaults keys for anchors
    private let anchorKeyPrefix = "HKManager_Anchor_"
    private let lastSyncTimeKey = "HKManager_LastSyncTime"

    var lastSyncTimeString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        if let timestamp = UserDefaults.standard.object(forKey: lastSyncTimeKey) as? Date {
            return formatter.string(from: timestamp)
        }
        return "Never"
    }

    // MARK: - Batch metrics accumulator
    private var syncMetrics: [String: Any] = [:]
    private var syncWorkouts: [[String: Any]] = []
    private var syncWindowStart: Date?
    private var syncWindowEnd: Date = Date()
    private var pendingWrites: Int = 0
    private let metricsQueue = DispatchQueue(label: "com.kirt.healthsync.metrics")

    // MARK: - HealthKit data types (quantity + workout, anchored queries)
    private let anchoredTypes: [HKQuantityTypeIdentifier] = [
        .stepCount,
        .activeEnergyBurned,
        .basalEnergyBurned,
        .distanceWalkingRunning,
        .distanceSwimming,
        .swimmingStrokeCount,
        .vo2Max,
        .heartRate,
        .restingHeartRate,
        .walkingHeartRateAverage,
        .heartRateVariabilitySDNN,
        .bodyMass,
        .height,
        .bodyFatPercentage,
        .leanBodyMass,
        .bodyMassIndex,
        .respiratoryRate,
        .bloodGlucose,
        .bloodPressureSystolic,
        .bloodPressureDiastolic,
        .oxygenSaturation,
        .runningSpeed,
        .runningPower,
        .dietaryEnergyConsumed,
        .dietaryProtein,
        .dietaryCarbohydrates,
        .dietaryFatTotal,
        .dietaryFiber,
        .dietarySugar,
        .dietarySodium,
        .dietaryWater,
    ]

    // MARK: - Background task identifier
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

        var typesToRead: Set<HKObjectType> = []
        for id in anchoredTypes {
            if let t = HKQuantityType.quantityType(forIdentifier: id) {
                typesToRead.insert(t)
            }
        }
        typesToRead.insert(HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!)
        typesToRead.insert(HKObjectType.workoutType())

        let typesToWrite: Set<HKSampleType> = [
            HKQuantityType.quantityType(forIdentifier: .bodyMass)!,
        ]

        healthStore.requestAuthorization(toShare: typesToWrite, read: typesToRead) { success, error in
            DispatchQueue.main.async {
                completion(success, error)
            }
        }
    }

    // MARK: - Background Sync

    func startBackgroundSync() {
        registerSleepObserver()  // Register once; fires on new sleep data
        syncHealthData()
        scheduleBackgroundTask()
    }

    private func scheduleBackgroundTask() {
        let request = BGProcessingTaskRequest(identifier: backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
            print("Background task scheduled")
        } catch {
            print("Failed to schedule background task: \(error)")
        }
    }

    private func handleBackgroundTask(task: BGProcessingTask) {
        scheduleBackgroundTask()

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

    // MARK: - Sleep Observer Query

    /// Registered once at startBackgroundSync(). Fires when Apple Health saves new sleep data
    /// (e.g., after the user wakes up). Triggers an immediate anchored sync of sleep samples.
    private func registerSleepObserver() {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return }

        let observerQuery = HKObserverQuery(sampleType: sleepType, predicate: nil) { [weak self] _, _, error in
            if let error = error {
                print("Sleep observer query error: \(error)")
                return
            }
            print("Sleep observer fired — syncing sleep data")
            self?.syncSleepData()
        }

        healthStore.execute(observerQuery)
    }

    // MARK: - Data Sync

    /// Main entry point. Runs anchored object queries for all types in parallel,
    /// accumulates results, then writes ONE Firestore document per sync.
    func syncHealthData(completion: ((Bool) -> Void)? = nil) {
        // Reset accumulators for this sync window
        metricsQueue.sync {
            syncMetrics = [:]
            syncWorkouts = []
            syncWindowStart = getAnchorDate()
            syncWindowEnd = Date()
        }

        let group = DispatchGroup()
        var syncSuccess = true

        // Run anchored query for each quantity type
        for id in anchoredTypes {
            guard let type = HKQuantityType.quantityType(forIdentifier: id) else { continue }
            group.enter()
            runAnchoredQuery(for: type, metricId: id.rawValue) { error in
                if error != nil { syncSuccess = false }
                group.leave()
            }
        }

        // Run anchored query for workouts
        group.enter()
        runWorkoutAnchoredQuery { error in
            if error != nil { syncSuccess = false }
            group.leave()
        }

        // Run anchored query for sleep (category type — separate path)
        group.enter()
        runSleepAnchoredQuery { error in
            if error != nil { syncSuccess = false }
            group.leave()
        }

        // After all queries complete, write ONE batch upsert to Firestore
        group.notify(queue: metricsQueue) { [weak self] in
            guard let self = self else { return }
            self.writeBatchUpsert { success in
                DispatchQueue.main.async {
                    completion?(success && syncSuccess)
                }
            }
        }
    }

    // MARK: - HKAnchoredObjectQuery for Quantity Types

    /// Runs an anchored object query for a single HKQuantityType.
    /// Updates the anchor in UserDefaults on completion so restarts resume correctly.
    private func runAnchoredQuery(for quantityType: HKQuantityType, metricId: String, completion: @escaping (Error?) -> Void) {
        let anchor = loadAnchor(for: metricId)

        let query = HKAnchoredObjectQuery(
            type: quantityType,
            predicate: nil,
            anchor: anchor,
            limit: HKObjectQueryNoLimit
        ) { [weak self] _, samples, _, newAnchor, error in
            guard let self = self else { return }

            if let error = error {
                print("Anchored query error for \(metricId): \(error)")
                completion(error)
                return
            }

            // Persist new anchor before processing (prevents duplicates on crash)
            if let newAnchor = newAnchor {
                self.saveAnchor(newAnchor, for: metricId)
            }

            if let quantitySamples = samples as? [HKQuantitySample] {
                self.processQuantitySamples(quantitySamples, metricId: metricId)
            }

            completion(nil)
        }

        query.updateHandler = { [weak self] _, samples, _, newAnchor, error in
            guard let self = self else { return }
            if let newAnchor = newAnchor {
                self.saveAnchor(newAnchor, for: metricId)
            }
            if let quantitySamples = samples as? [HKQuantitySample] {
                self.processQuantitySamples(quantitySamples, metricId: metricId)
            }
        }

        healthStore.execute(query)
    }

    // MARK: - HKAnchoredObjectQuery for Workouts

    private func runWorkoutAnchoredQuery(completion: @escaping (Error?) -> Void) {
        let anchor = loadAnchor(for: "workout")
        let query = HKAnchoredObjectQuery(
            type: HKObjectType.workoutType(),
            predicate: nil,
            anchor: anchor,
            limit: HKObjectQueryNoLimit
        ) { [weak self] _, samples, _, newAnchor, error in
            guard let self = self else { return }

            if let error = error {
                print("Workout anchored query error: \(error)")
                completion(error)
                return
            }

            if let newAnchor = newAnchor {
                self.saveAnchor(newAnchor, for: "workout")
            }

            if let workouts = samples as? [HKWorkout] {
                self.processWorkouts(workouts)
            }

            completion(nil)
        }

        query.updateHandler = { [weak self] _, samples, _, newAnchor, error in
            guard let self = self else { return }
            if let newAnchor = newAnchor {
                self.saveAnchor(newAnchor, for: "workout")
            }
            if let workouts = samples as? [HKWorkout] {
                self.processWorkouts(workouts)
            }
        }

        healthStore.execute(query)
    }

    // MARK: - HKAnchoredObjectQuery for Sleep (Category Type)

    /// Sleep uses HKCategorySample — anchored query pattern is the same as quantity types.
    private func runSleepAnchoredQuery(completion: @escaping (Error?) -> Void) {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            completion(nil)
            return
        }

        let anchor = loadAnchor(for: "sleep")
        let query = HKAnchoredObjectQuery(
            type: sleepType,
            predicate: nil,
            anchor: anchor,
            limit: HKObjectQueryNoLimit
        ) { [weak self] _, samples, _, newAnchor, error in
            guard let self = self else { return }

            if let error = error {
                print("Sleep anchored query error: \(error)")
                completion(error)
                return
            }

            if let newAnchor = newAnchor {
                self.saveAnchor(newAnchor, for: "sleep")
            }

            if let categorySamples = samples as? [HKCategorySample] {
                self.processSleepSamples(categorySamples)
            }

            completion(nil)
        }

        query.updateHandler = { [weak self] _, samples, _, newAnchor, error in
            guard let self = self else { return }
            if let newAnchor = newAnchor {
                self.saveAnchor(newAnchor, for: "sleep")
            }
            if let categorySamples = samples as? [HKCategorySample] {
                self.processSleepSamples(categorySamples)
            }
        }

        healthStore.execute(query)
    }

    /// Called directly by HKObserverQuery when new sleep data arrives overnight.
    /// Uses an anchored query so we don't re-process everything.
    private func syncSleepData() {
        runSleepAnchoredQuery { _ in }
    }

    // MARK: - Sample Processing

    private func processQuantitySamples(_ samples: [HKQuantitySample], metricId: String) {
        guard !samples.isEmpty else { return }

        metricsQueue.sync {
            for sample in samples {
                accumulateMetric(metricId, sample: sample)
            }
        }
    }

    private func processWorkouts(_ workouts: [HKWorkout]) {
        metricsQueue.sync {
            for workout in workouts {
                let entry: [String: Any] = [
                    "type": String(describing: workout.workoutActivityType),
                    "duration": workout.duration,
                    "startDate": ISO8601DateFormatter().string(from: workout.startDate),
                    "endDate": ISO8601DateFormatter().string(from: workout.endDate),
                    "energyBurned": workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()) ?? 0,
                ]
                syncWorkouts.append(entry)
            }
        }
    }

    private func processSleepSamples(_ samples: [HKCategorySample]) {
        metricsQueue.sync {
            var totalMinutes: Double = 0
            var stages: [String: Double] = [:]

            for sample in samples {
                let minutes = sample.endDate.timeIntervalSince(sample.startDate) / 60
                totalMinutes += minutes

                let stageName: String
                if #available(iOS 16.0, *) {
                    switch HKCategoryValueSleepAnalysis(rawValue: sample.value) {
                    case .asleepUnspecified: stageName = "asleep"
                    case .asleepCore: stageName = "asleepCore"
                    case .asleepDeep: stageName = "asleepDeep"
                    case .awake: stageName = "awake"
                    case .asleepREM: stageName = "asleepREM"
                    default: stageName = "unknown"
                    }
                } else {
                    switch sample.value {
                    case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue: stageName = "asleep"
                    case HKCategoryValueSleepAnalysis.awake.rawValue: stageName = "awake"
                    default: stageName = "unknown"
                    }
                }

                stages[stageName] = (stages[stageName] ?? 0) + minutes
            }

            if totalMinutes > 0 {
                syncMetrics["sleep"] = [
                    "totalMinutes": totalMinutes,
                    "stages": stages,
                    "unit": "min",
                ]
            }
        }
    }

    // MARK: - Metric Accumulation

    /// Accumulates the latest value for each metric type into syncMetrics.
    /// For cumulative types (steps, energy, distance), sums all samples in the window.
    private func accumulateMetric(_ metricId: String, sample: HKQuantitySample) {
        let value: Any
        var unit: String = ""

        switch HKQuantityTypeIdentifier(rawValue: metricId) {
        case .stepCount:
            value = sample.quantity.doubleValue(for: .count())
            unit = "count"
        case .activeEnergyBurned:
            value = sample.quantity.doubleValue(for: .kilocalorie())
            unit = "kcal"
        case .basalEnergyBurned:
            value = sample.quantity.doubleValue(for: .kilocalorie())
            unit = "kcal"
        case .distanceWalkingRunning:
            value = sample.quantity.doubleValue(for: .meter())
            unit = "m"
        case .distanceSwimming:
            value = sample.quantity.doubleValue(for: .meter())
            unit = "m"
        case .swimmingStrokeCount:
            value = sample.quantity.doubleValue(for: .count())
            unit = "count"
        case .vo2Max:
            value = sample.quantity.doubleValue(for: HKUnit.literUnit(with: .milli).unitDivided(by: .gramUnit(with: .kilo)))
            unit = "mL/min/kg"
        case .heartRate:
            value = sample.quantity.doubleValue(for: HKUnit(from: "count/min"))
            unit = "count/min"
        case .restingHeartRate:
            value = sample.quantity.doubleValue(for: HKUnit(from: "count/min"))
            unit = "count/min"
        case .walkingHeartRateAverage:
            value = sample.quantity.doubleValue(for: HKUnit(from: "count/min"))
            unit = "count/min"
        case .heartRateVariabilitySDNN:
            value = sample.quantity.doubleValue(for: .secondUnit(with: .milli))
            unit = "ms"
        case .bodyMass:
            // Convert lb → kg as per Phase 2 schema
            let lb = sample.quantity.doubleValue(for: .pound())
            value = lb / 2.20462
            unit = "kg"
        case .height:
            value = sample.quantity.doubleValue(for: .meterUnit(with: .centi))
            unit = "cm"
        case .bodyFatPercentage:
            value = sample.quantity.doubleValue(for: .percent())
            unit = "fraction"
        case .leanBodyMass:
            // Convert lb → kg
            let lb = sample.quantity.doubleValue(for: .pound())
            value = lb / 2.20462
            unit = "kg"
        case .bodyMassIndex:
            value = sample.quantity.doubleValue(for: .count())
            unit = "count"
        case .respiratoryRate:
            value = sample.quantity.doubleValue(for: HKUnit(from: "count/min"))
            unit = "count/min"
        case .bloodGlucose:
            value = sample.quantity.doubleValue(for: HKUnit(from: "mg/dL"))
            unit = "mg/dL"
        case .bloodPressureSystolic:
            value = sample.quantity.doubleValue(for: .millimeterOfMercury())
            unit = "mmHg"
        case .bloodPressureDiastolic:
            value = sample.quantity.doubleValue(for: .millimeterOfMercury())
            unit = "mmHg"
        case .oxygenSaturation:
            value = sample.quantity.doubleValue(for: .percent())
            unit = "%"
        case .runningSpeed:
            value = sample.quantity.doubleValue(for: HKUnit(from: "m/s"))
            unit = "m/s"
        case .runningPower:
            value = sample.quantity.doubleValue(for: .watt())
            unit = "W"
        case .dietaryEnergyConsumed:
            value = sample.quantity.doubleValue(for: .kilocalorie())
            unit = "kcal"
        case .dietaryProtein:
            value = sample.quantity.doubleValue(for: .gram())
            unit = "g"
        case .dietaryCarbohydrates:
            value = sample.quantity.doubleValue(for: .gram())
            unit = "g"
        case .dietaryFatTotal:
            value = sample.quantity.doubleValue(for: .gram())
            unit = "g"
        case .dietaryFiber:
            value = sample.quantity.doubleValue(for: .gram())
            unit = "g"
        case .dietarySugar:
            value = sample.quantity.doubleValue(for: .gram())
            unit = "g"
        case .dietarySodium:
            value = sample.quantity.doubleValue(for: .gramUnit(with: .milli))
            unit = "mg"
        case .dietaryWater:
            value = sample.quantity.doubleValue(for: .liter())
            unit = "L"
        default:
            print("Unknown metric: \(metricId)")
            return
        }

        // Merge into existing accumulated value (for cumulative types like steps)
        let existing = syncMetrics[metricId] as? [String: Any]
        if var existingMetric = existing {
            if let existingTotal = existingMetric["total"] as? Double, let newVal = value as? Double {
                existingMetric["total"] = existingTotal + newVal
            } else {
                // Non-cumulative: just take the latest value
                existingMetric["latest"] = value
            }
            existingMetric["unit"] = unit
            syncMetrics[metricId] = existingMetric
        } else {
            var metric: [String: Any] = ["unit": unit]
            if let v = value as? Double {
                metric["total"] = v
            } else {
                metric["latest"] = value
            }
            syncMetrics[metricId] = metric
        }
    }

    // MARK: - Anchor Persistence

    private func loadAnchor(for metricId: String) -> HKQueryAnchor? {
        guard let data = UserDefaults.standard.data(forKey: anchorKeyPrefix + metricId) else {
            return nil
        }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private func saveAnchor(_ anchor: HKQueryAnchor, for metricId: String) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) {
            UserDefaults.standard.set(data, forKey: anchorKeyPrefix + metricId)
        }
    }

    /// Returns the anchor date as the beginning of this sync window.
    /// If no anchor exists, returns nil (query returns all historical data on first run).
    private func getAnchorDate() -> Date? {
        return nil  // Anchored queries handle this via the HKQueryAnchor itself
    }

    // MARK: - Firestore Batch Upsert

    /// Writes ONE document to kirt/daily/daily/{YYYY-MM-DD} containing all accumulated metrics.
    /// Uses setData with merge:true so each metric field is updated without overwriting
    /// the entire document (safe for concurrent syncs).
    private func writeBatchUpsert(completion: @escaping (Bool) -> Void) {
        let todayStr = String(ISO8601DateFormatter().string(from: Date()).prefix(10))

        var document: [String: Any] = [
            "date": todayStr,
            "syncedAt": FieldValue.serverTimestamp(),
            "windowStart": syncWindowStart ?? NSNull(),
            "windowEnd": FieldValue.serverTimestamp(),
        ]

        // Build metrics map keyed by canonical names (steps, sleep, heartRate, etc.)
        var metrics: [String: Any] = [:]

        // Map metric IDs to canonical names
        let metricNameMap: [String: String] = [
            "stepCount": "steps",
            "activeEnergyBurned": "activeEnergy",
            "basalEnergyBurned": "basalEnergy",
            "distanceWalkingRunning": "distanceWalkingRunning",
            "distanceSwimming": "distanceSwimming",
            "swimmingStrokeCount": "swimmingStrokes",
            "vo2Max": "vo2Max",
            "heartRate": "heartRate",
            "restingHeartRate": "heartRate",       // merged under heartRate
            "walkingHeartRateAverage": "heartRate",
            "heartRateVariabilitySDNN": "hrv",
            "bodyMass": "weight",
            "height": "height",
            "bodyFatPercentage": "bodyComposition",
            "leanBodyMass": "bodyComposition",
            "bodyMassIndex": "bodyComposition",
            "respiratoryRate": "respiratoryRate",
            "bloodGlucose": "bloodGlucose",
            "bloodPressureSystolic": "bloodPressure",
            "bloodPressureDiastolic": "bloodPressure",
            "oxygenSaturation": "oxygenSaturation",
            "runningSpeed": "runningSpeed",
            "runningPower": "runningPower",
            "dietaryEnergyConsumed": "nutrition",
            "dietaryProtein": "nutrition",
            "dietaryCarbohydrates": "nutrition",
            "dietaryFatTotal": "nutrition",
            "dietaryFiber": "nutrition",
            "dietarySugar": "nutrition",
            "dietarySodium": "nutrition",
            "dietaryWater": "dietaryWater",
        ]

        // Process accumulated metrics
        for (metricId, metricData) in syncMetrics {
            guard let canonicalName = metricNameMap[metricId] else { continue }
            if metrics[canonicalName] == nil {
                metrics[canonicalName] = [:]
            }
            if var existing = metrics[canonicalName] as? [String: Any], var newData = metricData as? [String: Any] {
                // Merge: prefer higher total for cumulative types
                if let oldTotal = existing["total"] as? Double, let newTotal = newData["total"] as? Double {
                    newData["total"] = oldTotal + newTotal
                }
                existing.merge(newData) { _, new in new }
                metrics[canonicalName] = existing
            } else {
                metrics[canonicalName] = metricData
            }
        }

        // Add workouts array
        if !syncWorkouts.isEmpty {
            metrics["workouts"] = syncWorkouts
        }

        document["metrics"] = metrics

        let docRef = db!.collection("kirt").document("daily").collection("daily").document(todayStr)

        docRef.setData(document, merge: true) { error in
            if let error = error {
                print("Firestore upsert error: \(error)")
                completion(false)
            } else {
                print("Batch upsert success: \(todayStr), \(metrics.count) metric categories")
                UserDefaults.standard.set(Date(), forKey: self.lastSyncTimeKey)
                completion(true)
            }
        }
    }
}
