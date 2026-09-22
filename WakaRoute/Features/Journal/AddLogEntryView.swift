import SwiftUI
import WakaRouteKit

/// Adds one block of time to the day.
///
/// Minutes first, and a set of common lengths one tap away — 「部活 120分」 is
/// the whole interaction. Start and end times exist in the API and are
/// deliberately not asked for here: a student recording their day at 23:00 does
/// not remember when practice started, and making them guess turns a five-second
/// entry into a form.
struct AddLogEntryView: View {
    /// What is left of the day's 24 hours. The server refuses anything past it.
    let remainingMinutes: Int
    let onAdd: (NewDayLogEntry) async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var category: JournalCategory = .selfStudy
    @State private var minutes = 60
    @State private var subject = ""
    @State private var content = ""
    @State private var isSaving = false

    private static let commonLengths = [15, 30, 45, 60, 90, 120, 180]

    var body: some View {
        NavigationStack {
            Form {
                Section("なにを") {
                    Picker("種類", selection: $category) {
                        ForEach(JournalCategory.known, id: \.self) { option in
                            Label(option.displayName, systemImage: option.symbolName).tag(option)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }

                Section {
                    HStack {
                        Text("時間")
                        Spacer()
                        Text(minutes.asDuration)
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                    }

                    // Common lengths, so the usual case is one tap. The stepper
                    // below stays for everything else.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Self.commonLengths, id: \.self) { length in
                                Button {
                                    minutes = length
                                } label: {
                                    Text(length.asDuration)
                                        .font(.subheadline)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(
                                            Capsule().fill(
                                                minutes == length
                                                    ? Color.accentColor
                                                    : Color.secondary.opacity(0.12)
                                            )
                                        )
                                        .foregroundStyle(minutes == length ? Color.white : Color.primary)
                                }
                                .buttonStyle(.plain)
                                .disabled(length > remainingMinutes)
                                .opacity(length > remainingMinutes ? 0.4 : 1)
                            }
                        }
                        .padding(.vertical, 2)
                    }

                    Stepper(value: $minutes, in: 5...max(5, remainingMinutes), step: 5) {
                        Text("5分きざみで調整")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("どれくらい")
                } footer: {
                    Text("この日はあと \(remainingMinutes.asDuration) 記録できます。")
                }

                if category.countsAsStudy {
                    Section {
                        TextField("教科（数学、英語…）", text: $subject)
                        TextField("内容（p.42 二次関数 …）", text: $content)
                    } header: {
                        Text("くわしく")
                    } footer: {
                        Text("任意です。")
                    }
                }
            }
            .navigationTitle("時間を記録")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("追加") { add() }
                        .disabled(isSaving || remainingMinutes < 5)
                }
            }
        }
    }

    private func add() {
        isSaving = true
        // `clientEntryId` is generated once, here, and travels with the entry.
        // If this send times out and is retried, the server recognises it as the
        // same block rather than logging the student's hour twice.
        let entry = NewDayLogEntry(
            category: category,
            durationMinutes: minutes,
            subject: trimmed(subject),
            content: trimmed(content)
        )
        Task {
            await onAdd(entry)
            dismiss()
        }
    }

    private func trimmed(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
