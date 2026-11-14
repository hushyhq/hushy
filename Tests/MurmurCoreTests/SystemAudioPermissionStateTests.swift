import Foundation
import Testing
@testable import MurmurCore

/// Covers `SystemAudioPermissionState`'s pure decision logic: whether capture should be
/// attempted, and what (if anything) to tell the user — see the task's contract to "handle
/// permission request/denial gracefully (clear message + link to System Settings; never change
/// settings yourself)". The actual `CGPreflightScreenCaptureAccess` call this state is derived
/// from (in `SystemAudioCapture.permissionState()`) is not unit-testable (it depends on live TCC
/// state), so this suite covers everything downstream of that single system call.
@Suite("System audio permission state")
struct SystemAudioPermissionStateTests {
    @Test("capture is attempted unless the OS can't do it (taps have no preflight)")
    func attemptUnlessUnsupported() {
        #expect(SystemAudioPermissionState.granted.canCapture)
        #expect(SystemAudioPermissionState.notDetermined.canCapture)
        #expect(SystemAudioPermissionState.denied.canCapture)
        #expect(!SystemAudioPermissionState.unsupported.canCapture)
    }

    @Test("only denied and unsupported show a message")
    func messages() {
        #expect(SystemAudioPermissionState.granted.userMessage == nil)
        #expect(SystemAudioPermissionState.notDetermined.userMessage == nil)
        #expect(SystemAudioPermissionState.denied.userMessage != nil)
        #expect(SystemAudioPermissionState.unsupported.userMessage != nil)
    }

    @Test("denied message never asks for Screen Recording itself, only the audio-only option")
    func deniedMessageIsAudioOnly() {
        let message = SystemAudioPermissionState.denied.userMessage ?? ""
        #expect(message.contains("System Audio Recording Only"))
    }

    @Test("real signal means granted; 10 s of zeros while the mic hears speech means denied")
    func verdicts() {
        #expect(SystemAudioVerdict.verdict(systemPeak: 0.02, systemSeconds: 3, micRMS: 0) == .granted)
        #expect(SystemAudioVerdict.verdict(systemPeak: 0, systemSeconds: 12, micRMS: 0.03) == .denied)
        #expect(SystemAudioVerdict.verdict(systemPeak: 0, systemSeconds: 5, micRMS: 0.03) == nil)
        #expect(SystemAudioVerdict.verdict(systemPeak: 0, systemSeconds: 30, micRMS: 0.001) == nil)
    }

    @Test("denied message points toward System Settings without instructing the app to change it")
    func deniedMessageMentionsSystemSettings() {
        let message = SystemAudioPermissionState.denied.userMessage ?? ""
        #expect(message.localizedCaseInsensitiveContains("System Settings"))
    }

    @Test("unsupported message explains the macOS version requirement")
    func unsupportedMessageExplainsRequirement() {
        let message = SystemAudioPermissionState.unsupported.userMessage ?? ""
        #expect(message.contains("14.4") || message.localizedCaseInsensitiveContains("Screen Recording"))
    }
}
