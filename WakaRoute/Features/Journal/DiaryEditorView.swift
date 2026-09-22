import SwiftUI
import WakaRouteKit

/// The 受験日記 form.
///
/// Opened from the current diary, never from nothing: `PUT /{date}/diary`
/// replaces the whole entry, so a form that only knew about 明日やること would
/// erase what the student wrote this morning about できたこと. `DiaryDraft`
/// carries every field for exactly this reason.
struct DiaryEditorView: View {
    let date: JournalDate
    @State var draft: DiaryDraft
    let onSave: (DiaryDraft) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @FocusState private var focusedField: Field?

    private enum Field { case achievements, struggles, tomorrowPlan }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DiaryTextField(
                        text: $draft.achievements,
                        placeholder: "わかったこと、進んだこと"
                    )
                    .focused($focusedField, equals: .achievements)
                } header: {
                    Text("できたこと")
                }

                Section {
                    DiaryTextField(
                        text: $draft.struggles,
                        placeholder: "つまずいたところ、わからなかったこと"
                    )
                    .focused($focusedField, equals: .struggles)
                } header: {
                    Text("困ったこと")
                } footer: {
                    // The point of the field, said once. A student who writes
                    // down where they got stuck is giving the 理解マップ
                    // something to work with.
                    Text("書いておくと、あとで見返すときに役立ちます。")
                }

                Section {
                    DiaryTextField(
                        text: $draft.tomorrowPlan,
                        placeholder: "英語の長文 2 題、など"
                    )
                    .focused($focusedField, equals: .tomorrowPlan)
                } header: {
                    Text("明日やること")
                }

                Section {
                    MoodPicker(title: "集中できた", value: $draft.focus, low: "あまり", high: "とても")
                    MoodPicker(title: "つかれ", value: $draft.fatigue, low: "元気", high: "くたくた")
                } header: {
                    Text("この日の調子")
                } footer: {
                    Text("任意です。えらばなくてもかまいません。")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(isSaving || isOverLimit)
                }
                ToolbarItem(placement: .keyboard) {
                    Spacer()
                }
                ToolbarItem(placement: .keyboard) {
                    Button("閉じる") { focusedField = nil }
                }
            }
            .overlay(alignment: .bottom) {
                if isOverLimit {
                    Text("1つの欄は \(JournalLimits.diaryTextLength) 文字までです。")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding()
                }
            }
        }
    }

    private var title: String {
        date.startOfDay.formatted(.dateTime.month().day().locale(Locale(identifier: "ja_JP"))) + "の日記"
    }

    /// Checked here so the student sees it while typing, rather than meeting a
    /// 400 after pressing 保存.
    private var isOverLimit: Bool {
        [draft.achievements, draft.struggles, draft.tomorrowPlan]
            .contains { $0.count > JournalLimits.diaryTextLength }
    }

    private func save() {
        isSaving = true
        Task {
            await onSave(draft)
            dismiss()
        }
    }
}

/// Grows with what is typed rather than scrolling inside a fixed box — a
/// paragraph the student cannot see all of is a paragraph they stop writing.
private struct DiaryTextField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
                    .padding(.leading, 5)
                    .accessibilityHidden(true)
            }
            TextEditor(text: $text)
                .frame(minHeight: 72)
                .scrollContentBackground(.hidden)
        }
        .accessibilityLabel(placeholder)
    }
}

/// 1–5, with the number always written out. The scale is labelled at both ends
/// so it is clear which way is which.
private struct MoodPicker: View {
    let title: String
    @Binding var value: Int?
    let low: String
    let high: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                if value != nil {
                    Button("えらばない") { value = nil }
                        .font(.caption)
                }
            }

            HStack(spacing: 6) {
                Text(low).font(.caption2).foregroundStyle(.secondary)

                ForEach(1...5, id: \.self) { step in
                    Button {
                        value = (value == step) ? nil : step
                    } label: {
                        Text("\(step)")
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(value == step ? Color.accentColor : Color.secondary.opacity(0.12))
                            )
                            .foregroundStyle(value == step ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title) 5 段階のうち \(step)")
                    .accessibilityAddTraits(value == step ? [.isButton, .isSelected] : .isButton)
                }

                Text(high).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
