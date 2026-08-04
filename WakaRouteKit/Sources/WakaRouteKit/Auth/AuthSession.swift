import Foundation

/// Owns the credential lifecycle: silent registration on first launch, token
/// renewal, and recovery.
///
/// This is an actor for one specific reason. The refresh token is single-use
/// and the server treats a replay as theft by killing every session on the
/// account. Two screens refreshing at once, or a retry after a timeout, would
/// present the same token twice and sign the student out everywhere. All
/// renewal therefore funnels through one serialized path, and a renewal that
/// fails is never retried with the same token — recovery goes through the
/// device secret instead.
public actor AuthSession {
    private enum StorageKey {
        static let deviceSecret = "deviceSecret"
        static let refreshToken = "refreshToken"
    }

    private let client: DeviceAuthClient
    private let store: SecretStore
    private let deviceIdProvider: DeviceIdProvider
    private let now: @Sendable () -> Date

    private var tokens: AuthTokens?
    /// The single renewal in progress, if any. Concurrent callers await this
    /// rather than starting their own.
    private var renewal: Task<AuthTokens, Error>?

    public init(
        client: DeviceAuthClient,
        store: SecretStore,
        deviceIdProvider: DeviceIdProvider,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.store = store
        self.deviceIdProvider = deviceIdProvider
        self.now = now
    }

    /// The token to put in an `Authorization` header, registering or renewing
    /// first if needed. Safe to call from anywhere, concurrently.
    public func validAccessToken() async throws -> String {
        if let tokens, tokens.isFresh(at: now()) {
            return tokens.accessToken
        }
        return try await renewTokens().accessToken
    }

    /// True once this install has an account. Drives whether the UI can offer
    /// account linking.
    public func hasRegisteredDevice() throws -> Bool {
        try store.read(StorageKey.deviceSecret) != nil
    }

    /// The identifier this install registered under.
    ///
    /// A label, not a secret — it is safe to show for support and QA. The
    /// device *secret* is never exposed by this type at all.
    public func registeredDeviceId() throws -> String? {
        guard try hasRegisteredDevice() else { return nil }
        return try deviceIdProvider.deviceId()
    }

    /// When the current access token expires, for diagnostics.
    public func accessTokenExpiry() -> Date? {
        tokens?.expiresAt
    }

    public func currentUser() -> AuthenticatedUser? {
        tokens?.user
    }

    /// Forgets the cached access token so the next request renews.
    /// The refresh token and device secret are untouched.
    func forgetAccessToken() {
        tokens = nil
    }

    // MARK: - Renewal

    private func renewTokens() async throws -> AuthTokens {
        if let renewal {
            return try await renewal.value
        }

        let task = Task<AuthTokens, Error> { [self] in
            try await performRenewal()
        }
        renewal = task

        defer { renewal = nil }
        return try await task.value
    }

    /// Tries the cheapest credential first and falls back down the chain:
    /// refresh token → device secret → fresh registration.
    private func performRenewal() async throws -> AuthTokens {
        if let refreshToken = try store.read(StorageKey.refreshToken) {
            do {
                return try await persist(try await client.refresh(refreshToken: refreshToken))
            } catch {
                // Deliberately no retry with this token. Even a timeout may
                // have been processed server-side, which would have already
                // rotated it; presenting it again is what triggers the
                // session-wide revocation. Drop it and recover instead.
                try? store.delete(StorageKey.refreshToken)
            }
        }

        if let deviceSecret = try store.read(StorageKey.deviceSecret) {
            let deviceId = try deviceIdProvider.deviceId()
            do {
                let renewed = try await client.tokensFromDeviceSecret(
                    deviceId: deviceId,
                    deviceSecret: deviceSecret
                )
                return try await persist(renewed)
            } catch AuthError.deviceRejected {
                // Secret no longer valid. Re-registering with the same deviceId
                // returns the same account, so history is not lost.
                try? store.delete(StorageKey.deviceSecret)
            }
        }

        return try await registerDevice().auth
    }

    // MARK: - Registration

    /// Registers this install. Idempotent by `deviceId`: a second call returns
    /// the same account with `isNewAccount: false`.
    @discardableResult
    public func registerDevice() async throws -> DeviceRegistration {
        let deviceId = try deviceIdProvider.deviceId()
        let registration = try await client.register(deviceId: deviceId)

        // The secret exists only in this response. Store it before anything
        // else can fail.
        try store.write(registration.deviceSecret, for: StorageKey.deviceSecret)
        _ = try await persist(registration.auth)

        return registration
    }

    @discardableResult
    private func persist(_ newTokens: AuthTokens) async throws -> AuthTokens {
        try store.write(newTokens.refreshToken, for: StorageKey.refreshToken)
        tokens = newTokens
        return newTokens
    }

    // MARK: - Deletion

    /// Closes the account and clears every local credential.
    ///
    /// Order matters: the server is asked first, and local state is cleared
    /// only after it confirms. Clearing first would leave an orphaned account
    /// on the server that the student can no longer reach or delete.
    ///
    /// Irreversible.
    public func deleteAccount() async throws {
        let accessToken = try await validAccessToken()
        try await client.deleteAccount(accessToken: accessToken)

        // Only now is it safe to forget.
        try? store.delete(StorageKey.deviceSecret)
        try? store.delete(StorageKey.refreshToken)
        tokens = nil
        renewal?.cancel()
        renewal = nil
    }

    // MARK: - Linking

    /// Attaches an email so progress survives a new phone. Offered after the
    /// student has history worth keeping — never as a launch screen.
    ///
    /// The user id does not change, so nothing needs migrating: this adds a way
    /// in, it does not move the account.
    @discardableResult
    public func linkAccount(
        email: String,
        password: String,
        displayName: String = ""
    ) async throws -> AccountLink {
        let accessToken = try await validAccessToken()
        return try await client.link(
            accessToken: accessToken,
            email: email,
            password: password,
            displayName: displayName
        )
    }

    /// Signs in on a device that already has its own anonymous account.
    ///
    /// **Replaces the local account.** Whatever this install had recorded under
    /// its anonymous identity becomes unreachable, so the caller must deal with
    /// anything still unsent *before* calling this — see
    /// `AccountHandover.signIn`, which refuses while work is queued rather than
    /// silently discarding a student's study time.
    ///
    /// The device secret is cleared: this install is no longer the anonymous
    /// learner it registered as.
    public func signIn(email: String, password: String) async throws -> AuthenticatedUser {
        let renewed = try await client.signIn(email: email, password: password)

        try? store.delete(StorageKey.deviceSecret)
        _ = try await persist(renewed)

        return renewed.user
    }
}
