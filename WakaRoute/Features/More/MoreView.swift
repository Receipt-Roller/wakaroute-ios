import SwiftUI
import WakaRouteKit

/// Service information, and the parent-facing material.
///
/// Everything here is read inside the app. The 開発ガイド permits a WebView for
/// the legal pages, but a 中学生 handed to Safari has to find their way back,
/// and with no signal cannot read them at all — so they ship in the bundle
/// instead. The only link that still leaves is a school's own website, which
/// belongs to someone else.
struct MoreView: View {
    let auth: AuthSession
    let profile: ProfileClient
    let studyTimer: StudyTimer
    let handover: AccountHandover

    var body: some View {
        NavigationStack {
            List {
                Section("アカウント") {
                    NavigationLink {
                        AccountView(viewModel: AccountViewModel(auth: auth, profile: profile, studyTimer: studyTimer, handover: handover))
                    } label: {
                        Label("学習記録とアカウント", systemImage: "person.crop.circle")
                    }
                }

                Section("保護者の方へ") {
                    documentLink(.forParents)
                }

                Section("サービスについて") {
                    documentLink(.about)
                    documentLink(.terms)
                    documentLink(.privacy)
                }

                Section {
                    LabeledContent("バージョン", value: Bundle.main.shortVersion)
                }
            }
            .readableWidth()
            .navigationTitle("その他")
        }
    }

    private func documentLink(_ document: LegalDocument) -> some View {
        NavigationLink {
            LegalDocumentView(document: document)
        } label: {
            Label(document.title, systemImage: document.symbolName)
        }
    }
}

extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}
