import SwiftUI
import WakaRouteKit

@MainActor
@Observable
final class AccountViewModel {
    enum State {
        case loading
        case ready(LearnerProfile)
        case notRegistered
        case failed(message: String)
    }

    enum DeletionState: Equatable {
        case idle
        case deleting
        case deleted
        case failed(message: String)
    }

    private(set) var state: State = .loading
    private(set) var deviceId: String?
    private(set) var tokenExpiry: Date?
    private(set) var deletion: DeletionState = .idle

    private let auth: AuthSession
    private let profile: ProfileClient
    private let studyTimer: StudyTimer
    let handover: AccountHandover

    init(auth: AuthSession, profile: ProfileClient, studyTimer: StudyTimer, handover: AccountHandover) {
        self.auth = auth
        self.profile = profile
        self.studyTimer = studyTimer
        self.handover = handover
    }

    /// Closes the account and clears everything held on this device.
    ///
    /// The server is asked first. Local data is cleared only after it confirms,
    /// so a failure never leaves an account the student can no longer reach.
    func deleteAccount() async {
        deletion = .deleting
        do {
            try await auth.deleteAccount()
            // Study sessions live only on this device until the sync API
            // exists. Leaving them would keep a record of someone who asked to
            // be forgotten.
            try? await studyTimer.deleteAllSessions()
            deletion = .deleted
        } catch let error as AuthError {
            deletion = .failed(message: Self.describe(error))
        } catch {
            deletion = .failed(message: "削除できませんでした。通信状況を確認してください。")
        }
    }

    /// Actively completes registration rather than only reporting on it.
    ///
    /// Launch registration is fire-and-forget and swallows failures by design,
    /// so this screen must be able to drive it and say precisely what went
    /// wrong — otherwise every cause looks identical to "not registered".
    func load() async {
        state = .loading

        do {
            _ = try await auth.validAccessToken()
        } catch let error as AuthError {
            state = .failed(message: Self.describe(error))
            return
        } catch let error as SecretStoreError {
            state = .failed(message: "端末に保存できませんでした。\(error.diagnosticDescription)")
            return
        } catch {
            state = .failed(message: "登録できませんでした。通信状況を確認してください。")
            return
        }

        deviceId = try? await auth.registeredDeviceId()
        tokenExpiry = await auth.accessTokenExpiry()

        guard (try? await auth.hasRegisteredDevice()) == true else {
            // Tokens were obtained but the secret did not persist — the account
            // exists on the server and would be lost on next launch.
            state = .failed(message: "登録はできましたが、端末に保存できませんでした。キーチェーンを確認してください。")
            return
        }

        do {
            state = .ready(try await profile.profile())
        } catch let error as AuthError {
            state = .failed(message: Self.describe(error))
        } catch {
            state = .failed(message: "アカウント情報を取得できませんでした。")
        }
    }

    private static func describe(_ error: AuthError) -> String {
        switch error {
        case .applicationNotConfigured:
            "サーバー側の設定が完了していません（403 admin_required）。"
        case let .rateLimited(retryAfter):
            "登録の回数制限に達しました。\(retryAfter.map { "\(Int($0))秒" } ?? "しばらく")待って再試行してください。"
        case .deviceRejected:
            "この端末の登録が無効になっています。"
        case .alreadyLinked:
            "すでに連携済みのアカウントです。"
        case .emailInUse:
            "このメールアドレスは使用されています。"
        case let .api(underlying):
            switch underlying {
            case .offline: "インターネットに接続されていません。"
            case .timedOut: "通信がタイムアウトしました。"
            case let .http(status, problem):
                "サーバーエラー（\(status)\(problem?.code.map { " \($0)" } ?? "")）"
            case let .decoding(detail): "応答を読み取れませんでした。\(detail.prefix(80))"
            case let .unknown(detail): detail
            }
        }
    }
}

/// アカウント — what protects this student's learning record.
///
/// Framed as 「学習記録の引き継ぎ」 rather than 「アカウント登録」, per §6 of the
/// 実装ガイド: the student cares about not losing three years of work, not
/// about having an account.
struct AccountView: View {
    @State var viewModel: AccountViewModel
    @State private var isConfirmingDeletion = false
    @State private var handoverMode: HandoverViewModel.Mode?

    var body: some View {
        List {
            switch viewModel.state {
            case .loading:
                HStack { Spacer(); ProgressView(); Spacer() }

            case .notRegistered:
                Section {
                    Label("この端末はまだ登録されていません", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                } footer: {
                    Text("通信できる状態でアプリを開きなおすと登録されます。")
                }

            case let .failed(message):
                Section {
                    Label {
                        Text(message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }

                    Button("再試行") { Task { await viewModel.load() } }

                    #if DEBUG
                    if let deviceId = viewModel.deviceId {
                        LabeledContent("デバイスID") {
                            Text(deviceId).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    #endif
                } header: {
                    Text("登録できていません")
                } footer: {
                    Text("この画面を開くたびに登録を試みます。")
                }

            case let .ready(profile):
                statusSection(profile: profile)
                handoverSection(profile: profile)
                deletionSection(profile: profile)
                #if DEBUG
                diagnosticsSection(profile: profile)
                #endif
            }
        }
        .navigationTitle("アカウント")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
        .sheet(item: $handoverMode) { mode in
            AccountHandoverView(
                viewModel: HandoverViewModel(mode: mode, handover: viewModel.handover)
            )
            .onDisappear { Task { await viewModel.load() } }
        }
        .confirmationDialog(
            "学習記録を削除しますか？",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("削除する", role: .destructive) {
                Task { await viewModel.deleteAccount() }
            }
            Button("やめる", role: .cancel) {}
        } message: {
            // Names exactly what is lost. 「本当によろしいですか」 tells a 中学生
            // nothing about what they are agreeing to.
            Text("学習の記録（レッスン・クイズ）、志望校、学習時間の記録がすべて消えます。もとに戻すことはできません。")
        }
    }

    /// Required by App Store Review 5.1.1(v): an app that creates accounts must
    /// let the user delete one from inside the app. ワカルート creates one
    /// silently at first launch, so this applies even though there is no
    /// sign-up screen anywhere.
    @ViewBuilder
    private func deletionSection(profile: LearnerProfile) -> some View {
        Section {
            switch viewModel.deletion {
            case .idle:
                Button("学習記録を削除する", role: .destructive) {
                    isConfirmingDeletion = true
                }

            case .deleting:
                HStack { ProgressView(); Text("削除しています").foregroundStyle(.secondary) }

            case .deleted:
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("削除しました").font(.subheadline)
                        Text("アプリを開きなおすと、新しく始められます。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }

            case let .failed(message):
                VStack(alignment: .leading, spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.subheadline).foregroundStyle(.orange)
                    Button("再試行") { Task { await viewModel.deleteAccount() } }
                }
            }
        } header: {
            Text("削除")
        } footer: {
            if case .idle = viewModel.deletion {
                Text(profile.isLinked
                     ? "アカウントと学習記録を削除します。メールアドレスの登録も解除されます。"
                     : "この端末の学習記録を削除します。もとに戻すことはできません。")
            }
        }
    }

    private func statusSection(profile: LearnerProfile) -> some View {
        Section {
            if profile.isLinked {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("学習記録は保護されています").font(.subheadline)
                        Text(profile.email).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                }
            } else {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("学習記録はこの端末にあります").font(.subheadline)
                        Text("機種変更やアプリの削除で失われます。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "iphone").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("学習記録")
        }
    }

    /// Offered, never nagged. The 実装ガイド is explicit that prompting at
    /// install turns this back into the sign-up screen we deliberately avoided.
    @ViewBuilder
    private func handoverSection(profile: LearnerProfile) -> some View {
        if !profile.isLinked {
            Section {
                Button {
                    handoverMode = .link
                } label: {
                    Label("学習記録を引き継げるようにする", systemImage: "arrow.right.circle")
                }

                Button {
                    handoverMode = .signIn
                } label: {
                    Label("前の記録を呼び出す", systemImage: "arrow.down.circle")
                }
            } footer: {
                Text("メールアドレスを登録すると、新しい端末でも同じ記録を続けられます。")
            }
        }
    }

    #if DEBUG
    /// Build-time only. Enough to confirm on-device which learner this install
    /// is, without ever showing the device secret.
    private func diagnosticsSection(profile: LearnerProfile) -> some View {
        Section {
            LabeledContent("ユーザーID") {
                Text(profile.userId).font(.caption.monospaced()).textSelection(.enabled)
            }
            if let deviceId = viewModel.deviceId {
                LabeledContent("デバイスID") {
                    Text(deviceId).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            if let organizationId = profile.organizationId {
                LabeledContent("組織ID") {
                    Text(organizationId).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            if let expiry = viewModel.tokenExpiry {
                LabeledContent("トークン有効期限") {
                    Text(expiry.formatted(date: .omitted, time: .standard)).font(.caption.monospaced())
                }
            }
        } header: {
            Text("開発者向け")
        } footer: {
            Text("デバッグビルドのみ表示されます。デバイスシークレットは表示しません。")
        }
    }
    #endif
}
