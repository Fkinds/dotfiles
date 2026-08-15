---
name: exception-design
description: 例外を使うと決めた後の設計指針。例外クラスをどう作るか決めるとき、ValueError だけで足りなくなったとき、リポジトリや外部 API クライアントが失敗をどの型で伝えるか決めるとき、エラー型をどこに置くか迷うとき、エラーコードを API で返したいとき、例外メッセージをそのまま画面に出していいか迷うとき、同じエラーが何度もログに出るときに使う。扱う範囲はドメイン例外の基底クラスと型階層、層ごとの例外の分け方(ドメイン/アプリケーション/インフラ)、インフラ例外のラップとポート専用エラー型の置き場所、呼び出し側が機械的に分岐するためのエラーコードとコンテキスト情報、開発者向けとユーザー向けのメッセージの分離、raise from による原因の保持、変換を 1 か所に集約する方法、ログを出す位置。
---

# 例外設計 (Exception Design)

**そもそも例外にすべきか**は
[operation-result-design](../operation-result-design/SKILL.md)(業務上ありふれた
否定的結果は例外にしない)。ここは**例外を使うと決めた後**、どう作るか。

HTTP への変換方針は
[ddd-application-layer](../ddd-application-layer/SKILL.md) 第 6 節、
変換後のレスポンス本体の形式は
[http-error-response](../http-error-response/SKILL.md)。

> **本スキル群の他のコード例について**: 他の DDD スキルは簡潔さのため
> `raise ValueError(...)` と書いている。**実プロジェクトでは、以下の階層に置き換える。**
> 意味は同じ(不変条件違反)で、型が具体的になる。

---

## 1. 標準例外だけでは足りなくなる点

`ValueError` を投げるだけだと、次ができない。

- **呼び出し側が種類で分岐できない。** 「残高不足」と「口座凍結」が同じ型。
- **エラーコードを返せない。** クライアントが文言に依存して分岐することになる。
- **一括変換できない。** ライブラリが投げる無関係な `ValueError` と区別がつかない。

**独自例外に切り替える境目**: 上のどれか 1 つが必要になったとき。
それまでは標準例外で構わない。

---

## 2. 基底クラスと階層

```python
class DomainError(Exception):
    """すべてのドメイン例外の基底。ドメイン層は stdlib のみなので Exception を継承する。"""

    code: str = "domain_error"


class InvariantViolation(DomainError):
    """不変条件の違反。構築時・遷移時に送出する。"""


class InsufficientBalance(InvariantViolation):
    code = "insufficient_balance"

    def __init__(self, *, required: Money, available: Money) -> None:
        super().__init__(f"残高不足: 必要 {required}, 残高 {available}")
        self.required = required
        self.available = available
```

- **`Exception` を直接継承する。** `ValueError` を継承すると、ライブラリが投げる
  無関係な `ValueError` と区別できず、一括変換で巻き込む。
- **階層は 2〜3 段まで。** `DomainError` → 分類 → 個別。深くすると、
  どこで捕まえるべきか分からなくなる。
- **例外の種類は「呼び出し側が分岐する単位」で作る。** 分岐しないなら 1 つで足りる。
  メッセージを変えたいだけなら、型を増やさず引数で渡す。
- **ドメイン層は stdlib のみ**([ddd-domain-object-completeness](../ddd-domain-object-completeness/SKILL.md))。
  基底も自前で定義する。

---

## 3. 層ごとに例外を分ける

**どの層で起きたかで、扱いが変わる。**

| 層 | 基底 | 意味 | 典型 |
| --- | --- | --- | --- |
| ドメイン | `DomainError` | **業務ルールの違反** | 不変条件違反、不正な遷移 |
| アプリケーション | `ApplicationError` | **アプリの都合** | 見つからない、認可失敗、競合 |
| インフラ | 素の例外 or `InfrastructureError` | **技術的失敗** | 接続断、タイムアウト |

```python
# usecases/exceptions.py
class ApplicationError(Exception):
    code: str = "application_error"


class OrderNotFound(ApplicationError):
    code = "order_not_found"
```

- **「見つからない」をドメイン例外にしない。** 集約が存在しないのは業務ルール違反
  ではなく、アプリケーションの都合
  ([ddd-application-layer](../ddd-application-layer/SKILL.md))。
- **インフラの例外をドメインまで漏らさない。** リポジトリ実装で捕まえ、
  意味のある例外に翻訳する(第 5 節)。
- 層ごとに基底が分かれていると、**exception handler で一括変換できる**。

### ポート専用のエラーは、ポートと同じ位置に置く

**インフラ起因の例外は原則 `InfrastructureError` でラップする。** 例外は、
**アプリケーション層が分岐に使うもの**(ファイル未発見、楽観ロック競合など)。
これは専用の型を設けて投げる。作る単位は第 2 節と同じ — 呼び出し側が分岐するかどうか。

専用型は、**それを投げるポート(抽象)が定義されている位置**に置く。

| ポートの位置 | 専用エラー型の位置 |
| --- | --- |
| `usecases/ports.py` | `usecases/exceptions.py` |
| `<module>/domain/ports.py` | `<module>/domain/exceptions.py` |

- **ポートより内側の汎用エラー型を、インフラ実装が自分で構築して投げない。**
  リポジトリ実装が `DomainError` を直接 `raise` するのは層境界違反。業務ルールに
  違反したかどうかを判断できるのはドメインだけで、インフラはそれを知らない。
- **例外は、ポート契約がその型を明示的に採用している場合。** 「このポートは
  `XxxError` を送出する」と抽象の側に書いてあるなら、実装は契約に従って構築してよい。
  暗黙に投げるのと、契約として宣言されているのは別物。
- **実装が投げる例外はポートの一部。** 抽象を読めば、呼び出し側が捕まえるべき型が
  分かる状態にする。ポートの設計は [adapter-design](../adapter-design/SKILL.md)。

---

## 4. 例外に情報を持たせる

**メッセージ文字列で分岐させない。** 文言を変えた瞬間に壊れる。

| 持たせるもの | 用途 |
| --- | --- |
| **`code`**(機械可読の識別子) | クライアントの分岐、i18n のキー、ログの集計 |
| **コンテキスト**(必要値・現在値・対象 id) | 原因調査、ユーザーへの説明 |
| メッセージ | **開発者向け**の説明(第 5 節) |

```python
# NG: メッセージで分岐する。文言変更で壊れる
except DomainError as e:
    if "残高" in str(e):
        ...

# OK: code で分岐する
except DomainError as e:
    if e.code == "insufficient_balance":
        ...
```

- **`code` は変えない。** 一度クライアントに出したら公開契約になる
  ([ddd-domain-events](../ddd-domain-events/SKILL.md) のイベントと同じ扱い)。
- **コンテキストは属性で持つ。** `str(e)` をパースさせない。
- **秘密情報を入れない。** 例外はログにもレスポンスにも出る。

---

## 5. メッセージの向き先を分ける

**例外メッセージは開発者向け。そのままユーザーに出さない。**

```python
# NG: 例外メッセージをそのまま画面へ
return Response({"error": str(e)}, status=422)
# → "残高不足: 必要 Money(amount=Decimal('1000'), currency=JPY), 残高 ..."
```

| 向き先 | 誰が書くか | どこで作るか |
| --- | --- | --- |
| **開発者向け** | 例外のメッセージ | 例外クラスの中。詳細・数値を含めてよい |
| **ユーザー向け** | `code` から引く文言 | インターフェース層。i18n の対象 |

```python
# interfaces/error_messages.py
USER_MESSAGES = {
    "insufficient_balance": "残高が不足しています。入金してからお試しください。",
    "order_not_found": "指定された注文が見つかりません。",
}
```

- **ドメイン層で i18n しない。** 表示は外側の関心。
- **`code` が未登録なら汎用文言にフォールバック**し、ログに警告を出す。
  未登録に気付けない設計にしない。

---

## 6. 原因を失わない (`raise from`)

**翻訳するときは、元の例外を必ず繋ぐ。**

```python
# NG: 原因が消える。スタックトレースに元の例外が出ない
try:
    row = OrderModel.objects.get(pk=...)
except OrderModel.DoesNotExist:
    raise OrderNotFound(order_id)

# OK: 原因を保持する
except OrderModel.DoesNotExist as e:
    raise OrderNotFound(order_id) from e
```

- **`from e` を付ける。** 付けないと「During handling of the above exception,
  another exception occurred」になり、因果が読めなくなる。
- **意図的に原因を隠すときは `from None`。** 無意識に省略しない。
- **握り潰さない。** `except Exception: pass` は、不変条件の違反をなかったことにする。

---

## 7. 変換は 1 か所

**usecase ごとに try/except を書き散らさない。**

```python
# interfaces/exception_handler.py  (DRF の custom exception handler)
_STATUS = {
    DomainError: 422,
    ApplicationError: 404,      # サブクラスごとに上書き
    PermissionDenied: 403,
    ConflictError: 409,
}
```

- **層の基底クラスで拾い、必要なものだけ個別に上書きする。**
- **未知の例外は 500 にして落とす。** 握り潰して 200 を返さない。
- 分類の詳細は
  [ddd-application-layer](../ddd-application-layer/SKILL.md) 第 6 節。
- **リトライ可否も返す**と呼び出し側が判断できる
  ([operation-result-design](../operation-result-design/SKILL.md))。

---

## 8. ログは境界で 1 回だけ

**各層で `logger.exception()` を呼ぶと、1 つの失敗が何度もログに出る。**
どれが根本原因か分からなくなる。

| どこ | ログ | 理由 |
| --- | --- | --- |
| ドメイン層 | **出さない** | ログは技術的関心。stdlib のみの原則にも反する |
| usecase | 原則出さない | 例外を投げて外へ伝える |
| **例外ハンドラ(境界)** | **ここで 1 回** | 全体像が揃う唯一の場所 |
| 再送・リトライの断念時 | 出す | ここで失敗が確定する |

- **捕まえて再送出するときはログを出さない。** 上流で出る。
- **握り潰すときだけは必ずログ**(理由つき)。黙って消さない。
- ドメイン例外(業務ルール違反)は `warning`、技術的失敗は `error` が目安。
  **業務的に正常な失敗を `error` で出さない** — アラートが鳴り続ける。

---

## アンチパターン

| アンチパターン | なぜ悪いか |
| --- | --- |
| 例外メッセージの文字列で分岐する | 文言変更で壊れる。`code` を使う |
| すべて `Exception` / `ValueError` で投げる | 呼び出し側が分岐できず、一括変換もできない |
| `DomainError(ValueError)` にする | ライブラリの無関係な `ValueError` を巻き込む |
| 例外階層を 4 段以上にする | どこで捕まえるべきか分からなくなる |
| 分岐しないのに例外の型を増やす | 型が増えるだけ。引数で足りる |
| インフラ実装が `DomainError` を直接 `raise` する | 業務ルールに違反したかを判断できるのはドメインだけ。層境界違反 |
| ポート専用のエラー型をインフラ側に置く | 抽象を読んでも捕まえるべき型が分からず、実装差し替えで型が変わる |
| 例外メッセージをそのままユーザーに出す | 内部構造が漏れ、日本語としても読めない |
| ドメイン層で i18n する | 表示は外側の関心。層が壊れる |
| `raise X` で原因を捨てる | 因果が追えない。`from e` を付ける |
| `except Exception: pass` | 不変条件の違反をなかったことにする |
| usecase ごとに try/except で HTTP に変換 | 変換が散らばり、一貫性が失われる |
| 各層で `logger.exception()` を呼ぶ | 同じ失敗が何度もログに出る |
| 業務的に正常な失敗を `error` で出す | アラートが鳴り続け、本当の障害が埋もれる |
| 例外に秘密情報を入れる | ログにもレスポンスにも出る |
| `code` を後から変える | 公開契約が壊れる |

---

## ルール(チェックリスト)

- [ ] そもそも**例外にすべき**か確認した(業務結果は戻り値へ)
- [ ] 独自例外に切り替える理由が明確(分岐 / エラーコード / 一括変換のいずれか)
- [ ] 基底は **`Exception` を直接継承**(`ValueError` を継承していない)
- [ ] 階層が **2〜3 段**に収まっている
- [ ] 例外の種類が「**呼び出し側が分岐する単位**」で作られている
- [ ] **層ごとに基底が分かれている**(ドメイン / アプリケーション / インフラ)
- [ ] インフラ起因の例外を**原則ラップ**し、アプリ層が分岐に使うものだけ専用型にした
- [ ] 専用エラー型が**ポートと同じ位置**にある
- [ ] インフラ実装が、ポートより内側の汎用エラー型を**自分で構築していない**
      (ポート契約として明示採用しているものを除く)
- [ ] 「見つからない」がドメイン例外になっていない
- [ ] **`code`** を持ち、メッセージ文字列で分岐していない
- [ ] コンテキスト情報を**属性**で持っている(`str(e)` をパースさせない)
- [ ] 例外に秘密情報が入っていない
- [ ] メッセージが**開発者向け**で、ユーザー向け文言は `code` から引いている
- [ ] 翻訳時に **`raise ... from e`** で原因を保持している
- [ ] 変換が**1 か所**(exception handler)に集約されている
- [ ] 未知の例外を **500 で落としている**(握り潰していない)
- [ ] ログが**境界で 1 回**。各層で重複して出していない
- [ ] 業務ルール違反を `error` ではなく `warning` で出している
