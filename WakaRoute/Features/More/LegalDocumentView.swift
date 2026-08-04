import SwiftUI
import WakaRouteKit

/// One of the service's own documents, read inside the app.
///
/// Rendered with the lesson typography rather than a WebView: it scales with
/// Dynamic Type, works with no signal, and never hands a 中学生 to Safari with
/// no obvious way back.
struct LegalDocumentView: View {
    let document: LegalDocument

    private var blocks: [LessonBlock] { document.blocks() }

    var body: some View {
        ScrollView {
            if blocks.isEmpty {
                ContentUnavailableView(
                    "読み込めませんでした",
                    systemImage: "doc.text",
                    description: Text("この文書はアプリに含まれていません。アプリを更新してみてください。")
                )
                .padding(.top, 40)
            } else {
                LessonBodyView(blocks: blocks)
                    .padding()
                    .readableWidth()
            }
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("プライバシーポリシー") {
    NavigationStack { LegalDocumentView(document: .privacy) }
}
