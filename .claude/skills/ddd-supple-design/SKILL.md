---
name: ddd-supple-design
description: ドメインコードを変更に耐える書き味にする指針。ドメイン層をレビューするとき、変更のたびに広範囲が壊れるとき、名前や引数が読み解けないとき、正しく置いてあるのに書きにくい・読みにくいと感じたときに使う。扱う範囲は意図を明かす名前とインターフェース、副作用のない関数と問い合わせ/コマンドの分離、事前条件と事後条件の表明、概念の輪郭に沿った分割、依存を削って単体で読めるクラス、同じ型を返す閉じた操作、宣言的に組み立てられる設計。
allowed-tools:
  - Read
  - Grep
  - Glob
---

# DDD: しなやかな設計 (Supple Design)

他の DDD スキルは「**何をどこに置くか**」を扱う。ここは「**どう書けば変更に耐えるか**」。
置き場所が正しくても、書き味が悪いモデルは使われず、やがて迂回される。

前提は
[ddd-domain-object-completeness](../ddd-domain-object-completeness/SKILL.md)
(frozen な値オブジェクト、構築時バリデーション)。モデルの発見は
[ddd-modeling-discovery](../ddd-modeling-discovery/SKILL.md)。

**しなやかさは目的ではなく、深いモデルに到達したときの結果。** 形だけ真似ても効かない。
「変更しようとしたら広範囲が壊れた」「引数の意味が読めない」といった**摩擦**が出た
ところにだけ当てる。

---

## 1. 意図を明かす (Intention-Revealing Interfaces)

**名前は「どうやるか」ではなく「何のためか」を言う。** 中を読まないと使えない
名前は、モデルをカプセル化できていない。

```python
# NG: 手続きの説明。何のためか分からない
def process(self, data: dict, flag: bool) -> None: ...
def calc(self, a: Decimal, b: Decimal, c: int) -> Decimal: ...

# OK: 業務の意図
def cancel(self, *, reason: CancellationReason) -> "Order": ...
def prorate_for(self, *, period: Period) -> Money: ...
```

- **業務の人が使う言葉で名付ける**([ddd-bounded-context](../ddd-bounded-context/SKILL.md)
  のユビキタス言語)。会話に出ない語がコードにあるなら、技術的都合が混ざっている。
- **引数はキーワード専用**(`*` を置く)。呼び出し側で意味が読める。
- **プリミティブを並べない。** `calc(a, b, c)` は値オブジェクトを渡せば
  `calc(rate, usage, days)` になり、順序間違いを型が防ぐ。
- **テストを先に書くと露見する。** 使いにくい名前はテストが書きにくい。

---

## 2. 副作用のない関数 (Side-Effect-Free Functions)

**「答えを返す」と「状態を変える」を混ぜない**(コマンド/クエリ分離)。

```python
# NG: 計算しながら状態も変える。呼ぶのが怖くなる
def total(self) -> Money:
    self._cached_total = ...        # ← 副作用
    return self._cached_total

# OK: 問い合わせは何も変えない
@property
def total(self) -> Money:
    return sum((line.subtotal for line in self.lines), start=Money.zero())

# OK: 変更は新しいインスタンスを返す(frozen なので自然にこうなる)
def cancel(self) -> "Order": ...
```

- **計算は値オブジェクトへ寄せる。** 値オブジェクトは不変なので、そこに置いた計算は
  自動的に副作用がない。エンティティは「どの計算を使うか」を決めるだけになる。
- **戻り値のない `->  None` メソッドは変更、戻り値のあるメソッドは問い合わせ。**
  両方やっているものを見つけたら割る。
- `frozen=True` を守っていれば大半は自然に達成される。**破れるのは
  `object.__setattr__` を使ったときと、可変オブジェクト(`list` / `dict`)を
  フィールドに持ったとき。** `tuple` / `frozenset` を使う。

---

## 3. 表明 (Assertions)

**事前条件・事後条件・不変条件を、コードで表明する。** コメントで書いた約束は守られない。

| 種類 | どこに書くか |
| --- | --- |
| **不変条件**(常に真) | `__post_init__` |
| **事前条件**(呼ぶ前に真であるべき) | メソッド冒頭のガード節 |
| **事後条件**(返す前に真) | 戻り値の型そのもの、または生成時の検証 |

```python
def ship(self, *, shipped_at: datetime) -> "Order":
    # 事前条件: 支払済みでなければ出荷できない
    if self.status is not OrderStatus.PAID:
        raise ValueError(f"支払済みでない注文は出荷できない: {self.status}")
    # 事後条件は Order の __post_init__ が保証する
    return replace(self, status=OrderStatus.SHIPPED, shipped_at=shipped_at)
```

- **`assert` 文を業務ルールに使わない。** `python -O` で消える。`raise` を使う。
- **事後条件は型で表す**のが最良。返り値の型自身が不変条件を持っていれば、
  チェックを書かなくてよい。
- 表明が多すぎると感じたら、**その概念が値オブジェクトになっていない**サイン。

---

## 4. 概念の輪郭 (Conceptual Contours)

**モデルの自然な切れ目で分ける。** 「大きいから割る」ではなく、
「**業務の中で独立して変わる単位**」で割る。

判定: **一緒に変更されるものは一緒に、別々に変更されるものは別々に。**

| 症状 | 輪郭がずれている | 直し方 |
| --- | --- | --- |
| 1つの業務変更で複数クラスを同時に直す | 割りすぎ。輪郭を跨いでいる | 統合する |
| 無関係な業務変更で同じクラスを直す | 詰め込みすぎ | 変更理由で割る |
| 引数で振る舞いを切り替えるフラグがある | 2つの概念が同居 | 別のメソッド/型へ |
| 条件分岐が同じ形で何度も出る | 隠れた概念がある | その分岐を型にする |

```python
# NG: フラグで振る舞いが変わる = 2つの概念が同居している
def calculate(self, *, is_business_day: bool) -> Money: ...

# OK: 概念を分けた
def calculate_for_business_day(self) -> Money: ...
def calculate_for_holiday(self) -> Money: ...
# または料金体系そのものを型にする(TariffPlan)
```

**輪郭は最初から見えない。** リファクタリングを繰り返して、変更が一箇所に収まる
形に近づける。集約の境界も同じ考え方
([ddd-aggregate-repository-boundary](../ddd-aggregate-repository-boundary/SKILL.md))。

---

## 5. 独立したクラス (Standalone Classes)

**依存が少ないほど、単体で理解できる。** 特に値オブジェクトは、他のドメイン概念を
知らずに読み切れるのが理想。

- **import を数える。** ドメインの値オブジェクトが他のドメインクラスを5個も
  import しているなら、概念が絡まっている。
- **依存を切るには、引数で受け取る。** 内部で他の集約を引きに行かない。
- 低レベルな概念(`Money` / `Period` / `Quantity`)は、
  **何にも依存しない**のが自然([ddd-modeling-primitives](../ddd-modeling-primitives/SKILL.md))。
- 「このクラスを理解するのに何個のファイルを開く必要があるか」で測る。

---

## 6. 閉じた操作 (Closure of Operations)

**引数と戻り値が同じ型の操作**は、外部概念を持ち込まずに組み立てられる。

```python
@dataclass(frozen=True, kw_only=True)
class Money(ValueObject):
    def add(self, other: "Money") -> "Money": ...        # 閉じている
    def multiply(self, factor: Decimal) -> "Money": ...  # 半分閉じている(戻り値は同型)


@dataclass(frozen=True, kw_only=True)
class Period(ValueObject):
    def intersect(self, other: "Period") -> "Period | None": ...
    def merge(self, other: "Period") -> "Period": ...
```

- **連鎖できる。** `a.add(b).add(c)` のように、中間結果に名前を付けずに繋がる。
- **`sum()` などの標準機能に乗る**(`start=Money.zero()`)。
- **すべてを閉じさせようとしない。** 自然に閉じる操作だけ。無理に閉じると、
  返す型が実態と合わなくなる。
- 閉じない場合(`Order` → `Money`)は普通の操作でよい。

---

## 7. 宣言的に組み立てられるようにする

**部品を組み合わせて「何を」書けば済む形**にすると、`if` の塊が消える。

```python
# 手続き的: 条件が増えるたびに if が増える
if customer.lifetime_value >= threshold and not customer.has_overdue_invoices:
    ...

# 宣言的: 仕様を組み合わせる
eligible = PremiumCustomer(threshold=...) & InGoodStanding()
if eligible.is_satisfied_by(customer):
    ...
```

仕様パターンの詳細は
[ddd-domain-service-specification](../ddd-domain-service-specification/SKILL.md)。

**やりすぎに注意。** 独自の DSL やビルダーを作り込むと、それ自体が学習コストになる。
**組み合わせる部品が3つ以上あり、実行時に組み替える必要があるとき**だけ。

---

## 8. どこに当てるか

しなやかな設計は**コスト**がかかる。全域に適用しない。

| 対象 | 適用 |
| --- | --- |
| **コアドメイン** | しっかり当てる。ここが事業の差 |
| 支援・汎用サブドメイン | 素直な実装で十分 |
| 変更が頻繁な箇所 | 当てる。回収できる |
| 数年触っていない箇所 | 触らない |

分類は [ddd-bounded-context](../ddd-bounded-context/SKILL.md)。

---

## アンチパターン

| アンチパターン | なぜ悪いか |
| --- | --- |
| `process` / `handle` / `manage` / `data` という名前 | 何のためか伝わらない。中を読まないと使えない |
| プリミティブを並べた引数(`calc(a, b, c)`) | 順序を間違えても気付けない。意味も読めない |
| 問い合わせメソッドが状態を変える | 呼ぶのが怖くなる。キャッシュ更新が典型 |
| フィールドに `list` / `dict` を持つ | frozen が破れ、外から書き換えられる |
| 業務ルールに `assert` を使う | `python -O` で消える |
| 事前条件をコメントで書く | 守られない。ガード節にする |
| 引数のフラグで振る舞いを切り替える | 2つの概念が同居している |
| 「大きいから」でクラスを割る | 輪郭を跨ぎ、1つの変更で複数を直すことになる |
| 値オブジェクトが多数のドメインクラスに依存 | 単体で読めない。概念が絡まっている |
| 無理にすべての操作を閉じさせる | 返す型が実態と合わなくなる |
| 独自 DSL を作り込む | それ自体が学習コストになる |
| 支援・汎用サブドメインまで作り込む | 回収できないコストを払う |

---

## ルール(チェックリスト)

- [ ] メソッド名が**業務の意図**を言っている(手続きの説明になっていない)
- [ ] 引数が**キーワード専用**で、プリミティブの羅列になっていない
- [ ] **問い合わせが状態を変えない**。コマンドと分離されている
- [ ] フィールドが `tuple` / `frozenset` で、`list` / `dict` を持っていない
- [ ] 事前条件が**ガード節**にあり、`assert` ではなく `raise` を使っている
- [ ] 不変条件が `__post_init__` に、事後条件が**型**に表れている
- [ ] クラスの分割が**変更理由**で決まっている(サイズで割っていない)
- [ ] 引数のフラグで振る舞いを切り替えていない
- [ ] 値オブジェクトが**単体で読める**(他のドメインクラスへの依存が少ない)
- [ ] 自然に**閉じる操作**は同じ型を返している(無理に閉じさせていない)
- [ ] `if` の塊が繰り返し出るなら、隠れた概念を型にした
- [ ] 適用対象を**コアドメイン / 変更が頻繁な箇所**に絞っている
