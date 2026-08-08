---
name: solid-principles
description: SOLID 原則をコードの判断に落とし込む指針。単一責任(変更理由で測る)、開放閉鎖(ABC/Protocol による拡張点)、リスコフの置換(継承より合成、Django モデル継承の落とし穴)、インターフェース分離(太った抽象の分割)、依存性逆転(抽象への依存と注入)を、Python / Django の具体例と検出方法つきで扱う。コードをレビューするとき、クラスや関数が肥大化してきたとき、if 分岐が種類ごとに増えるとき、継承するか合成するか迷うとき、モックだらけのテストになったときに使う。
allowed-tools:
  - Read
  - Grep
  - Glob
---

# SOLID 原則

**5 つの原則は「変更にどう備えるか」の別々の切り口。** 暗記するものではなく、
**摩擦が出たときに当てる道具**として使う。前提は Python 3.10+ / Django。

依存性逆転の実装(リポジトリ抽象、composition root)は
[ddd-application-layer](../ddd-application-layer/SKILL.md) /
[ddd-aggregate-repository-boundary](../ddd-aggregate-repository-boundary/SKILL.md)、
モジュール間の依存関係は
[component-design](../component-design/SKILL.md)。

**適用の前提**: すべての原則にコストがある。**変更が実際に起きている場所**にだけ当てる。
起きていない変更に備えた抽象は、ただの複雑さ。

---

## 1. 単一責任 (SRP) — 変更理由で測る

**「1 つのことをする」ではなく「変更理由が 1 つ」。** 行数でも機能数でもない。

判定: **「このクラスを変更させる人は誰か」** を挙げる。2 人以上いたら割る。

```python
# NG: 変更理由が 3 つ
class OrderReport:
    def calculate_total(self): ...   # 経理が変える(税率・割引)
    def render_html(self): ...       # デザイナが変える
    def save_to_s3(self): ...        # インフラが変える
```

Django での典型:

| 症状 | 混ざっている責務 | 直し方 |
| --- | --- | --- |
| fat view(100 行超) | HTTP + 業務ルール + 永続化 | usecase へ抽出 |
| fat model | テーブル定義 + 業務ルール + 通知 | ドメインへ([ddd-legacy-refactoring](../ddd-legacy-refactoring/SKILL.md)) |
| serializer に業務判定 | 形式検証 + 業務ルール | 業務ルールはドメインへ |
| `utils.py` が数百行 | 無関係な関数の寄せ集め | 関心ごとにモジュール分割 |

- **「〜と〜をする」と説明したくなったら割る。**
- ただし**割りすぎも SRP 違反ではない**別の問題を生む。1 つの変更で 5 ファイル
  直すなら、それは割りすぎ([ddd-supple-design](../ddd-supple-design/SKILL.md)
  の「概念の輪郭」)。

---

## 2. 開放閉鎖 (OCP) — 種類が増えるなら拡張点を作る

**新しい種類を足すのに既存コードを書き換えるなら、閉じていない。**

```python
# NG: 支払方法が増えるたびに、この関数を書き換える
def calculate_fee(payment_type: str, amount: Decimal) -> Decimal:
    if payment_type == "credit":
        return amount * Decimal("0.03")
    elif payment_type == "bank":
        return Decimal(300)
    # 新種を足すたびにここを編集 = 修正に開いている

# OK: 抽象に対して開く
class PaymentMethod(ABC):
    @abstractmethod
    def fee_for(self, amount: Money) -> Money: ...


@dataclass(frozen=True, kw_only=True)
class CreditCard(PaymentMethod):
    def fee_for(self, amount: Money) -> Money:
        return amount.multiply(Decimal("0.03"))
```

- **`if` / `match` が「種類」で分岐し、同じ形が複数箇所に出たら**拡張点を作る合図。
- **1 箇所にしかない分岐は、そのままでよい。** 抽象化のコストが上回る。
- **「増える見込み」で作らない。** 2 回目に同じ形の分岐が出たときに作る。
- Python では `ABC` のほか **`Protocol`**(構造的部分型)も使える。実装側に
  継承を強制したくないときはこちら。

---

## 3. リスコフの置換 (LSP) — 派生型は約束を狭めない

**親の代わりに使えないなら、それは派生型ではない。**

```python
# NG: 親の約束(いつでも保存できる)を破っている
class ReadOnlyOrder(Order):
    def save(self) -> None:
        raise NotImplementedError("読み取り専用")   # ← 呼び出し側が壊れる
```

違反のサイン:

- サブクラスが**メソッドを無効化**する(`NotImplementedError` / `pass`)。
- サブクラスが**事前条件を強める**(親より厳しい引数チェック)。
- 呼び出し側に **`isinstance` 分岐**が要る。置換できていない証拠。

対処: **継承をやめて合成にする。** Python では特に、継承は
「is-a」でないと簡単に破綻する。

### Django モデル継承の落とし穴

| 種類 | 挙動 | 注意 |
| --- | --- | --- |
| **抽象基底**(`abstract = True`) | テーブルは子だけ | 安全。既定はこれ |
| **マルチテーブル継承** | 親子でテーブルが分かれ、暗黙 JOIN | 性能劣化。LSP も破れやすい |
| **プロキシモデル** | テーブル同じ、振る舞いだけ変える | 振る舞いを変えすぎると LSP 違反 |

**マルチテーブル継承は避ける。** 共通フィールドが欲しいだけなら抽象基底、
種類ごとに振る舞いが違うならドメイン側で型を分ける。

---

## 4. インターフェース分離 (ISP) — 使わないメソッドを強制しない

**実装側が「これは使わない」と思うメソッドがある抽象は、太すぎる。**

```python
# NG: 読み取りしかしない実装にも書き込みを強制する
class OrderRepository(ABC):
    def find_by_id(self, id): ...
    def save(self, order): ...
    def delete(self, order): ...
    def export_csv(self): ...        # ← 誰が使う?

# OK: 必要な分だけの抽象を、必要な場所が持つ
class OrderReader(Protocol):
    def find_by_id(self, order_id: OrderId) -> Order | None: ...


class OrderWriter(Protocol):
    def save(self, order: Order) -> None: ...
```

- **抽象は「使う側」が定義する。** usecase が必要とする操作だけを持つ
  Protocol を、usecase の近くに置く。
- 読み取り専用の関心は、そもそもリポジトリではなく query service へ
  ([ddd-read-model-cqrs](../ddd-read-model-cqrs/SKILL.md))。
- **テストのフェイクを書くときに露見する。** 「使わないメソッドを 5 個実装した」
  なら、その抽象は太い。

---

## 5. 依存性逆転 (DIP) — 上位が下位に依存しない

**方針(業務ルール)が、詳細(DB・HTTP・外部 API)に依存してはいけない。**
両方が抽象に依存する。

```python
# NG: usecase が具象を知っている
class PlaceOrder:
    def __init__(self) -> None:
        self._orders = DjangoOrderRepository()   # ← 詳細への依存

# OK: 抽象を受け取る。具象の選択は composition root
class PlaceOrder:
    def __init__(self, orders: OrderRepository) -> None:
        self._orders = orders
```

- **抽象は「使う側の層」に置く。** リポジトリの `ABC` はドメイン層、
  実装はインフラ層。ここで矢印が逆転する。
- **具象の選択は 1 か所**(composition root)。Django なら `apps.py` の `ready()`。
- **import の向きで検証できる**:

```bash
grep -rn "^from infrastructure\|^import infrastructure" src/*/domain/ src/*/usecases/ \
  && echo "DIP 違反: 上位が下位を import している" || echo "OK"
```

詳細は
[ddd-application-layer](../ddd-application-layer/SKILL.md) 第 5 節。

---

## 6. やりすぎの見分け

原則の適用自体が負債になることがある。**次が出たら戻す。**

| 症状 | 何が起きているか |
| --- | --- |
| 実装が 1 つしかない抽象が大量にある | 起きていない変更に備えている |
| 1 つの機能追加で 5 ファイル触る | 割りすぎ。輪郭を跨いでいる |
| テストがモックだらけで、何を検証しているか読めない | 抽象が多すぎる。フェイクで足りないか疑う |
| 実装を追うのに 4 ファイル開く | 間接化が深い |
| 抽象の名前が `IXxx` / `XxxImpl` だけ | 概念ではなく機械的な分割 |

**判断基準**: その抽象は**実際に差し替えたことがあるか / テストで差し替えているか**。
どちらでもないなら、消してよい。

---

## アンチパターン

| アンチパターン | なぜ悪いか |
| --- | --- |
| SRP を行数で判断する | 短くても変更理由が複数なら違反。長くても 1 つなら適切 |
| fat view / fat model にロジックを集める | 変更理由が混ざり、影響範囲が読めない |
| 種類の分岐を 1 箇所で `if` し続ける | 追加のたびに既存コードを壊すリスクを取る |
| 1 箇所の分岐に抽象を作る | コストだけ払って何も得ていない |
| サブクラスでメソッドを `NotImplementedError` にする | 置換できない。継承ではなく合成へ |
| 呼び出し側に `isinstance` 分岐がある | LSP が成立していない証拠 |
| Django のマルチテーブル継承 | 暗黙 JOIN で遅く、置換性も壊れやすい |
| 抽象に「念のため」メソッドを足す | 実装とフェイクの両方に負担がかかる |
| usecase が具象クラスを `new` する | 差し替え不能。テストに DB が要る |
| 実装が 1 つしかない抽象を量産する | 間接化のコストだけが残る |
| テストがモックだらけ | 抽象過多。フェイクで足りるか疑う |

---

## ルール(チェックリスト)

- [ ] **SRP**: 各クラスの「変更させる人」が 1 人。行数ではなく変更理由で測った
- [ ] fat view / fat model / 巨大 `utils.py` がない
- [ ] **OCP**: 同じ形の種類分岐が**2 回目**に出たときだけ拡張点を作った
- [ ] **LSP**: サブクラスがメソッドを無効化していない。`isinstance` 分岐がない
- [ ] Django のマルチテーブル継承を使っていない(抽象基底か、型を分ける)
- [ ] **ISP**: 抽象に、実装側が使わないメソッドが混ざっていない
- [ ] 抽象を**使う側**が定義している(必要な操作だけ)
- [ ] **DIP**: usecase / ドメインが具象を `new` していない
- [ ] 抽象はドメイン層、実装はインフラ層。**import の向きを grep で検証**した
- [ ] 具象の選択が composition root 1 か所に閉じている
- [ ] 実装が 1 つしかない抽象を量産していない(差し替え実績かテストでの差し替えがある)
- [ ] テストがモックだらけになっていない
