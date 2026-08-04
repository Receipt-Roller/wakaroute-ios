import OSLog
import SwiftUI
import WakaRouteKit

/// Never log names, emails, tokens, answers, or study history — §9 of the
/// 開発ガイド. Messages here describe state, never content.
let logger = Logger(subsystem: "com.wakaroute.app", category: "app")

@main
struct WakaRouteApp: App {
    @State private var services = AppServices.live()
    @State private var update: UpdateDecision = .allowed

    var body: some Scene {
        WindowGroup {
            Group {
                if case let .required(message, storeUrl) = update {
                    UpdateRequiredView(message: message, storeUrl: storeUrl)
                } else {
                    RootView(services: services)
                }
            }
            .task {
                // Registration happens silently on first launch. There is
                // no sign-up screen, so a failure here must never block the
                // student from the parts of the app that need no account.
                await registerIfNeeded()
                await checkForRequiredUpdate()
            }
        }
    }

    /// Asks whether this build may still run.
    ///
    /// Deliberately **after** registration, and it sends anything queued before
    /// putting up the wall: study time and offline quiz answers live on the
    /// device until they are uploaded, and a student who cannot get past the
    /// update screen could never send them. Losing a week of recorded revision
    /// to a version bump would be unforgivable.
    ///
    /// If the check itself fails, nothing happens — see `AppVersionGate`.
    private func checkForRequiredUpdate() async {
        let decision = await services.versionGate.decision(for: Bundle.main.shortVersion)
        guard case .required = decision else {
            update = decision
            return
        }

        _ = await services.studySync.run()
        _ = await services.actionQueue.run()
        update = decision
    }

    private func registerIfNeeded() async {
        do {
            // Registers on first launch, renews on later ones. Either way the
            // student sees nothing — no sign-up screen, no spinner.
            _ = try await services.auth.validAccessToken()

            // Confirms the account is usable end to end. Nothing is shown on
            // success; a failure here must not block the app either.
            let profile = try await services.profile.profile()
            logger.info("Learner session ready. Linked: \(profile.isLinked, privacy: .public)")
        } catch AuthError.applicationNotConfigured {
            // Server-side configuration is incomplete. Nothing the student can
            // do, and nothing worth interrupting them over — school search and
            // the guides still work. Deliberately not an assertion: this must
            // stay non-fatal even in Debug, or it blocks exactly the people who
            // need to keep working while the server is being configured.
            logger.error("Device registration is not enabled for this client. Signed-in features are unavailable.")
        } catch {
            // Retried on next launch, and on demand when a signed-in feature is
            // actually reached.
        }
    }
}
