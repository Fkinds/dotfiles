---
name: ddd-domain-service-specification
description: 集約に収まらないドメインロジックの置き場所を決める設計指針。ドメインサービスを名乗ってよい条件と乱用の見分け方、状態を持たないステートレスな実装、アプリケーションサービス(usecase)との線引き、仕様パターン(Specification)による判定ルールの部品化と再利用、ファクトリによる複雑な生成の切り出しを扱う。ロジックがどのオブジェクトにも自然に属さないとき、複数の集約をまたぐ判定を書くとき、`XxxService` を作ろうとしているとき、生成手順が複雑になってきたときに使う。
allowed-tools:
  - Read
  - Grep
  - Glob
---

# DDD: ドメインサービス・仕様・ファクトリ (Domain Service / Specification / Factory)

**エンティティにも値オブジェクトにも自然に属さないロジック**の置き場所。
ただし「属さない」と判断するハードルは高い — 安易に使うと、ドメインサービスが
usecase と同じ「ロジックの掃き溜め」になる。

前提: Python 標準ライブラリの `dataclasses`。**すべてドメイン層 = stdlib のみ**。

ドメインオブジェクトの設計は
[ddd-domain-object-completeness](../ddd-domain-object-completeness/SKILL.md)、
集約の境界は
[ddd-aggregate-repository-boundary](../ddd-aggregate-repository-boundary/SKILL.md)、
usecase の責務は
[ddd-application-layer](../ddd-application-layer/SKILL.md)。

---

## 1. まず「置けない」ことを疑う

**ドメインサービスは最後の手段。** 作る前に、この順で検討する。

1. **その値オブジェクト / エンティティのメソッドにできないか。**
   引数のオブジェクトが 1 つなら、たいていどちらかのメソッドになる。
2. **新しい値オブジェクトを作れば収まらないか。**
   「2 つの値から 3 つ目を計算する」は、多くの場合その 3 つ目が値オブジェクト。
3. **集約ルートのメソッドにできないか。**
   関係するものが同じ集約内なら、ルートが持つべき。
4. ここまでで置けない → **ドメインサービス**。

```python
# NG: 何でもサービスにする
class MoneyService:
    def add(self, a: Money, b: Money) -> Money: ...  # ← Money.add() でよい

# OK: Money 自身の振る舞い
@dataclass(frozen=True, kw_only=True)
class Money(ValueObject):
    amount: Decimal
    currency: Currency

    def add(self, other: "Money") -> "Money":
        if self.currency != other.currency:
            raise ValueError("通貨が異なる金額は加算できない")
        return Money(amount=self.amount + other.amount, currency=self.currency)
```

**目安**: ドメインサービスの数がエンティティの数を超えたら、貧血症を疑う
([ddd-domain-object-completeness](../ddd-domain-object-completeness/SKILL.md))。

---

## 2. ドメインサービスを名乗ってよい条件

**次の 3 つを全部満たすときだけ。**

1. **ドメインの言葉で説明できる操作**である(業務の人が「それは〜だ」と言える)。
2. **どの単一のエンティティ / 値オブジェクトにも自然に属さない** — 特に、
   複数の集約やオブジェクトが**対等に**関わる。
3. **状態を持たない**(ステートレス)。同じ入力なら常に同じ結果。

典型例:

| 例 | なぜサービスか |
| --- | --- |
| 通貨換算 (`ExchangeService`) | `Money` にも `ExchangeRate` にも一方的には属さない |
| 重複チェック(メールアドレスの一意性) | 単一の `User` からは判定できない(集合の性質) |
| 移送 (`TransferService`: 口座 A → 口座 B) | 2 つの口座が対等。どちらのメソッドでもない |
| 料金プランの適用可否判定 | `Plan` と `Customer` の両方の状態に依存する |

```python
@dataclass(frozen=True, kw_only=True)
class TransferService:
    """口座間の振替。どちらの口座のメソッドでもない。"""

    def transfer(
        self, *, source: Account, destination: Account, amount: Money
    ) -> tuple[Account, Account]:
        if not source.can_withdraw(amount):
            raise ValueError("残高が不足している")
        return source.withdraw(amount), destination.deposit(amount)
```

- **状態を持たない。** インスタンス変数に処理途中の値を溜めない。
- **依存を持つとしても抽象だけ。** 重複チェックのようにリポジトリが要る場合、
  ドメイン層のリポジトリ抽象を受け取る(Django も具象も知らない)。
- **返すのはドメインオブジェクト。** 保存しない — 永続化は usecase の仕事。

---

## 3. ドメインサービス ≠ アプリケーションサービス

名前が似ているだけで、まったく別のもの。**混同すると層が崩れる。**

| | ドメインサービス | アプリケーションサービス (usecase) |
| --- | --- | --- |
| 置き場所 | `domain/services/` | `usecases/` |
| 依存 | stdlib のみ | ドメイン層 + リポジトリ抽象 |
| 中身 | **業務ルール** | **手順の組み立て**(取得・保存・イベント) |
| トランザクション | 知らない | 境界を張る |
| 名前 | 業務の言葉 (`TransferService`) | 動詞句 (`TransferMoney`) |

```python
# ドメインサービス: ルールだけ。保存しない
class TransferService:
    def transfer(self, *, source, destination, amount) -> tuple[Account, Account]: ...

# usecase: 取得・呼び出し・保存を組み立てる
class TransferMoney:
    def execute(self, command: TransferMoneyCommand) -> TransferMoneyOutput:
        source = self._accounts.find_by_id(...)
        destination = self._accounts.find_by_id(...)
        new_source, new_destination = self._transfer.transfer(...)
        # 保存は usecase。1 トランザクション 1 集約の制約もここで効く
        ...
```

**ドメインサービスがリポジトリに `save` を呼んだら、それはもう usecase。**

---

## 4. 仕様パターン (Specification)

**「条件を満たすか」という判定を、名前の付いたオブジェクトにする。**
`if` の塊がドメインの言葉を失っているときに効く。

> 以下は Python 3.12 の型パラメータ構文(`class Specification[T]`)。3.11 以前なら
> `TypeVar` + `Generic[T]` に読み替える。

```python
from abc import ABC, abstractmethod
from dataclasses import dataclass


class Specification[T](ABC):
    @abstractmethod
    def is_satisfied_by(self, candidate: T) -> bool: ...

    def __and__(self, other: "Specification[T]") -> "Specification[T]":
        return AndSpecification(left=self, right=other)


@dataclass(frozen=True, kw_only=True)
class AndSpecification[T](Specification[T]):
    left: Specification[T]
    right: Specification[T]

    def is_satisfied_by(self, candidate: T) -> bool:
        return self.left.is_satisfied_by(candidate) and self.right.is_satisfied_by(candidate)


@dataclass(frozen=True, kw_only=True)
class PremiumCustomer(Specification[Customer]):
    threshold: Money

    def is_satisfied_by(self, candidate: Customer) -> bool:
        return candidate.lifetime_value >= self.threshold


@dataclass(frozen=True, kw_only=True)
class InGoodStanding(Specification[Customer]):
    def is_satisfied_by(self, candidate: Customer) -> bool:
        return not candidate.has_overdue_invoices


# 組み合わせて名前を付ける
eligible_for_discount = PremiumCustomer(threshold=Money(...)) & InGoodStanding()
```

### 使う / 使わない

**使う:**

- 同じ判定が**複数箇所**(集約・usecase・バリデーション)で必要。
- 条件を**実行時に組み合わせる**(ユーザーが絞り込み条件を選ぶ)。
- 条件そのものが**業務の関心**で、名前を付ける価値がある(「優良顧客」「出荷可能な注文」)。

**使わない:**

- 1 か所でしか使わない単純な条件 → 集約のメソッド 1 つ (`order.can_ship()`) で十分。
- **仕様を DB クエリに変換しようとしている。** `to_query()` を生やすとドメイン層に
  永続化の関心が侵入する。絞り込み検索は
  [ddd-read-model-cqrs](../ddd-read-model-cqrs/SKILL.md) の query service へ。
- 条件が 2 個しかないのに `And` / `Or` / `Not` の枠組みを先に作る → 過剰。

> **仕様は「判定」であって「取得」ではない。** メモリ上のオブジェクトに対して
> `is_satisfied_by` を問うだけ。SQL を組み立て始めたら設計を見直す。

---

## 5. ファクトリ (Factory)

**生成が複雑なときだけ**、生成の責務を切り出す。`__post_init__` による不変条件の
強制は[ドメインオブジェクトの完全性](../ddd-domain-object-completeness/SKILL.md)の
担当で、ファクトリはそれを置き換えない。

必要になるのは:

- 集約全体(ルート + 内部メンバー)を**まとめて**組み立てる必要がある。
- 生成時に**複数の入力から派生値を計算**する。
- **生成の条件分岐**がある(入力によって別のサブタイプを返す)。

```python
@dataclass(frozen=True, kw_only=True)
class Order(Entity):
    lines: tuple[OrderLine, ...]
    total: Money

    @classmethod
    def place(cls, *, customer_id: CustomerId, items: tuple[CartItem, ...]) -> "Order":
        """集約の生成 = ルートの classmethod が第一候補。"""
        if not items:
            raise ValueError("空のカートからは注文できない")
        lines = tuple(OrderLine.from_cart_item(i) for i in items)
        return cls(
            customer_id=customer_id,
            lines=lines,
            total=sum((line.subtotal for line in lines), start=Money.zero()),
        )
```

- **まずは集約ルートの `classmethod`。** 独立したファクトリクラスは、生成に他の集約や
  外部の値が必要な場合だけ。
- **ファクトリも不変条件を迂回しない。** 最後は通常のコンストラクタを通る。
- **リポジトリからの復元はファクトリの仕事ではない。** 復元も通常のコンストラクタを通す
  ([ddd-aggregate-repository-boundary](../ddd-aggregate-repository-boundary/SKILL.md))。
- ID 採番や現在時刻のような**外部依存は引数で受け取る**。ファクトリの中で
  `datetime.now()` を呼ぶとテストできなくなる。

---

## アンチパターン

| アンチパターン | なぜ悪いか |
| --- | --- |
| 何でも `XxxService` に置く | ドメインモデル貧血症の入口。まずオブジェクトに置けないか疑う |
| ドメインサービスが状態を持つ | 同じ入力で結果が変わる。テストも並行実行も壊れる |
| ドメインサービスがリポジトリに `save` する | それは usecase。トランザクション境界が二重化する |
| ドメインサービスが Django / requests を import する | ドメイン層が stdlib のみの原則を破る |
| ドメインサービスの数がエンティティより多い | ロジックがオブジェクトの外に出ている |
| 1 か所でしか使わない条件を Specification 化 | 抽象化のコストだけ払って何も得ていない |
| Specification に `to_query()` を生やす | 永続化の関心がドメイン層に侵入する。query service へ |
| ファクトリが検証を迂回する生成経路を作る | 不正な状態が構築可能になる |
| ファクトリ内で `datetime.now()` / 採番する | 隠れた外部依存。引数で受け取る |

---

## ルール(チェックリスト)

- [ ] そのロジックを**値オブジェクト / エンティティ / 集約ルートに置けない**ことを確認した
- [ ] ドメインサービスは 3 条件(ドメインの言葉・単一オブジェクトに属さない・ステートレス)を満たす
- [ ] ドメインサービスは **stdlib のみ**に依存し、保存もトランザクションもしない
- [ ] ドメインサービスと usecase を混同していない(名前・置き場所・責務が分かれている)
- [ ] ドメインサービスの数がエンティティの数を超えていない
- [ ] Specification は**再利用・組み合わせ・命名の価値**がある場合だけ使っている
- [ ] Specification が SQL を組み立てていない(絞り込み検索は query service へ)
- [ ] 集約の生成はまず**ルートの `classmethod`**。独立ファクトリは必要な場合だけ
- [ ] ファクトリも通常のコンストラクタを通り、不変条件を迂回していない
- [ ] 時刻・ID などの外部依存を**引数で受け取っている**(内部で取得していない)
