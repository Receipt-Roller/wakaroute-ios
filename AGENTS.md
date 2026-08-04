# AGENTS.md — wakaroute-ios

## Project

- AB Project ID: `89e7a1cf-f35e-4e65-a28d-39176ad06d39` (WakaRoute — all client tasks)
- Backend AB Project ID: `1d20be70-77b3-4016-8254-f92166172c2f` (LMS - DEV / MANABU2)
- Task prefix for this repo: `[iOS]`
- Specifications live in the AB Wiki and are authoritative. Where this file and
  the Wiki disagree, raise an AB Task rather than quietly matching either one.

Required reading before changing anything here:

- `WakaRoute サービス仕様`
- `WakaRoute iOS・Android開発ガイド`
- `アカウント作成と引き継ぎの実装ガイド（デバイス登録 / アカウント連携）`

## Layout

```
WakaRouteKit/          Swift package — all logic, testable from the CLI
  Config/              Environment, client identity, version gate
  Networking/          HTTP transport, RFC 7807 errors
  Security/            Keychain-backed secret storage
  Storage/             File paths
  Auth/                Device registration, token lifecycle, account handover
  Content/             Paths, courses, lessons, quizzes, offline replay
  StudyTime/           Study timer, calendar, server sync
  UnderstandingMap/    Prerequisite graph, mastery derivation
  Profile/             Learner profile, 志望校
  Schools/             School catalogue client
  Resources/           Prerequisite graph and legal documents, as data
```

Logic lives in the package, not the app target, so `swift test` runs without a
simulator.

## Architecture

```
View → ViewModel → UseCase → Repository → API client / cache
```

- Screens never perform network calls directly.
- Loading, success, empty, failure and retry are explicit states, not implied
  by a nil.
- API response types are not exposed to views; map to screen models.
- Use `id` as the permanent key. Never key off a school name or a 要素 name.

## Backend rules that bite

Read these before touching `Auth/`.

- **The refresh token is single-use.** Presenting a rotated token again makes
  the server revoke every session on the account. All renewal goes through
  `AuthSession`, which serializes it. Never retry a failed refresh with the
  same token — recover via `/api/v1/devices/token` instead.
- **`deviceSecret` is returned exactly once.** Persist it before anything else.
- **`deviceId` is a label, not a credential.** It must be ≥16 characters.
- **Quiz submissions need an `Idempotency-Key`.** Without one, a resend after a
  timeout records a duplicate attempt, and attempts gate certificates.
- Branch on the error `code`, never on `detail` — the prose changes.

## Security

- Never put credentials in `UserDefaults`. Keychain only, with
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- Never embed an API key. Device registration exists for this purpose.
- Never log names, emails, tokens, answers, or study history.
- Users are minors. Collect the minimum the feature actually requires.
- **Never hand `FileManager` a path from `URL.path()`.** It percent-encodes, so
  anything under Application Support silently fails to load while writing
  perfectly. Use `URL.filePath`. This cost the study history, the offline queue
  and the path cache once already.
- **This repository is public.** Do not commit real account ids, tokens or
  captured production responses containing them. Fixtures should be obviously
  fake.

## Verifying

```bash
cd WakaRouteKit && swift test
```

## Completing an AB Task

Record in a comment: the spec covered, states implemented, APIs and environment
used, devices tested, test results, VoiceOver check, failure/empty/retry check,
screenshots, and anything left undone. Close with `ab_complete_task`, then
re-read to confirm Status: Done, Progress: 100%, Complete: True.

## Settled — do not reopen without a task

- Minimum iOS **17.0**, bundle id `com.wakaroute.app`, iPhone + iPad.
- No analytics and no crash reporting. This is written into the privacy policy;
  adopting either means changing a published document.
- 要素 are MANABU2 **course ids**. Names are never keys.
- Mastery levels 3–5 need 確認テスト and are not claimed until they exist.

## Unresolved — do not decide alone

- Prerequisite edges for 国語 / 英語 / 理科 / 社会 (数学 is drafted and in review).
- Whether unused accounts are deleted automatically or by the annual manual
  sweep the privacy policy promises.

Raise these as `[Shared]` or `[API]` tasks and update the Wiki with the outcome.
