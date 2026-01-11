import Foundation

/// Manages license activation, validation, and persistence for Projector
/// Uses Gumroad's license verification API
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

    /// Your Gumroad Product ID - found on product edit page under "License key" section
    private let gumroadProductId = ""  // TODO: Set your Gumroad product ID (e.g., "abc123XYZ")

    /// Trial duration in days
    private let trialDurationDays = 7

    /// Gumroad API base URL
    private let gumroadAPIBaseURL = "https://api.gumroad.com/v2"

    // MARK: - Private Properties

    private let keychain = KeychainHelper.shared

    // Keychain keys
    private enum KeychainKey {
        static let licenseKey = "com.projector.licenseKey"
        static let purchaseEmail = "com.projector.purchaseEmail"
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
    /// - Parameter key: The license key from Gumroad
    /// - Returns: True if activation succeeded
    func activate(key: String) async -> Bool {
        guard !key.isEmpty else {
            errorMessage = "Please enter a license key"
            return false
        }

        isLoading = true
        errorMessage = nil
        statusMessage = "Activating license..."

        // Verify with Gumroad, incrementing use count (first activation)
        let result = await verifyLicenseWithGumroad(key: key, incrementUses: true)

        switch result {
        case .success(let response):
            // Store credentials securely
            keychain.save(key: key, forKey: KeychainKey.licenseKey)
            if let email = response.purchase?.email {
                keychain.save(key: email, forKey: KeychainKey.purchaseEmail)
            }

            hasFullLicense = true
            isTrialActive = false
            isLicensed = true
            statusMessage = "License activated successfully"
            isLoading = false
            return true

        case .failure(let error):
            errorMessage = error.userMessage
            isLoading = false
            return false
        }
    }

    /// Validate the current license
    /// - Returns: True if the license is valid
    func validate() async -> Bool {
        guard let key = keychain.retrieve(forKey: KeychainKey.licenseKey) else {
            isLicensed = isTrialActive
            return isTrialActive
        }

        isLoading = true
        statusMessage = "Validating license..."

        // Verify with Gumroad without incrementing use count
        let result = await verifyLicenseWithGumroad(key: key, incrementUses: false)

        switch result {
        case .success(let response):
            // Check if the license is still valid (not refunded or chargedback)
            if response.purchase?.refunded == true || response.purchase?.chargedback == true {
                hasFullLicense = false
                isLicensed = isTrialActive
                statusMessage = "License has been refunded"
                isLoading = false
                return false
            }

            hasFullLicense = true
            isTrialActive = false
            isLicensed = true
            statusMessage = "License valid"
            isLoading = false
            return true

        case .failure(let error):
            // Be graceful on network errors - keep current state
            if case .networkError = error {
                statusMessage = "Could not validate - working offline"
                isLoading = false
                return isLicensed
            }

            hasFullLicense = false
            isLicensed = isTrialActive
            statusMessage = error.userMessage
            isLoading = false
            return false
        }
    }

    /// Deactivate the current license (clears local credentials)
    /// Note: Gumroad doesn't support remote deactivation, this only clears local storage
    func deactivate() async -> Bool {
        isLoading = true
        statusMessage = "Deactivating license..."

        // Clear stored credentials
        keychain.delete(forKey: KeychainKey.licenseKey)
        keychain.delete(forKey: KeychainKey.purchaseEmail)

        hasFullLicense = false
        isLicensed = isTrialActive
        statusMessage = "License deactivated"
        isLoading = false
        return true
    }

    // MARK: - Trial Methods

    /// Start a 7-day trial with the user's email
    /// - Parameter email: User's email address (for tracking)
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

    // MARK: - Gumroad API

    /// Gumroad license verification response
    private struct GumroadResponse: Codable {
        let success: Bool
        let uses: Int?
        let purchase: Purchase?
        let message: String?

        struct Purchase: Codable {
            let email: String?
            let refunded: Bool?
            let chargedback: Bool?
            let subscriptionEndedAt: String?
            let subscriptionCancelledAt: String?
            let subscriptionFailedAt: String?

            enum CodingKeys: String, CodingKey {
                case email, refunded, chargedback
                case subscriptionEndedAt = "subscription_ended_at"
                case subscriptionCancelledAt = "subscription_cancelled_at"
                case subscriptionFailedAt = "subscription_failed_at"
            }
        }
    }

    /// Gumroad license verification errors
    private enum GumroadError: Error {
        case invalidLicenseKey
        case productNotFound
        case networkError(Error)
        case invalidResponse
        case serverError(String)

        var userMessage: String {
            switch self {
            case .invalidLicenseKey:
                return "Invalid license key"
            case .productNotFound:
                return "Product not found"
            case .networkError:
                return "Could not connect to license server"
            case .invalidResponse:
                return "Invalid response from license server"
            case .serverError(let message):
                return message
            }
        }
    }

    /// Verify a license key with Gumroad's API
    /// - Parameters:
    ///   - key: The license key to verify
    ///   - incrementUses: Whether to increment the use count (true for activation, false for validation)
    /// - Returns: Result with response or error
    private func verifyLicenseWithGumroad(key: String, incrementUses: Bool) async -> Result<GumroadResponse, GumroadError> {
        guard let url = URL(string: "\(gumroadAPIBaseURL)/licenses/verify") else {
            return .failure(.invalidResponse)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // Build form data
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "product_id", value: gumroadProductId),
            URLQueryItem(name: "license_key", value: key),
            URLQueryItem(name: "increment_uses_count", value: incrementUses ? "true" : "false")
        ]
        request.httpBody = components.query?.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }

            // Gumroad returns 404 for invalid license keys
            if httpResponse.statusCode == 404 {
                // Try to parse error message
                if let errorResponse = try? JSONDecoder().decode(GumroadResponse.self, from: data),
                   let message = errorResponse.message {
                    return .failure(.serverError(message))
                }
                return .failure(.invalidLicenseKey)
            }

            guard httpResponse.statusCode == 200 else {
                return .failure(.serverError("Server error (\(httpResponse.statusCode))"))
            }

            let gumroadResponse = try JSONDecoder().decode(GumroadResponse.self, from: data)

            if gumroadResponse.success {
                return .success(gumroadResponse)
            } else {
                let message = gumroadResponse.message ?? "License verification failed"
                return .failure(.serverError(message))
            }

        } catch let error as DecodingError {
            debugPrint("LicenseManager: Decoding error: \(error)")
            return .failure(.invalidResponse)
        } catch {
            debugPrint("LicenseManager: Network error: \(error)")
            return .failure(.networkError(error))
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
