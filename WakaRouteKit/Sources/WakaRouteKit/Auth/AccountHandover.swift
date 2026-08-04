import Foundation

/// Moving a learning record onto a new device.
///
/// Two operations that look symmetrical but are not: linking *adds* a way into
/// the account you already have, while signing in *replaces* the account this
/// install was using. The second can lose data, so it is guarded here rather
/// than left to each screen.
public struct AccountHandover: Sendable {

    public enum SignInRefusal: Error, Sendable, Equatable {
        /// Study sessions recorded on this device have not reached the server.
        /// Signing in now would strand them under an account the student can no
        /// longer reach.
        case unsentWork(sessions: Int)
    }

    private let auth: AuthSession
    private let timer: StudyTimer
    private let sync: StudySync

    public init(auth: AuthSession, timer: StudyTimer, sync: StudySync) {
        self.auth = auth
        self.timer = timer
        self.sync = sync
    }

    /// Attaches an email to the account this device already holds.
    ///
    /// Safe at any time: the user id does not change, so nothing moves.
    @discardableResult
    public func link(email: String, password: String, displayName: String = "") async throws -> AccountLink {
        try await auth.linkAccount(email: email, password: password, displayName: displayName)
    }

    /// Signs in, first making sure this device is not carrying work that would
    /// be lost.
    ///
    /// The local anonymous account becomes unreachable the moment we sign in as
    /// somebody else. Anything recorded here and not yet uploaded would go with
    /// it — so an upload is attempted, and if anything still will not send, the
    /// sign-in is refused and the caller is told how much is at stake.
    ///
    /// `discardingUnsentWork: true` proceeds anyway, for when the student has
    /// been shown the number and chosen to accept it.
    public func signIn(
        email: String,
        password: String,
        discardingUnsentWork: Bool = false
    ) async throws -> AuthenticatedUser {
        if !discardingUnsentWork {
            _ = await sync.run()

            let stillPending = ((try? await timer.pendingUpload()) ?? []).count
            if stillPending > 0 {
                throw SignInRefusal.unsentWork(sessions: stillPending)
            }
        }

        let user = try await auth.signIn(email: email, password: password)

        // The local sessions belong to the account this install just left. They
        // are on the server if they could be sent; keeping them here would mix
        // one student's study time into another's timeline.
        try? await timer.deleteAllSessions()

        return user
    }
}
