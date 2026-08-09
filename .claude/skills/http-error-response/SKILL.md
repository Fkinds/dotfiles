---
name: http-error-response
description: HTTP API がエラーを返すときの形式を決める指針。RFC 9457 Problem Details の 5 フィールドと拡張メンバー、application/problem+json、独自エラー形式から移行する判断、ステータスコードの正典としての RFC 9110 と 4xx/5xx の選び分け、機械可読なエラーコードとフィールド単位のエラー、日時の RFC 3339、フレームワークごとの対応状況を扱う。API のエラーレスポンスの形を決めるとき、エラー JSON に何を入れるか迷うとき、ステータスコードの選択で迷うとき、既存の独自エラー形式を見直すとき、エラーの文言をクライアントに出すときに使う。
allowed-tools:
  - Read
  - Grep
  - Glob
---

# HTTP エラーレスポンスの設計 (Problem Details)

**エラーの形式を自分で発明しない。** RFC 9457 が既にあり、クライアント側の
ライブラリもフレームワークもそれを前提にしている。

そもそもそれをエラーとして返すべきかは
[operation-result-design](../operation-result-design/SKILL.md)、
アプリ内部の例外の型とメッセージの設計は
[exception-design](../exception-design/SKILL.md)、
バージョニングと廃止の伝え方は
[api-lifecycle](../api-lifecycle/SKILL.md)。

---

## 1. Problem Details を既定にする

RFC 9457(2023)。RFC 7807(2016)の後継で、**拡張メンバーが公式に認められた**のが差分。

```http
HTTP/1.1 422 Unprocessable Content
Content-Type: application/problem+json

{
  "type": "https://example.com/probs/insufficient-balance",
  "title": "残高が不足しています",
  "status": 422,
  "detail": "送金額 12000 円に対し、残高は 8000 円です。",
  "instance": "/transfers/01H8X...",
  "code": "INSUFFICIENT_BALANCE",
  "balance": 8000
}
```

| フィールド | 何を入れるか | 必須か |
| --- | --- | --- |
| `type` | **問題の種類**を識別する URI。クライアントはこれで分岐する | 実質必須 |
| `title` | その `type` の短い説明。**個別の事情で変えない** | 推奨 |
| `status` | HTTP ステータスと同じ値 | 推奨 |
| `detail` | **この 1 回**に固有の説明 | 任意 |
| `instance` | 問題が起きた個別のリソース/実行を指す URI | 任意 |

- **`Content-Type` は `application/problem+json`。** これを付けないと、
  クライアントは通常の JSON と区別できない。
- **`title` は種類ごとに固定、`detail` は個別。** 逆にすると `type` 単位の
  ハンドリングができない。
- 該当する `type` がない汎用エラーは `"type": "about:blank"`(既定値)。
  このとき `title` は HTTP のステータス名(`"Not Found"` など)にする。

---

## 2. `type` の URI は解決できなくてよい

**`type` は識別子であって、取得先ではない。** ただし人が読める説明を置けるなら置く。

- 自社ドメインの URI にする(`https://example.com/probs/...`)。衝突しない。
- **一度公開した `type` の意味を変えない。** クライアントの分岐が壊れる。
  意味が変わるなら新しい `type` を作る。
- URN(`urn:problem-type:insufficient-balance`)でもよい。HTTP で引けないことを
  明示できる。

---

## 3. 拡張メンバーで業務の情報を足す

RFC 9457 はトップレベルへの追加を認めている。**`detail` の文章に埋め込まない。**

```json
{
  "type": "https://example.com/probs/validation-error",
  "title": "入力に誤りがあります",
  "status": 422,
  "errors": [
    { "field": "email", "code": "INVALID_FORMAT", "message": "形式が正しくありません" },
    { "field": "age",   "code": "OUT_OF_RANGE",   "message": "0 以上で入力してください" }
  ]
}
```

- **フィールド単位のエラーは配列で返す。** 最初の 1 件で打ち切らない。
  フォームは全項目を一度に出したい。
- **`code` は列挙値**にし、文言(`message` / `title` / `detail`)と分ける。
  分岐は `type` か `code`、表示は文言。**文言で分岐させない。**
- 内部の例外クラス名・スタックトレース・SQL を入れない。
  内部向けの情報は相関 ID(`instance` かログ ID)で紐付ける。

---

## 4. ステータスコードは RFC 9110 を正典にする

RFC 9110(2022, Internet Standard)が HTTP セマンティクスを統合した。
RFC 2616 や 7231 を根拠にしない。

| 状況 | コード | 補足 |
| --- | --- | --- |
| 構文が壊れている(JSON として読めない) | 400 | |
| 構文は正しいが内容が業務ルールに反する | 422 | 400 と区別する |
| 未認証 / トークン切れ | 401 | `WWW-Authenticate` を付ける |
| 認証済みだが権限がない | 403 | 存在を隠すなら 404 |
| 対象がない | 404 | |
| そのメソッドを許していない | 405 | `Allow` を付ける |
| 前提条件・同時更新の衝突 | 409 | 楽観ロックの競合 |
| 流量超過 | 429 | RFC 6585。[api-reliability](../api-reliability/SKILL.md) |
| こちらの不具合 | 500 | 原因をクライアントに晒さない |
| 依存先が落ちている / 一時的 | 503 | `Retry-After` を付ける |

- **400 と 422 を混ぜない。** 400 は「パースできない」、422 は「読めたが受け付けられない」。
  クライアントの直し方が違う。
- **業務上妥当な否定的結果(却下・在庫切れ)は 2xx + ボディ。**
  4xx は「リクエストを直せ」の意味で、直しても結果が変わらないものに使わない
  ([operation-result-design](../operation-result-design/SKILL.md))。
- **リトライしてよいかをステータスで伝える。** 5xx と 429 はリトライ可、
  4xx の大半は不可。判断材料になる `Retry-After` を惜しまない。

---

## 5. 日時は RFC 3339 の UTC で返す

```json
{ "created_at": "2026-08-07T12:34:56Z" }
```

- **RFC 3339。** ISO 8601 の曖昧さ(週番号、区切りなし表記、`24:00`)を排した
  プロファイルで、20 年変わっていない。「ISO 8601 で」と書くと解釈が割れる。
- **UTC(`Z`)で返し、表示側でローカルに直す。** オフセット付き(`+09:00`)は
  「その時刻に意味のある地域がある」場合だけ。
- 日付だけの値(`2026-08-07`)と時刻付きの値を同じフィールドに混ぜない。
- ドメイン側での時刻の持ち方は
  [ddd-modeling-primitives](../ddd-modeling-primitives/SKILL.md)。

---

## 6. フレームワーク側の現実

| 環境 | 対応 |
| --- | --- |
| Spring Framework 6 / Boot 3 | `ProblemDetail` が組み込み |
| ASP.NET Core | `[ApiController]` が自動変換 |
| Django / DRF | 標準では非対応。例外ハンドラを 1 か所書く |
| JS / TS 系 | 標準では非対応。自前で組み立てる |

- **変換は 1 か所に集約する。** DRF なら `EXCEPTION_HANDLER`、
  Django なら middleware。view ごとに整形しない
  ([ddd-application-layer](../ddd-application-layer/SKILL.md))。
- 既存の独自形式がある API に後から入れるときは、**新しいエンドポイントから
  Problem Details にし、既存は据え置く。** 形式の変更は破壊的変更
  ([api-lifecycle](../api-lifecycle/SKILL.md))。

---

## アンチパターン

| アンチパターン | なぜ悪いか |
| --- | --- |
| エラー形式を独自に発明する | クライアント側の既製の処理に乗れない |
| `Content-Type` を `application/json` のままにする | 正常レスポンスと区別できない |
| `title` に個別の事情を書く | `type` 単位でハンドリングできない |
| エラーの文言で分岐させる | 文言の修正や翻訳で壊れる。`type` か `code` で分岐する |
| バリデーションエラーを 1 件で打ち切る | フォームが 1 項目ずつしか直せない |
| 全部 200 で返してボディに `"error": true` | HTTP のリトライ・キャッシュ・監視が効かない |
| 全部 400 にする | 直し方が分からない。422 / 409 / 429 を使い分ける |
| 500 に例外メッセージやスタックトレースを載せる | 内部構造が漏れる |
| 却下・在庫切れを 4xx で返す | 直しても結果は変わらない |
| 日時を `2026/08/07 21:34` のような独自形式で返す | パースが実装ごとに割れる |

---

## ルール(チェックリスト)

- [ ] エラーは RFC 9457 Problem Details の形で返している
- [ ] `Content-Type` が `application/problem+json`
- [ ] `type` が自社ドメインの URI で、意味を後から変えていない
- [ ] `title` は種類ごとに固定、`detail` は個別の事情
- [ ] 業務情報は拡張メンバーで返し、`detail` の文章に埋めていない
- [ ] 機械可読な `code` と、表示用の文言を分けている
- [ ] バリデーションエラーを**全件**配列で返している
- [ ] 内部の例外クラス名・スタックトレース・SQL を返していない
- [ ] ステータスは RFC 9110 を根拠にし、400 と 422 を区別している
- [ ] 業務上の否定的結果を 4xx にしていない
- [ ] 429 / 503 に `Retry-After` を付けている
- [ ] 日時が RFC 3339 の UTC
- [ ] 例外 → レスポンスの変換が 1 か所に集約されている
