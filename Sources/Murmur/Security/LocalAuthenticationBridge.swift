import LocalAuthentication
import MurmurCore

/// The real Touch ID / password authenticator, bridging `LAContext` to `DeviceAuthenticating`
/// so `AppLockController` (in MurmurCore, which can't import LocalAuthentication the same way a
/// plain SPM library target would want to) can stay a plain, testable state machine.
struct LocalAuthenticationBridge: DeviceAuthenticating {
    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}
