import Foundation
import LemonSqueezyLicense

/// Manages license activation, validation, and persistence for Projector
@MainActor
final class LicenseManager: ObservableObject {
    // MARK: - Singleton

    static let shared = LicenseManager()

    // MARK: - Published Properties

    /// Whether the app is currently licensed (full license or active trial)
    @Published private(set) var isLicensed = false

    /// Whether the user has a full (non-trial) license
    @Published private(set) var hasFullLicense = false

    /// Whether the user is currently in a trial period
    @Published private(set) var isTrialActive = false

    /// Number of days remaining in trial (0 if not in trial or expired)
    @Published private(set) var trialDaysRemaining = 0

    /// Whether a trial has been used (prevents multiple trials)
    @Published private(set) var trialUsed = false

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

    /// Your Lemon Squeezy store slug (from your store URL)
    private let storeSlug = "your-store"  // TODO: Set your store slug (e.g., "musiquela")

    /// Trial duration in days
    private let trialDurationDays = 7

    // MARK: - Private Properties

    private let license = LemonSqueezyLicense()
    private let keychain = KeychainHelper.shared

    // Keychain keys
    private enum KeychainKey {
        static let licenseKey = "com.projector.licenseKey"
        static let instanceId = "com.projector.instanceId"
        static let trialStartDate = "com.projector.trialStartDate"
        static let trialEmail = "com.projector.trialEmail"
    }

    // MARK: - Initialization

    private init() {
        // Check trial status synchronously first (for UI state)
        checkTrialStatus()

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

                hasFullLicense = true
                isTrialActive = false
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
                hasFullLicense = true
                isTrialActive = false
                isLicensed = true
                statusMessage = "License valid"
                isLoading = false
                return true
            } else {
                // License is no longer valid
                hasFullLicense = false
                isLicensed = isTrialActive  // Keep licensed if trial still active
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

    // MARK: - Trial Methods

    /// Start a 7-day trial with the user's email
    /// - Parameter email: User's email address (for tracking and mailing list)
    /// - Returns: True if trial started successfully
    func startTrial(email: String) async -> Bool {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedEmail.isEmpty else {
            errorMessage = "Please enter your email address"
            return false
        }

        guard isValidEmail(trimmedEmail) else {
            errorMessage = "Please enter a valid email address"
            return false
        }

        // Check if trial was already used
        if keychain.retrieve(forKey: KeychainKey.trialStartDate) != nil {
            errorMessage = "Trial has already been used on this device"
            return false
        }

        isLoading = true
        statusMessage = "Starting trial..."

        // Add subscriber to Lemon Squeezy mailing list
        await addSubscriberToLemonSqueezy(email: trimmedEmail)

        // Store trial start date and email
        let startDate = ISO8601DateFormatter().string(from: Date())
        keychain.save(key: startDate, forKey: KeychainKey.trialStartDate)
        keychain.save(key: trimmedEmail, forKey: KeychainKey.trialEmail)

        // Update state
        checkTrialStatus()

        isLoading = false
        statusMessage = "Trial started - \(trialDaysRemaining) days remaining"
        return true
    }

    /// Add email subscriber to Lemon Squeezy mailing list
    private func addSubscriberToLemonSqueezy(email: String) async {
        let urlString = "https://\(storeSlug).lemonsqueezy.com/email-subscribe/external"
        guard let url = URL(string: urlString) else {
            debugPrint("LicenseManager: Invalid Lemon Squeezy URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyString = "email=\(email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? email)"
        request.httpBody = bodyString.data(using: .utf8)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                debugPrint("LicenseManager: Subscriber added to Lemon Squeezy (status: \(httpResponse.statusCode))")
            }
        } catch {
            // Don't fail the trial if subscriber add fails - just log it
            debugPrint("LicenseManager: Failed to add subscriber to Lemon Squeezy: \(error.localizedDescription)")
        }
    }

    /// Check current trial status and update published properties
    func checkTrialStatus() {
        // Check if trial was ever started
        guard let startDateString = keychain.retrieve(forKey: KeychainKey.trialStartDate),
              let startDate = ISO8601DateFormatter().date(from: startDateString) else {
            trialUsed = false
            isTrialActive = false
            trialDaysRemaining = 0
            return
        }

        // Trial was used at some point
        trialUsed = true

        // Calculate days remaining
        let calendar = Calendar.current
        let now = Date()
        let daysSinceStart = calendar.dateComponents([.day], from: startDate, to: now).day ?? 0
        let remaining = trialDurationDays - daysSinceStart

        if remaining > 0 {
            isTrialActive = true
            trialDaysRemaining = remaining
            isLicensed = true
            statusMessage = "\(remaining) day\(remaining == 1 ? "" : "s") left in trial"
        } else {
            isTrialActive = false
            trialDaysRemaining = 0
            // Don't set isLicensed = false here, let checkExistingLicense handle full license check
        }
    }

    /// Get the email used for trial (if any)
    var trialEmail: String? {
        keychain.retrieve(forKey: KeychainKey.trialEmail)
    }

    // MARK: - Private Methods

    /// Validate email format
    private func isValidEmail(_ email: String) -> Bool {
        let emailRegex = #"^[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
        return email.range(of: emailRegex, options: .regularExpression) != nil
    }

    /// Check if we have an existing license on app launch
    private func checkExistingLicense() async {
        // First check trial status
        checkTrialStatus()

        // Then check for full license
        guard keychain.retrieve(forKey: KeychainKey.licenseKey) != nil else {
            // No full license - isLicensed is already set by checkTrialStatus if trial is active
            if !isTrialActive {
                isLicensed = false
            }
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
