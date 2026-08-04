# WakaRoute iOS

[ワカルート（WakaRoute）](https://wakaroute.com)のiOSアプリです。高校受験にむけて学ぶ中学生が、「いまどこにいるか」と「次に何をすればいいか」を自分で見られるようにすることを目指しています。

ワカルートは株式会社レシートローラーが開発する、無料のオープンソースプロジェクトです。特定の学校、教育委員会、文部科学省が運営する公式サービスではありません。

Webアプリは [wakaroute-web](https://github.com/Receipt-Roller/wakaroute-web) にあります。

## このアプリの考え方

**つまずいたら、症状ではなく原因まで戻す。**

一次関数が解けない生徒は、一次関数でつまずいているとはかぎりません。二つ手前の「文字を用いた式」が固まっていないことがよくあります。そこを放置したまま一次関数を何度練習しても、あまり進みません。

このアプリは教科の中の**前提関係のグラフ**を持っていて、解けない要素からさかのぼり、**本当に足りていない一番手前の要素**を見つけて、そこを示します。

## いまの状態

**1.1.0** を審査に提出中です。iPhone / iPad、最低対応は iOS 17.0。

| 機能 | 状態 |
|---|---|
| 端末登録・トークン更新・記録の引き継ぎ | 動作、本番で確認済み |
| レッスン、確認クイズ、オフライン再送 | 動作 |
| ホーム（目標・連続日数・つぎにやること） | 動作、実データ |
| 理解マップ（前提関係グラフ） | 数学のみ。他4教科は辺の作成待ち |
| レッスン評価（わかった / むずかしかった） | 動作 |
| アプリ内の利用規約・プライバシーポリシー | 動作、オフラインでも読める |
| 確認テスト | 未検証。テストがまだ1件も作られていないため |
| 強制アップデート | クライアント側は完了、配信エンドポイント待ち |

## 設計上の判断

このリポジトリのコメントは、**やり方ではなく理由**を書いています。読む前に知っておくと早いものをいくつか。

**生徒はログインしません。** 初回起動で端末を登録し、`deviceSecret` をキーチェーンに保存します。サインアップ画面は作っていません。**アカウントを作らないと試せないアプリを、中学生は作りません。** メールアドレスは任意で、機種変更のときだけ使います。文言も一貫して「学習記録を引き継ぐ」であって「アカウント登録」ではありません。

**数字をでっち上げません。** オフラインで採点できないときは点数を出しません。理解度の5段階のうち、いま根拠をもって出せるのは3段階までなので、3段階しか出さず、残りは「準備中」と書きます。**誰も測れないレベルで、生徒が落第したことにはできません。**

**「まだ届いていない」と「つまずいた」は別ものです。** まだたどり着いていない要素はすべて blocked です。初回起動では26要素中23個がそうです。それを「手前でつまずき」と呼ぶと、学習を始めた全生徒の全教科で警告が点灯し続け、意味を失います。つまずきには証拠が要ります — **クイズを受けて落ちたこと**です。

**通信状況で学習が消えません。** 学習時間、レッスン完了、クイズ提出、評価は、送れなければ端末に貯めて後で送ります。最初の `Idempotency-Key` を使い回すので、再送は「同じ1回」であって2回目の挑戦にはなりません。削除されたレッスンのような**恒久的な失敗は脇に避けて**、後ろに詰まらないようにしています。

**レイアウトは端末ではなく「窓の幅」で決めます。** Split View も Stage Manager も任意の幅を渡してくるので、「iPad なら」と書くと、生徒が横に別アプリを開いた瞬間に300ptの列が2本並びます。判断はすべて幅のしきい値です。

## 構成

```
WakaRouteKit/          Swiftパッケージ — ロジックはすべてここ。シミュレータ不要でテストできる
  Config/              環境、クライアント識別、バージョンゲート
  Networking/          HTTP、RFC 7807 のエラー
  Security/            キーチェーンによる機密保存
  Storage/             ファイルパス（FilePath.swift には理由があります）
  Auth/                端末登録、トークン更新、記録の引き継ぎ
  Content/             パス・コース・レッスン・クイズ、オフライン再送、ホーム集計
  StudyTime/           学習タイマー、カレンダー、サーバー同期
  UnderstandingMap/    前提関係グラフ、理解度の導出、今集中すること
  Profile/             学習者プロフィール、志望校
  Schools/             高校カタログ
  Resources/           前提関係グラフと法的文書（データとして同梱）

WakaRoute/             アプリターゲット — SwiftUIの画面のみ
  DesignSystem/        共通のレイアウトと表示
  Features/            機能ごとのフォルダ
  Navigation/          画面遷移と、遷移先が必要とする情報
```

ロジックをパッケージ側に置いているので、`swift test` はシミュレータを起動せずコマンドラインで走ります。

## ビルドと検証

Xcode 26 以降が必要です。

```bash
cd WakaRouteKit && swift test
```

```bash
xcodebuild -project WakaRoute.xcodeproj -scheme WakaRoute \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Debug ビルドでは、階層の深い画面を直接開く起動引数が使えます。**Release ビルドからは完全に除去されます。**

| 引数 | 開く画面 |
|---|---|
| `-startTab N` | 指定のタブ |
| `-openLesson <id>` | レッスン1件 |
| `-openLesson <id> -withQuiz` | クイズを開いた状態のレッスン |
| `-openMap` | 理解マップ（実データ） |
| `-openDoc legal-privacy` | 同梱の文書 |
| `-openFeedback` | レッスン評価 |
| `-useSampleData` | 理解マップの仮データ（サンプル表示バナー付き） |

## バックエンド

学習内容とアカウントは **MANABU2**（`api.manabu2.com`）から取得します。**同じ会社が運営しています。** 高校情報は `wakaroute.com` から取得します。

**APIキーは一切埋め込んでいません。** 端末登録がその役割を担っています。

## プライバシー

利用者は未成年です。そのつもりで作っています。アクセス解析なし、クラッシュ収集なし、広告識別子なし、氏名・住所・生年月日も取得しません。

方針の代償も、隠さずポリシーに書いています — **解析を入れていないので、どの画面が使われているかを運営者は見られません。そのかわり、アプリが落ちたことも分かりません。**

全文はアプリ内（その他 → プライバシーポリシー）と [wakaroute.com/privacy](https://wakaroute.com/privacy) にあります。

## コントリビューション

[CONTRIBUTING.md](CONTRIBUTING.md) と、[AGENTS.md](AGENTS.md)（このコードベースの決めごと。特に、知らないと必ず踏むバックエンドの挙動）をご覧ください。

## ライセンス

[Apache License 2.0](LICENSE)。[NOTICE](NOTICE) と [TRADEMARKS.md](TRADEMARKS.md) もあわせてご確認ください。

---

**English**: iOS client for WakaRoute, a free open-source study service for
Japanese middle-school students preparing for high school entrance exams. It
holds a prerequisite graph over the curriculum and, when a student is stuck,
points them back to the earliest topic that is genuinely missing rather than the
one that hurts. Documentation is in Japanese; code comments are in English.
