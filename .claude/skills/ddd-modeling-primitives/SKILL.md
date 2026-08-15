---
name: ddd-modeling-primitives
description: 実務で必ず踏む題材のモデリング指針。金額や日時をドメインに持たせるとき、丸め・端数・通貨の扱いを決めるとき、ID をいつ誰が採番するか決めるとき、期間の重なりや境界で悩むときに使う。扱う範囲は金額(Decimal・通貨・丸め・配分)、時間(タイムゾーン・時点と期間・有効期間・営業日)、識別子(採番の責任・UUID・外部キーとの対応・自然キー)、数量と単位を、値オブジェクトとしてどう設計するか。
allowed-tools:
  - Read
  - Grep
  - Glob
---

# DDD: 実務のモデリング題材 (Money / Time / Identity / Quantity)

**どの業務にも出てきて、どこでも同じように間違える4つ。** 個別の設計判断が多く、
毎回考え直すには重い。前提は
[ddd-domain-object-completeness](../ddd-domain-object-completeness/SKILL.md)
(frozen な値オブジェクト、構築時バリデーション)。

Python 標準ライブラリのみ。`Decimal` / `datetime` / `uuid` / `enum` を使う。

---

## 1. 金額 (Money)

**`float` を使わない。`Decimal` を使う。** 二進浮動小数点は 0.1 を正確に表せず、
加算を繰り返すと合計が合わなくなる。

```python
from dataclasses import dataclass
from decimal import Decimal, ROUND_HALF_UP
from enum import Enum


class Currency(Enum):
    JPY = ("JPY", 0)   # 円は小数部なし
    USD = ("USD", 2)

    def __init__(self, code: str, exponent: int) -> None:
        self.code = code
        self.exponent = exponent


@dataclass(frozen=True, kw_only=True)
class Money(ValueObject):
    amount: Decimal
    currency: Currency

    def __post_init__(self) -> None:
        if self.amount != self.amount.quantize(Decimal(1).scaleb(-self.currency.exponent)):
            raise ValueError(f"{self.currency.code} に対して精度が細かすぎる: {self.amount}")

    def add(self, other: "Money") -> "Money":
        self._assert_same_currency(other)
        return Money(amount=self.amount + other.amount, currency=self.currency)

    def _assert_same_currency(self, other: "Money") -> None:
        if self.currency is not other.currency:
            raise ValueError("通貨が異なる金額は演算できない")
```

- **通貨を必ず持たせる。** 裸の `Decimal` を金額として回すと、異なる通貨が
  黙って足される。
- **異なる通貨の演算は例外。** 換算はドメインサービスの仕事
  ([ddd-domain-service-specification](../ddd-domain-service-specification/SKILL.md))。
- **通貨ごとに小数桁が違う**(JPY は 0、USD は 2)。桁を通貨に持たせる。

### 丸めと配分

- **丸めモードを明示する。** Python の既定は `ROUND_HALF_EVEN`(銀行家丸め)で、
  日本の業務でよくある「四捨五入」は `ROUND_HALF_UP`。**業務に確認して決める。**
- **いつ丸めるかを決める。** 途中で丸めるか最後に丸めるかで結果が変わる。
  税計算・按分は特に。決めたらモデルに書く。
- **按分(配分)は端数の行き先まで決める。** 1000円を3人で割ると 333/333/334。
  余りを誰が持つかは業務ルールであってプログラムの都合ではない。

```python
def allocate(self, ratios: tuple[int, ...]) -> tuple["Money", ...]:
    """端数を先頭から1単位ずつ配る。合計は必ず元の金額と一致する。"""
    total_ratio = sum(ratios)
    unit = Decimal(1).scaleb(-self.currency.exponent)
    shares = [
        (self.amount * r / total_ratio).quantize(unit, rounding=ROUND_DOWN)
        for r in ratios
    ]
    remainder = self.amount - sum(shares)
    for i in range(int(remainder / unit)):
        shares[i] += unit
    return tuple(Money(amount=s, currency=self.currency) for s in shares)
```

**合計が元に戻ることをテストする。** 按分のバグはここでしか出ない。

---

## 2. 時間 (Time)

### 時点は必ず aware。保存は UTC

```python
from datetime import UTC, datetime

# NG: naive datetime。どこの時刻か分からない
datetime.now()

# OK: tz 付き
datetime.now(UTC)
```

- **naive `datetime` をドメインに入れない。** 構築時に弾く。
- **保存と計算は UTC、表示だけローカル。** 変換はインターフェース層。
- **`datetime.now()` をドメインの中で呼ばない。** テストできなくなる。
  現在時刻は**引数で渡す**(第4節の共通則)。

### 日付と時点を区別する

| 種類 | 型 | 例 |
| --- | --- | --- |
| **時点**(instant) | `datetime`(aware) | 注文された瞬間 |
| **日付**(業務上の日) | `date` | 契約開始日、締め日 |

「契約開始日」に時刻はない。`datetime` で持つと、タイムゾーン次第で前日になる。
**業務が日で語るものは `date` で持つ。**

### 期間 (Period) は境界を明示する

```python
@dataclass(frozen=True, kw_only=True)
class Period(ValueObject):
    """開始を含み、終了を含まない [start, end)。"""

    start: date
    end: date | None          # None = 無期限

    def __post_init__(self) -> None:
        if self.end is not None and self.end <= self.start:
            raise ValueError("終了は開始より後でなければならない")

    def contains(self, d: date) -> bool:
        return self.start <= d and (self.end is None or d < self.end)

    def overlaps(self, other: "Period") -> bool:
        return (self.end is None or other.start < self.end) and \
               (other.end is None or self.start < other.end)
```

- **半開区間 `[start, end)` を既定にする。** 隣接する期間が重ならず、
  連続を表現しやすい。「3月31日まで」は `end = 4月1日`。
- **どちらの流儀か必ず書く。** 閉区間と半開区間が混在すると、1日ズレのバグが出る。
- **無期限(`None`)を型で表す。** `9999-12-31` のような番兵は比較で事故る。
- **重なり判定を自分で書かない。** `overlaps` を値オブジェクトに持たせて再利用する。

### 営業日・締め・タイムゾーン

- **営業日計算はドメインサービス。** 祝日カレンダーという外部知識が要るので、
  値オブジェクトには収まらない。
- **「日付が変わる時刻」が業務で 0:00 とは限らない**(締め時刻が朝5時など)。
  業務日(business date)と暦日を混同しない。

---

## 3. 識別子 (Identity)

### 型で包む

```python
@dataclass(frozen=True, kw_only=True)
class OrderId(ValueObject):
    value: uuid.UUID


@dataclass(frozen=True, kw_only=True)
class CustomerId(ValueObject):
    value: uuid.UUID
```

裸の `UUID` や `int` を渡し合うと、`OrderId` を期待する箇所に `CustomerId` を
渡しても気付けない。**型で包めば型チェッカが捕まえる。**

### 誰がいつ採番するか

**ドメイン側で採番する**のを既定にする(`uuid4` / `uuid7`)。

| 採番場所 | 利点 | 欠点 |
| --- | --- | --- |
| **ドメイン(生成時)** | 保存前に id を持てる。イベントに載せられる。テストが楽 | DB の連番より索引効率が落ちる |
| DB(AUTO INCREMENT) | 索引効率がよい | **保存するまで id がない** — 集約の生成とイベント発行が歪む |

- 保存前に id がないと、`OrderPlaced(order_id=...)` を集約の中で作れない
  ([ddd-domain-events](../ddd-domain-events/SKILL.md))。**これが決定打。**
- 索引効率が問題なら **UUID v7**(時刻順)を使う。連番の代わりになる。
- **採番はファクトリの引数で受け取る**か `default_factory` に閉じる。

### 業務上の番号は別物

「注文番号 `ORD-2026-00123`」のような**業務が使う番号**は、内部 id とは別の概念。

- 内部 id は不変・非公開。業務番号は**表示され、規則があり、変わりうる**。
- 業務番号を主キーにしない。改番があると全部壊れる。
- 業務番号にも値オブジェクトを与え、書式を型で守る。

---

## 4. 数量と単位

```python
@dataclass(frozen=True, kw_only=True)
class Quantity(ValueObject):
    value: int
    unit: Unit

    def __post_init__(self) -> None:
        if self.value < 0:
            raise ValueError("数量は負にできない")
```

- **単位を持たせる。** `kWh` と `MWh`、`個` と `箱` を裸の数値で混ぜない。
- **異なる単位の演算は例外か、明示的な変換を経由**させる。
- **負を許すかを型で決める。** 「在庫数」は非負、「増減」は符号あり。
  同じ `int` でも別の型にする。

---

## 5. 4つに共通する原則

- **外部依存は引数で受け取る。** 現在時刻・採番・乱数をドメインの中で取得しない。
  テストできなくなる。
- **境界(リポジトリ / DTO)で変換する。** DB には `Decimal` / `UUID` / `datetime` を
  そのまま入れ、ドメインでは値オブジェクトで扱う。変換はリポジトリ実装の内側
  ([ddd-aggregate-repository-boundary](../ddd-aggregate-repository-boundary/SKILL.md))。
- **DB のカラム型を合わせる。** 金額は `DecimalField`(`FloatField` にしない)、
  時刻は `DateTimeField` + `USE_TZ = True`。ドメインだけ正しくても保存で失われる。
- **等価性は値で決まる。** `Money(100, JPY) == Money(100, JPY)` が真になること
  (frozen dataclass の既定でそうなる)。

---

## アンチパターン

| アンチパターン | なぜ悪いか |
| --- | --- |
| 金額を `float` で持つ | 誤差が蓄積し、合計が合わなくなる |
| 金額に通貨を持たせない | 異なる通貨が黙って加算される |
| 丸めモードを決めずに `round()` | Python 既定は銀行家丸め。業務の期待とズレる |
| 按分の端数の行き先を決めない | 合計が元の金額と一致しなくなる |
| naive `datetime` をドメインに入れる | どこの時刻か不明。DST とサーバ移設で壊れる |
| 業務上の「日」を `datetime` で持つ | タイムゾーン次第で前日/翌日になる |
| 期間の境界(閉/半開)を決めない | 1日ズレのバグが出続ける |
| `9999-12-31` で無期限を表す | 比較・集計で事故る。`None` で表す |
| ドメイン内で `datetime.now()` / 採番する | 隠れた外部依存。テストできない |
| id を裸の `UUID` / `int` で渡す | 別種の id を取り違えても気付けない |
| DB 採番に依存する | 保存前に id がなく、イベントに載せられない |
| 業務番号を主キーにする | 改番で全部壊れる |
| 数量を単位なしで持つ | `kWh` と `MWh` が混ざる |

---

## ルール(チェックリスト)

- [ ] 金額は `Decimal` + **通貨**を持つ値オブジェクト。`float` を使っていない
- [ ] 異なる通貨の演算が**例外**になる。換算はドメインサービス経由
- [ ] **丸めモードと丸めるタイミング**を業務に確認して決めた
- [ ] 按分の**端数の行き先**を決め、合計が一致するテストがある
- [ ] `datetime` は**すべて aware**。保存と計算は UTC、変換は境界で
- [ ] 業務が「日」で語るものは **`date`** で持っている
- [ ] 期間は**半開区間 `[start, end)`** で、流儀を明記した
- [ ] 無期限を **`None`** で表している(番兵日付を使っていない)
- [ ] **現在時刻・採番を引数で受け取る**。ドメイン内で取得していない
- [ ] id を**型で包んでいる**(`OrderId` と `CustomerId` が混ざらない)
- [ ] **ドメイン側で採番**している(保存前に id を持てる)
- [ ] 業務番号と内部 id を**別概念**として持っている
- [ ] 数量に**単位**があり、非負かどうかが型で決まっている
- [ ] DB のカラム型が対応している(`DecimalField`、`USE_TZ = True`)
