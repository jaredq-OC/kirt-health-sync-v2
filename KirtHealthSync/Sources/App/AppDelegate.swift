import UIKit
import Firebase
import HealthKit

class AppDelegate: NSObject, UIApplicationDelegate {

    private var syncGroup = DispatchGroup()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {

        // Initialize Firebase
        FirebaseApp.configure()

        // Request HealthKit authorization
        HealthKitManager.shared.requestAuthorization { success, error in
            if success {
                print("[AppDelegate] HealthKit authorization granted")
                print("[AppDelegate] Writing mock HealthKit data...")
                HealthKitManager.shared.writeDebugMockData { mockSuccess, mockError in
                    if mockSuccess {
                        print("[AppDelegate] Mock data written successfully")
                    } else {
                        print("[AppDelegate] Mock data failed: \(mockError?.localizedDescription ?? "unknown")")
                    }
                    // Give HK a moment to index the saved samples
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        print("[AppDelegate] Starting sync with completion wait...")
                        self.syncGroup.enter()
                        HealthKitManager.shared.syncHealthData { syncSuccess in
                            print("[AppDelegate] Sync completed: \(syncSuccess)")
                            self.syncGroup.leave()
                        }
                    }
                }
            } else if let error = error {
                print("[AppDelegate] HealthKit authorization failed: \(error.localizedDescription)")
            }
        }

        // Keep app alive until sync completes (for UITest)
        DispatchQueue.global().async {
            self.syncGroup.wait()
            print("[AppDelegate] Sync group complete — app can exit")
        }

        return true
    }
}
