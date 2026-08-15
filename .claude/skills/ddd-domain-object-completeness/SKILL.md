---
name: ddd-domain-object-completeness
description: ドメインオブジェクト(エンティティ・値オブジェクト・集約)を常に完全かつ妥当な状態に保つための設計指針。ドメイン層を設計・レビューするとき、あるいは不変条件・バリデーション・ドメインの振る舞いの置き場所に迷ったときに使う。前提は Python 標準ライブラリの dataclasses。扱う範囲は Always-Valid なドメインモデル、エンティティと値オブジェクトの使い分け、集約と集約ルート、ドメインモデル貧血症の禁止、完全性(全域性)。
---

# DDD: ドメインオブジェクトの完全性 (Domain Object Completeness)

ドメインオブジェクト(エンティティ・値オブジェクト・集約)を**完全かつ常に妥当(always-valid)**な状態に保つ方法をまとめる。

前提: Python 標準ライブラリの [`dataclasses`](https://docs.python.org/3/library/dataclasses.html)。ドメイン層は **stdlib のみ**に依存し、フレームワーク(Django 等)にも外部ライブラリにも依存しない。`kw_only=True` は Python 3.10 以降。

集約の境界の引き方と永続化は
[ddd-aggregate-repository-boundary](../ddd-aggregate-repository-boundary/SKILL.md)、
集約をまたぐ整合性は
[ddd-domain-events](../ddd-domain-events/SKILL.md)、
ドメインオブジェクトを組み立てる側は
[ddd-application-layer](../ddd-application-layer/SKILL.md)、
どのオブジェクトにも属さないロジックの置き場所は
[ddd-domain-service-specification](../ddd-domain-service-specification/SKILL.md)。
そもそもどこにモデルの境界を引くかは
[ddd-bounded-context](../ddd-bounded-context/SKILL.md)。
ここで設計したものをどうテストするかは
[ddd-testing-strategy](../ddd-testing-strategy/SKILL.md)。
そもそも何をモデルにするかを見つける工程は
[ddd-modeling-discovery](../ddd-modeling-discovery/SKILL.md)、
金額・時間・識別子・数量の具体的な設計は
[ddd-modeling-primitives](../ddd-modeling-primitives/SKILL.md)、
既存コードから移行する場合は
[ddd-legacy-refactoring](../ddd-legacy-refactoring/SKILL.md)。
状態とライフサイクルの設計は
[ddd-state-transition](../ddd-state-transition/SKILL.md)、
置き場所が正しいのに書きにくいと感じたら
[ddd-supple-design](../ddd-supple-design/SKILL.md)。

---

## 1. Always-Valid なドメインモデル

ドメインオブジェクトは、**不正な状態で観測されることが決してない**。すべての不変条件(invariant)は「あとから」ではなく**構築時(construction)に**強制する。

- 値オブジェクト / エンティティ: `@dataclass(frozen=True, kw_only=True)` + `__post_init__` でバリデーション。
- `frozen=True` が代入(`__setattr__`)を封じるので、**不変性を自前で実装しなくてよい**。
- バリデーションは `__init__` の実行中に走る `__post_init__` で行う。**「不正な状態を構築不能にする(make invalid states unconstructible)」** — construct してから `validate()` を呼ぶ、という順序は禁止。
- `__post_init__` は例外を送出する。インターフェース層でそれを変換し、不正なエンティティは 500 ではなく妥当なクライアントエラー(例: 422)として表面化させる。**以降のコード例では簡潔さのため `ValueError` を使うが、実プロジェクトでは `DomainError` を基底とする独自例外にする** — 型階層とエラーコードは [exception-design](../exception-design/SKILL.md)。

```python
from dataclasses import dataclass


@dataclass(frozen=True, kw_only=True)
class Email(ValueObject):
    value: str

    def __post_init__(self) -> None:
        if "@" not in self.value:
            raise ValueError(f"不正なメールアドレス: {self.value!r}")


# OK: 構築した時点で必ず妥当
email = Email(value="a@example.com")

# NG: この設計は禁止(construct してから検証する)
# email = Email(value="broken")
# email.validate()
```

> 検証だけでなく派生値のセットが必要な場合、frozen インスタンスへの通常の代入はできない。`object.__setattr__(self, "field", value)` を `__post_init__` 内で使う(多用は設計の見直しサイン)。

---

## 2. エンティティ vs 値オブジェクト

| | 同一性 (Identity) | 等価性 (Equality) | 可変性 (Mutability) |
| --- | --- | --- | --- |
| **値オブジェクト (Value Object)** | なし | 値による(全フィールド) | 不変 (immutable) |
| **エンティティ (Entity)** | 安定した id を持つ | id による | 生涯にわたり状態が変化する |

**デフォルトは値オブジェクト**。「ライフサイクル」と「連続した同一性」を持つものだけをエンティティに昇格させる。

### 共通のスーパータイプを継承する(独自実装しない)

エンティティ用・値オブジェクト用の共通基底クラス(以下では `Entity` / `ValueObject` と呼ぶ)を1つずつ用意し、すべてのドメインオブジェクトはそれを継承する。基底クラスを各所で独自実装しない。

```python
import uuid
from dataclasses import dataclass, field


@dataclass(frozen=True, kw_only=True)
class ValueObject:
    """値による等価性(dataclass のデフォルト)をそのまま使う。"""


@dataclass(frozen=True, kw_only=True, eq=False)
class Entity:
    """安定した id と、id ベースの等価性を提供する。"""

    id: uuid.UUID = field(default_factory=uuid.uuid4)  # uuid7 等

    def __eq__(self, other: object) -> bool:
        return isinstance(other, Entity) and self.id == other.id

    def __hash__(self) -> int:
        return hash(self.id)
```

- `ValueObject`: `dataclass` のデフォルト(`eq=True`)で値による等価性が得られる。`frozen=True` なので `__hash__` も自動生成される。
- `Entity`: `eq=False` にして `__eq__` / `__hash__` を手書きし、id ベースの等価性にする。
- どちらも `frozen`。エンティティは、可変にするのではなく、**新しい frozen インスタンスを生成すること(`dataclasses.replace(...)`)で「変化」する**。

### `eq=False` の注意点(重要)

エンティティのサブクラスは **必ず** `@dataclass(frozen=True, kw_only=True, eq=False)` で装飾する。

- `eq=False` は、`dataclass` に `__eq__` を生成させず、基底クラスの id 同一性による `__eq__` / `__hash__` を継承させる。
- これを省く(= `eq` デフォルトの `True`)と `dataclass` が全フィールドで `__eq__` を再生成してしまい、**気付かぬうちに値等価性へ退行する**。
- `frozen` なクラスを継承するサブクラスも `frozen=True` でなければならない(混在は `TypeError`)。

```python
from dataclasses import dataclass, replace


@dataclass(frozen=True, kw_only=True, eq=False)  # eq=False を忘れない
class Order(Entity):
    status: OrderStatus
    lines: tuple[OrderLine, ...]

    def cancel(self) -> "Order":
        # 変化 = 新しい frozen インスタンスを返す(ミューテートしない)
        return replace(self, status=OrderStatus.CANCELLED)
```

---

## 3. 集約ルートが不変条件を守る

**集約 (Aggregate)** は**整合性の境界(consistency boundary)**であり、**集約ルート
(Aggregate Root)** はその**唯一の入口**である。ここではルートが果たす「不変条件の守り手」
としての役割だけを扱う。

- 外部はルートへの参照だけを持つ — 内部メンバーへの参照は決して持たない。
- **メンバーをまたぐ不変条件はルート内に置き、ルートが(再)構築されるときに検査する。**
- 他の集約へはオブジェクトグラフを埋め込むのではなく、**同一性(id)経由で**到達する。

> 境界をどこに引くか、集約をどう永続化するか(リポジトリ、1 トランザクション 1 集約、
> 永続化モデルとの分離)は
> [ddd-aggregate-repository-boundary](../ddd-aggregate-repository-boundary/SKILL.md)。
> 集約をまたぐ整合性は
> [ddd-domain-events](../ddd-domain-events/SKILL.md)。

```python
from dataclasses import dataclass


@dataclass(frozen=True, kw_only=True, eq=False)
class Order(Entity):
    lines: tuple[OrderLine, ...]
    customer_id: CustomerId  # 別集約は id で参照(オブジェクトを埋め込まない)

    def __post_init__(self) -> None:
        # メンバーをまたぐ不変条件はルートで検査する
        if not self.lines:
            raise ValueError("注文には少なくとも1行が必要")
```

---

## 4. ドメインモデル貧血症の禁止 (No Anemic Domain Model)

**ドメインモデル貧血症(anemic domain model)** — データ(フィールド + getter/setter)だけを持つエンティティ/値オブジェクトで、それらを操作するルールが usecase・serializer・model 側に散らばっている状態 — は**禁止**。データと、それを守る振る舞いは一緒に置かなければならない。

- ビジネスロジックは `domain/` の値オブジェクト / エンティティ / ドメインサービスに置く — Django モデル(永続化専用)や serializer、usecase には置かない。
- 生の状態アクセスではなく、**意図を表す振る舞い**を公開する: `order.status = "cancelled"` ではなく `order.cancel()`。
- 読み取りは `@property` のみで公開する。setter は存在しない(`frozen` が強制する)。
- 複数の集約に自然にまたがるロジックは**ドメインサービス**(`domain/services/`)に置く。stdlib のみ。これがエンティティの外にロジックを置く唯一の正当な場所であり、usecase がエンティティのフィールドに手を突っ込むのは決して認められない。名乗ってよい条件と乱用の見分け方は [ddd-domain-service-specification](../ddd-domain-service-specification/SKILL.md)。

### 検出シグナル(いずれか1つでも該当 = 貧血。設計を直す)

| におい (Smell) | 修正 (Fix) |
| --- | --- |
| エンティティがフィールド + get/set だけでメソッドを持たない | それらのフィールドを読むルールをエンティティに移す |
| usecase がエンティティの状態をフィールド単位でミューテートしている | ルートの意図を表すメソッド1つに置き換える |
| エンティティに関するルールが serializer / model に居る | `domain/`(エンティティ or ドメインサービス)へ引き上げる |
| 同じバリデーションを呼び出し側ごとに繰り返している | オブジェクトの構築時 / 値オブジェクトへ押し込む |

---

## 5. 完全性・全域性 (Completeness / Totality)

ドメイン型は、**妥当な範囲の全体を、かつ妥当な範囲のみ**をモデル化する。表現不能であるべき状態(unrepresentable states)は、**構築不能であるべき**。裸の `str` / `int` ではなく `Enum`・`frozenset`・狭い値オブジェクトを使う。

- ルールを持つプリミティブの代わりに、小さな値オブジェクト(`Email`・`Isbn`・`Money`)を優先する。ルールを型に押し込めば、すべての呼び出し側がそれを継承する(**プリミティブ強迫観念 / primitive obsession の禁止**)。

```python
from enum import Enum


# NG: 裸の str。"cancelld" のようなタイポや不正値を構築できてしまう
# status: str

# OK: 妥当な範囲だけを型で表現する
class OrderStatus(Enum):
    PENDING = "pending"
    PAID = "paid"
    CANCELLED = "cancelled"
```

---

## ルール(チェックリスト)

- [ ] すべての不変条件を**構築時に**強制する。不正な状態を決して公開しない(construct-then-validate は禁止)
- [ ] **デフォルトは値オブジェクト**。エンティティは同一性 + ライフサイクルを持つものだけ。どちらも `@dataclass(frozen=True, kw_only=True)`
- [ ] 共通スーパータイプを継承する: エンティティは `Entity`、値オブジェクトは `ValueObject`。エンティティのサブクラスは `eq=False` を付けて id ベースの等価性を維持する(全フィールド等価性にしない)
- [ ] frozen インスタンスの「変化」は `dataclasses.replace(...)` で新インスタンスを返す。ミューテートしない
- [ ] 集約はルート経由でのみ変更する。メンバーをまたぐ不変条件はルートが検査する。他の集約は id で参照する
- [ ] **ドメインモデル貧血症の禁止**: 振る舞いはドメインオブジェクト / ドメインサービスに置く。ルールが model・serializer・usecase に取り残されたデータ専用エンティティにしない
- [ ] `Enum` / 値オブジェクトで妥当な範囲を正確にモデル化する — プリミティブ強迫観念なし、貧血な setter なし
