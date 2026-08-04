# wakaroute-ios

iOS client for [ワカルート / WakaRoute](https://wakaroute.com) — a free service
for Japanese middle-school students (中学生) preparing for high school entrance
exams (高校受験).

Its one idea: **when a student is stuck, send them back to the cause, not the
symptom.** A student failing 一次関数 is often not stuck on 一次関数 — the gap is
文字を用いた式, two steps earlier. Drilling the thing that hurts does not help. So
the app carries a prerequisite graph over the curriculum, walks backwards from
what a student cannot do to the earliest thing genuinely missing, and points
there.

Built by [株式会社レシートローラー](https://receiptroller.co).

## Status

Submitting as **1.1.0**, iPhone and iPad, minimum iOS 17.0.

| Area | State |
|---|---|
| Silent device registration, token lifecycle, account handover | Working, verified against production |
| Lessons, 確認クイズ, offline replay | Working |
| Home on real progress — goal, streak, what to do next | Working |
| 理解マップ (prerequisite graph) | 数学 only; the other four subjects need their edges authored |
| Lesson feedback (わかった / むずかしかった) | Working |
| In-app 利用規約 / プライバシーポリシー | Working, readable offline |
| 確認テスト (`/tests/{id}`) | Not exercised — no tests authored yet |
| Forced update | Client done, waiting on the endpoint |

## Design notes

The comments in this repository carry the reasoning rather than the mechanics.
A few decisions worth knowing before reading:

**Students never sign in.** The app registers a device silently on first launch
and stores a `deviceSecret` in the Keychain. There is no sign-up screen, because
a 中学生 who has to make an account will not make one. Email is optional and only
for moving to a new phone — framed throughout as 「学習記録を引き継ぐ」, never as
「アカウント登録」.

**Nothing invents a number.** No score is shown when the app cannot grade
offline. Only the first three of the five mastery levels are derivable today, so
the app reports three and marks the rest 準備中 — a student has not failed a
level nobody can measure yet.

**"Blocked" and "stumbling" are different things.** Everything a student has not
reached is blocked; on a first launch, 23 of 26 元素 are. Reporting that as
手前でつまずき would light a warning on every subject, permanently, and mean
nothing. A stumble needs evidence: a quiz sat and missed.

**Work is never lost to a bad network.** Study time, lesson completions, quiz
submissions and feedback queue locally and replay, reusing the original
`Idempotency-Key` so a replay is the same attempt rather than a second one.
Permanent failures — a deleted lesson — are set aside so they cannot block the
queue behind them.

**Layout asks the window, not the device.** Split View and Stage Manager hand an
iPad app an arbitrary width, so `if iPad` would put two 300pt columns on screen
the moment a student opens something alongside. Every adaptive decision is a
width threshold.

## Layout

```
WakaRouteKit/          Swift package — all logic, testable without a simulator
  Config/              Environment, client identity, version gate
  Networking/          HTTP transport, RFC 7807 problem details
  Security/            Keychain-backed secret storage
  Storage/             File paths — see FilePath.swift, it exists for a reason
  Auth/                Device registration, token lifecycle, account handover
  Content/             Paths, courses, lessons, quizzes, offline replay, home digest
  StudyTime/           Study timer, calendar, server sync
  UnderstandingMap/    Prerequisite graph, mastery derivation, 今集中すること
  Profile/             Learner profile, 志望校
  Schools/             School catalogue
  Resources/           The prerequisite graph and the legal documents, as data

WakaRoute/             App target — SwiftUI screens only
  DesignSystem/        Shared layout and presentation
  Features/            One folder per area
  Navigation/          Routes, and the context pushed screens need
```

Logic lives in the package so `swift test` runs from the command line without
booting a simulator.

## Building

Requires Xcode 26 or later.

```bash
cd WakaRouteKit && swift test
```

```bash
xcodebuild -project WakaRoute.xcodeproj -scheme WakaRoute \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Debug builds accept launch arguments for reaching screens that sit several
pushes deep. All are compiled out of Release builds.

| Argument | Opens |
|---|---|
| `-startTab N` | A tab directly |
| `-openLesson <id>` | One lesson |
| `-openLesson <id> -withQuiz` | That lesson with its quiz open |
| `-openMap` | The 理解マップ against live data |
| `-openDoc legal-privacy` | One of the bundled documents |
| `-openFeedback` | The lesson rating control |
| `-useSampleData` | 理解マップ fixtures, behind a サンプル表示 banner |

## Backends

Learning content and accounts come from **MANABU2** (`api.manabu2.com`), which
is operated by the same company. The school catalogue comes from
`wakaroute.com`. **No API key is embedded anywhere** — device registration
exists for that purpose.

## Privacy

Users are minors, and the app is built accordingly: no analytics, no crash
reporting, no advertising identifier, no name, address or date of birth. The
full policy ships inside the app under その他 → プライバシーポリシー and is
mirrored at [wakaroute.com/privacy](https://wakaroute.com/privacy).

The trade is stated in the policy rather than hidden: with no analytics, nobody
can watch which screens a student uses — and nobody finds out when the app
crashes, either.

## Contributing

See [AGENTS.md](AGENTS.md) for the conventions this codebase holds to, including
the backend behaviours that will bite you if you have not met them.

## Licence

All rights reserved. Published for reference; not licensed for reuse.
