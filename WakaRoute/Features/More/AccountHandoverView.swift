import Foundation
import Observation
import SwiftUI
import WakaRouteKit

@MainActor
@Observable
final class HandoverViewModel {
    enum Mode: String, Identifiable { case link, signIn; var id: String { rawValue } }
    enum Phase: Equatable {
        case editing
        case working
        case done(email: String)
        case failed(message: String)
        /// Sign-in would strand study time recorded on this device.
        case blockedByUnsentWork(sessions: Int)
    }

    var email = ""
    var password = ""
    private(set) var phase: Phase = .editing

    let mode: Mode
    private let handover: AccountHandover

    init(mode: Mode, handover: AccountHandover) {
        self.mode = mode
        self.handover = handover
    }

    /// The server's rules, stated up front rather than after a rejection.
    static let passwordRequirement = "6文字以上で、大文字・小文字・記号をそれぞれ1つ以上入れてください。"

    var canSubmit: Bool {
        guard case .editing = phase else { return false }
        return email.contains("@") && password.count >= 6
    }

    func submit(discardingUnsentWork: Bool = false) async {
        guard canSubmit || discardingUnsentWork else { return }
        phase = .working

        do {
            switch mode {
            case .link:
                _ = try await handover.link(email: email, password: password)
            case .signIn:
                _ = try await handover.signIn(
                    email: email,
                    password: password,
                    discardingUnsentWork: discardingUnsentWork
                )
            }
            phase = .done(email: email)
        } catch let refusal as AccountHandover.SignInRefusal {
            if case let .unsentWork(sessions) = refusal {
                phase = .blockedByUnsentWork(sessions: sessions)
            }
        } catch let error as AuthError {
            phase = .failed(message: Self.describe(error, mode: mode))
        } catch {
            phase = .failed(message: "通信できませんでした。電波の良いところで試してください。")
        }
    }

    func backToEditing() { phase = .editing }

    private static func describe(_ error: AuthError, mode: Mode) -> String {
        switch error {
        case .alreadyLinked:
            "この端末の記録には、すでにメールアドレスが登録されています。"
        case .emailInUse:
            mode == .link
                ? "このメールアドレスは別の記録で使われています。そちらにログインすると、その記録を続けられます。"
                : "このメールアドレスは使えません。"
        case let .api(underlying):
            switch underlying {
            case .offline: "インターネットに接続されていません。"
            case .timedOut: "通信に時間がかかっています。もう一度お試しください。"
            case let .http(status, problem) where status == 400:
                // The server spells out which rule was missed; it is more
                // useful than anything generic we could write.
                problem?.detail ?? passwordRequirement
            case let .http(status, _) where status == 401:
                "メールアドレスかパスワードが違います。"
            case .http, .decoding, .unknown:
                "うまくいきませんでした。もう一度お試しください。"
            }
        case .applicationNotConfigured, .rateLimited, .deviceRejected:
            "いまは利用できません。しばらくしてからお試しください。"
        }
    }
}

/// 学習記録の引き継ぎ.
///
/// Framed throughout as protecting a record, never as "creating an account" —
/// §6 of the 実装ガイド. A 中学生 cares about not losing three years of work.
struct AccountHandoverView: View {
    @State var viewModel: HandoverViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                switch viewModel.phase {
                case .editing, .working, .failed:
                    introSection
                    fieldsSection
                    if case let .failed(message) = viewModel.phase {
                        Section { errorLabel(message) }
                    }
                    submitSection

                case let .done(email):
                    doneSection(email: email)

                case let .blockedByUnsentWork(sessions):
                    unsentWorkSection(sessions: sessions)
                }
            }
            .readableWidth()
            .navigationTitle(viewModel.mode == .link ? "記録を引き継げるようにする" : "記録を呼び出す")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    private var introSection: some View {
        Section {
            Text(viewModel.mode == .link
                 ? "メールアドレスを登録しておくと、スマホを変えても、いまの学習記録をそのまま続けられます。"
                 : "前に使っていたメールアドレスとパスワードを入れると、そのときの学習記録を呼び出せます。")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var fieldsSection: some View {
        Section {
            TextField("メールアドレス", text: $viewModel.email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            SecureField("パスワード", text: $viewModel.password)
                .textContentType(viewModel.mode == .link ? .newPassword : .password)
        } footer: {
            if viewModel.mode == .link {
                Text(HandoverViewModel.passwordRequirement)
            }
        }
    }

    private var submitSection: some View {
        Section {
            if case .working = viewModel.phase {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else {
                Button {
                    Task { await viewModel.submit() }
                } label: {
                    Text(viewModel.mode == .link ? "登録する" : "記録を呼び出す")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canSubmit)
            }
        }
    }

    private func doneSection(email: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("できました", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(viewModel.mode == .link
                     ? "\(email) で、新しいスマホからも学習記録を続けられます。"
                     : "\(email) の学習記録を呼び出しました。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("閉じる") { dismiss() }
        }
    }

    /// Sign-in would strand study time. The student is told how much and
    /// decides — this is never resolved silently.
    private func unsentWorkSection(sessions: Int) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label("まだ送信していない記録があります", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("この端末に、まだ送れていない学習時間が \(sessions) 件あります。いま記録を呼び出すと、この \(sessions) 件は失われます。")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("電波の良いところでもう一度試すと、送信してから続けられます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("もう一度試す") { Task { await viewModel.submit() } }

            Button("この \(sessions) 件を捨てて続ける", role: .destructive) {
                Task { await viewModel.submit(discardingUnsentWork: true) }
            }
        }
    }

    private func errorLabel(_ message: String) -> some View {
        Label {
            Text(message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }
}
