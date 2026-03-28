import UIKit
import Firebase
import HealthKit

class AppDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {

        // Initialize Firebase
        FirebaseApp.configure()

        // Request HealthKit authorization
        HealthKitManager.shared.requestAuthorization { success, error in
            if success {
                print("[AppDelegate] HealthKit authorization granted")
                // Write mock data first, THEN sync — completion handler ensures ordering
                print("[AppDelegate] Writing mock HealthKit data...")
                HealthKitManager.shared.writeDebugMockData { mockSuccess, mockError in
                    if mockSuccess {
                        print("[AppDelegate] Mock data written successfully, starting sync...")
                    } else {
                        print("[AppDelegate] Mock data failed: \(mockError?.localizedDescription ?? "unknown"), syncing anyway...")
                    }
                    // Sync ONLY after mock data is confirmed written
                    print("[AppDelegate] Calling startBackgroundSync...")
                    HealthKitManager.shared.startBackgroundSync()
                }
            } else if let error = error {
                print("[AppDelegate] HealthKit authorization failed: \(error.localizedDescription)")
            }
        }

        return true
    }
}
