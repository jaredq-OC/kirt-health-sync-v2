import UIKit
import Firebase
import HealthKit

class AppDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {

        // Check for UITesting mode via launch argument (set by XCTest in app.launchArguments)
        // Also check XCTest environment variable (always set when running under XCTest runner)
        let isUITesting = ProcessInfo.processInfo.environment["XCTest"] != nil ||
                          ProcessInfo.processInfo.arguments.contains("--uitesting")

        if isUITesting {
            print("[UITesting] Skipping Firebase and HealthKit initialization")
            return true
        }

        // Initialize Firebase
        FirebaseApp.configure()

        // Request HealthKit authorization
        HealthKitManager.shared.requestAuthorization { success, error in
            if success {
                print("HealthKit authorization granted")
                // Start background sync once authorized
                HealthKitManager.shared.startBackgroundSync()
            } else if let error = error {
                print("HealthKit authorization failed: \(error.localizedDescription)")
            }
        }

        return true
    }
}
