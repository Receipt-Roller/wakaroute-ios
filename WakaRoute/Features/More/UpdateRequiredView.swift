import SwiftUI
import WakaRouteKit

/// Shown in place of the app when this build may no longer be used.
///
/// This screen locks a student out of their own revision, so it appears only
/// when the server explicitly says a version is too old — never because a
/// request failed. Before it appears, everything recorded on the device has
/// already been sent, so nothing a student did is waiting behind the wall.
struct UpdateRequiredView: View {
    let message: String?
    let storeUrl: URL?

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            Image(systemName: "arrow.down.circle")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            VStack(spacing: 10) {
                Text("アプリの更新が必要です")
                    .font(.title2.weight(.semibold))

                Text(message ?? "新しいバージョンが出ています。更新すると、続きから学べます。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Said plainly, because "your data is gone" is the first thing a
            // student will assume when the app they were using stops opening.
            Label("これまでの学習記録は残っています。", systemImage: "checkmark.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let storeUrl {
                Button {
                    openURL(storeUrl)
                } label: {
                    Text("App Store をひらく").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Spacer()
        }
        .padding(28)
        .readableWidth()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

#Preview {
    UpdateRequiredView(
        message: "新しい問題を追加しました。",
        storeUrl: URL(string: "https://apps.apple.com/jp/app/id0000000000")
    )
}
