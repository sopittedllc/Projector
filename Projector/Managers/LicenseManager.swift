import Foundation
import LemonSqueezyLicense

/// Manages license activation, validation, and persistence for Projector
@MainActor
final class LicenseManager: ObservableObject {
    // MARK: - Singleton

    static let shared = LicenseManager()

    // MARK: - Published Properties

    /// Whether the app is currently licensed
    @Published private(set) var isLicensed = false

    /// Current license status message
    @Published private(set) var statusMessage = ""

    /// Whether a license operation is in progress
    @Published private(set) var isLoading = false

    /// Error message if last operation failed
    @Published var errorMessage: String?

    // MARK: - Configuration

    /// Your Lemon Squeezy Store ID - verify responses match this
    private let expectedStoreId = 0  // TODO: Set your store ID

    /// Your Lemon Squeezy Product ID - verify responses match this
    private let expectedProductId = 0  // TODO: Set your product ID

    // MARK: - Private Properties

    private let license = LemonSqueezyLicense()
    private let keychain = KeychainHelper.shared

    // Keychain keys
    private enum KeychainKey {
        static let licenseKey = "com.projector.licenseKey"
        static let instanceId = "com.projector.instanceId"
    }

    // MARK: - Initialization

    private init() {
        // Check if we have stored credentials on init
        Task {
            await checkExistingLicense()
        }
    }

    // MARK: - Public Methods

    /// Activate a new license key
    /// - Parameter key: The license key from Lemon Squeezy
    /// - Returns: True if activation succeeded
    func activate(key: String) async -> Bool {
        guard !key.isEmpty else {
            errorMessage = "Please enter a license key"
            return false
        }

        isLoading = true
        errorMessage = nil
        statusMessage = "Activating license..."

        do {
            let instanceName = Host.current().localizedName ?? "Mac"
            let response = try await license.activate(key: key, instanceName: instanceName)

            if response.activated {
                // Store credentials securely
                if let instanceId = response.instance?.id {
                    keychain.save(key: key, forKey: KeychainKey.licenseKey)
                    keychain.save(key: instanceId, forKey: KeychainKey.instanceId)
                }

                isLicensed = true
                statusMessage = "License activated successfully"
                isLoading = false
                return true
            } else {
                errorMessage = "Activation failed - please check your license key"
                isLoading = false
                return false
            }
        } catch let error as LemonSqueezyLicenseError {
            handleLicenseError(error)
            isLoading = false
            return false
        } catch {
            errorMessage = "Network error: \(error.localizedDescription)"
            isLoading = false
            return false
        }
    }

    /// Validate the current license
    /// - Returns: True if the license is valid
    func validate() async -> Bool {
        guard let key = keychain.retrieve(forKey: KeychainKey.licenseKey),
              let instanceId = keychain.retrieve(forKey: KeychainKey.instanceId) else {
            isLicensed = false
            return false
        }

        isLoading = true
        statusMessage = "Validating license..."

        do {
            let response = try await license.validate(key: key, instanceId: instanceId)

            if response.valid {
                isLicensed = true
                statusMessage = "License valid"
                isLoading = false
                return true
            } else {
                // License is no longer valid
                isLicensed = false
                statusMessage = "License invalid or expired"
                isLoading = false
                return false
            }
        } catch let error as LemonSqueezyLicenseError {
            handleLicenseError(error)
            // Don't immediately revoke on network errors - be graceful
            if case .badServerResponse = error {
                // Network issue, keep current state
                isLoading = false
                return isLicensed
            }
            isLicensed = false
            isLoading = false
            return false
        } catch {
            // Network error - be graceful, keep current state
            statusMessage = "Could not validate - working offline"
            isLoading = false
            return isLicensed
        }
    }

    /// Deactivate the current license (e.g., when user wants to move to another machine)
    func deactivate() async -> Bool {
        guard let key = keychain.retrieve(forKey: KeychainKey.licenseKey),
              let instanceId = keychain.retrieve(forKey: KeychainKey.instanceId) else {
            return false
        }

        isLoading = true
        statusMessage = "Deactivating license..."

        do {
            let response = try await license.deactivate(key: key, instanceId: instanceId)

            if response.deactivated {
                // Clear stored credentials
                keychain.delete(forKey: KeychainKey.licenseKey)
                keychain.delete(forKey: KeychainKey.instanceId)

                isLicensed = false
                statusMessage = "License deactivated"
                isLoading = false
                return true
            } else {
                errorMessage = "Deactivation failed"
                isLoading = false
                return false
            }
        } catch {
            errorMessage = "Failed to deactivate: \(error.localizedDescription)"
            isLoading = false
            return false
        }
    }

    // MARK: - Private Methods

    /// Check if we have an existing license on app launch
    private func checkExistingLicense() async {
        guard keychain.retrieve(forKey: KeychainKey.licenseKey) != nil else {
            isLicensed = false
            return
        }

        // We have stored credentials, validate them
        _ = await validate()
    }

    /// Handle license-specific errors
    private func handleLicenseError(_ error: LemonSqueezyLicenseError) {
        switch error {
        case .badServerResponse:
            errorMessage = "Could not connect to license server"
        case .serverError(let statusCode, let message):
            if statusCode == 404 {
                errorMessage = "License key not found"
            } else if statusCode == 400 {
                errorMessage = message ?? "Invalid license key"
            } else {
                errorMessage = message ?? "Server error (\(statusCode))"
            }
        }
    }
}

// MARK: - Keychain Helper

/// Simple keychain wrapper for storing license credentials securely
final class KeychainHelper {
    static let shared = KeychainHelper()

    private init() {}

    func save(key value: String, forKey key: String) {
        let data = Data(value.utf8)

        // Delete any existing item first
        delete(forKey: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        SecItemAdd(query as CFDictionary, nil)
    }

    func retrieve(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        return string
    }

    func delete(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]

        SecItemDelete(query as CFDictionary)
    }
}
