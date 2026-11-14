import AppKit
import Security
import SwiftUI

/// Shown once (and re-openable from Settings) after encryption is turned on. Offers Copy and
/// "Save to iCloud Keychain (Passwords)" — deliberately *not* Apple Notes, which isn't
/// end-to-end encrypted by default and would sit right next to the data it's meant to recover.
/// The primary data-encryption key itself always stays device-only in the login Keychain
/// (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, not synchronizable); this sheet only ever
/// writes a *copy* of the recovery string to a separate, synchronizable item so losing this Mac
/// doesn't mean losing the key.
struct RecoveryKeySheet: View {
    let model: AppModel
    @Binding var copied: Bool
    @Binding var savedToICloud: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var recoveryKey: String?
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Label("Your recovery key", systemImage: "key.fill")
                .font(Theme.Font.title)
                .foregroundStyle(Theme.textPrimary)

            Text("This is the only way back into your data if your login Keychain is ever lost (a fresh macOS install, a wiped Mac). Save it now — Hushy won't show it again after you close this.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)

            if let recoveryKey {
                Text(recoveryKey)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(Theme.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.bgSunken))
            } else {
                Text("No recovery key available yet.")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.error)
            }

            if let saveError {
                Text(saveError).font(Theme.Font.caption).foregroundStyle(Theme.error)
            }

            HStack(spacing: Theme.Space.s) {
                Button(copied ? "Copied" : "Copy") { copyToClipboard() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(recoveryKey == nil)
                Button(savedToICloud ? "Saved to iCloud Keychain" : "Save to iCloud Keychain (Passwords)") { saveToICloudKeychain() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(recoveryKey == nil || savedToICloud)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle())
            }

            Text("Losing both your Keychain and this recovery key means your encrypted recordings can never be recovered — not by Hushy, not by anyone.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(Theme.Space.xl)
        .frame(width: 480)
        .onAppear { recoveryKey = model.encryption.recoveryKeyForDisplay() }
    }

    private func copyToClipboard() {
        guard let recoveryKey else { return }
        RecoveryKeyClipboard.copy(recoveryKey)
        copied = true
    }

    /// Writes the recovery key string to a *separate*, synchronizable Keychain item (distinct
    /// from the device-only data-encryption key), so it round-trips through iCloud Keychain's
    /// own end-to-end encryption. Apple Notes is intentionally not offered here: it isn't
    /// end-to-end encrypted by default and would place the recovery key right next to the data
    /// it exists to recover.
    private func saveToICloudKeychain() {
        guard let recoveryKey, let data = recoveryKey.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.hushy.recovery-key",
            kSecAttrAccount as String: "hushy-recovery-key",
            kSecAttrLabel as String: "Hushy recovery key",
            kSecAttrSynchronizable as String: true,
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess {
            savedToICloud = true
            saveError = nil
        } else {
            saveError = "Couldn't save to iCloud Keychain (\(status)). Use Copy instead."
        }
    }
}
