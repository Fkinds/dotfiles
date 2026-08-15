---
name: ddd-testing-strategy
description: DDD の層ごとのテスト方針。ドメイン層・usecase のテストを書く/レビューするとき、テストに DB やモックが必要になってきたとき、実装を変えるたびにテストが壊れるとき、何をどの層でテストするか決めるときに使う。扱う範囲はドメイン層をモックも DB もなしでテストする、不変条件と集約の振る舞いの検証、in-memory リポジトリ(フェイク)によるユースケースのテスト、リポジトリ実装の往復テスト、ドメインイベントの検証、テストデータビルダー、モックを使ってよい範囲。
allowed-tools:
  - Read
  - Grep
  - Glob
---

# DDD: テスト戦略 (Testing Strategy)

**層を分けた見返りは、テストで受け取る。** ドメイン層が stdlib のみに依存していれば、
そのテストは DB もフレームワークもモックも要らない — 速く、壊れにくく、読める。
テストに DB やモックが要るようになったら、それは**層が壊れている兆候**。

前提: pytest + Django。ドメイン層は stdlib のみ
([ddd-domain-object-completeness](../ddd-domain-object-completeness/SKILL.md))。

ユースケースの構造は
[ddd-application-layer](../ddd-application-layer/SKILL.md)、
リポジトリ抽象は
[ddd-aggregate-repository-boundary](../ddd-aggregate-repository-boundary/SKILL.md)、
イベントは
[ddd-domain-events](../ddd-domain-events/SKILL.md)。

---

## 1. 層ごとに、テストの種類を変える

| 層 | テストの種類 | DB | テストダブル | 量 |
| --- | --- | --- | --- | --- |
| `domain/` | 単体テスト。**純粋** | 不要 | **不要** | **最も多い** |
| `usecases/` | 単体テスト | 不要 | in-memory フェイク | 中 |
| `infrastructure/`(リポジトリ実装) | 統合テスト | **実 DB** | 不要 | 少(往復のみ) |
| `interfaces/`(view) | API テスト | 実 DB | 不要 | 少(疎通と HTTP 変換) |

**判定**: そのテストに `@pytest.mark.django_db` が要るなら、テスト対象は
ドメイン層ではない。ドメイン層のテストに DB マークが付いていたら、**テストではなく
実装のほうを疑う**。

> この表は「何を検証するか」の軸。**「何に依存するか」でサイズ(small/medium/large)に
> 分けて走らせる仕組み**は [test-harness](../test-harness/SKILL.md)。
> 上 2 行が small、下 2 行が medium に対応する。

### 4 本柱で優先度を決める

テストの価値は 4 つの軸で決まる。**どれを犠牲にしているか**を意識する。

| 柱 | 意味 | ドメイン層のテストの強み |
| --- | --- | --- |
| 退行に対する保護 | バグを捕まえるか | 業務ルールそのものを検証する。中心的 |
| リファクタリングへの耐性 | 実装を変えて壊れないか | **公開された振る舞いだけを見るので強い** |
| 迅速なフィードバック | 速いか | DB なし。ミリ秒 |
| 保守しやすさ | 読めるか・直しやすいか | セットアップが数行で済む |

内部実装(private メソッド、呼び出し回数)を検証すると、**耐性が落ちる** —
リファクタするたびにテストが赤くなり、やがてテストが信用されなくなる。

---

## 2. ドメイン層 — 入力と戻り値だけを見る

ドメインオブジェクトは frozen なので、振る舞いは**新しいインスタンスを返す**。
検証対象は**戻り値の状態**であって、内部の呼び出しではない。

```python
import pytest


class TestOrderCancel:
    def test_未出荷の注文は取り消せる(self) -> None:
        order = an_order(status=OrderStatus.PENDING)

        cancelled = order.cancel(reason=CancellationReason(value="顧客都合"))

        assert cancelled.status is OrderStatus.CANCELLED
        assert order.status is OrderStatus.PENDING  # 元は変わらない(frozen)

    def test_出荷済みの注文は取り消せない(self) -> None:
        order = an_order(status=OrderStatus.SHIPPED)

        with pytest.raises(ValueError, match="出荷済み"):
            order.cancel(reason=CancellationReason(value="顧客都合"))
```

- **frozen の確認を兼ねる。** 元のインスタンスが変わっていないことを 1 度は検証する。
- **`match=` でメッセージを縛る。** どの `ValueError` なのか区別できないと、
  別の理由で失敗しても緑になる。
- **private メソッドをテストしない。** テストしたくなったら、それは公開されるべき
  概念(値オブジェクトやドメインサービス)が隠れているサイン。

### 不変条件は「構築できないこと」でテストする

Always-Valid なドメインモデルの検証は、**構築が失敗すること**を確かめる。

```python
class TestEmail:
    @pytest.mark.parametrize("value", ["a@example.com", "user+tag@sub.example.jp"])
    def test_妥当な形式は構築できる(self, value: str) -> None:
        assert Email(value=value).value == value

    @pytest.mark.parametrize("value", ["", "no-at-mark", "@example.com"])
    def test_不正な形式は構築時に落ちる(self, value: str) -> None:
        with pytest.raises(ValueError):
            Email(value=value)
```

- **正常系と異常系の `parametrize` を分ける。** 1 つの parametrize に期待結果を
  混ぜると、テスト名から何を検証しているのか読めなくなる。
- **`validate()` を呼ぶテストを書かない。** そのテストが書けるということは、
  construct-then-validate になっている
  ([ddd-domain-object-completeness](../ddd-domain-object-completeness/SKILL.md))。
- 集約は**メンバーをまたぐ不変条件**を検証する(「明細が空の注文は作れない」)。

---

## 3. テストデータビルダー — セットアップを 1 行にする

集約の構築に 8 個の引数が要ると、テストの大半がセットアップで埋まり、
**何を検証しているのかが読めなくなる**。既定値を持つビルダーを用意する。

- **テストが気にする値だけを渡す。** `an_order(status=SHIPPED)` と書けば、
  「このテストは status だけを気にしている」が一目で分かる。
- **既定値は必ず妥当なものにする。** ビルダー経由で不正な集約が作れてはいけない。
- ビルダーは `tests/` に置く。**プロダクションコードに置かない。**
- Django の `factory_boy` は**永続化モデル用**。ドメインオブジェクトには
  素の関数で十分(依存も増えない)。

書き方は [fakes-and-builders.md](fakes-and-builders.md)。

---

## 4. ユースケース — in-memory フェイクで DB を外す

usecase は抽象に依存している
([ddd-application-layer](../ddd-application-layer/SKILL.md))。テストでは
**フェイク実装**を差し込む。フェイクと usecase テストの書き方は
[fakes-and-builders.md](fakes-and-builders.md)。

### フェイク > モック

| | フェイク (in-memory 実装) | モック (`Mock` / `patch`) |
| --- | --- | --- |
| 検証 | **結果の状態**を見る | 呼び出し回数・引数を見る |
| 耐性 | 実装を変えても壊れない | 実装を変えると壊れる |
| 実装 | 数十行、1 度書けば使い回せる | テストごとに設定が要る |

**既定はフェイク。** `assert mock.save.called_once_with(...)` は「保存を呼んだこと」しか
言えないが、`orders.find_by_id(...)` は「**正しく保存されたこと**」を言える。

- **フェイクは抽象を実装する。** `OrderRepository` を継承するので、抽象を変えたら
  フェイクもコンパイルエラーになる = 乖離しない。
- フェイクは `tests/fakes.py` にまとめ、全 usecase テストで共有する。
- **`unittest.mock.patch` でドメイン層を差し替えない。** ドメインは純粋なので
  差し替える理由がない。patch したくなったら、依存が注入されていない。

### モックを使ってよい場面

**自分たちが制御できない外部依存**(外部 API、メール送信、決済ゲートウェイ)との
**やり取りそのもの**が仕様である場合だけ。DB は自分たちの管理下なので、
モックではなく実 DB(第 5 節)かフェイクを使う。

> 外部 API アダプタ自体のテスト(翻訳ロジック、スタブでの再生、契約テストの分離)は
> [adapter-design](../adapter-design/SKILL.md)。

---

## 5. リポジトリ実装 — 実 DB で往復させる

**マッピングのバグは実 DB でしか出ない。** in-memory フェイクは
`_to_domain` / `_to_model` を一切通らない。

```python
@pytest.mark.django_db
class TestDjangoOrderRepository:
    def test_保存して読み戻すと同じ集約になる(self) -> None:
        repo = DjangoOrderRepository()
        order = an_order(lines=(an_order_line(quantity=3),))

        repo.save(order)
        restored = repo.find_by_id(order.id)

        assert restored == order                       # Entity は id 等価
        assert restored.lines == order.lines           # 値オブジェクトは値等価
        assert restored.status is order.status

    def test_存在しない id は None を返す(self) -> None:
        assert DjangoOrderRepository().find_by_id(OrderId(value=uuid.uuid4())) is None
```

- **往復 (round-trip) が本体。** 「保存 → 読み戻し → 一致」で、両方向のマッピングを
  同時に検証できる。
- **`Entity.__eq__` は id 比較**なので、`restored == order` だけでは中身が一致した
  ことにならない。**フィールドも明示的に検証する**。
- 復元で不変条件が再検査されること
  ([ddd-aggregate-repository-boundary](../ddd-aggregate-repository-boundary/SKILL.md))を、
  **壊れた行を直接 INSERT して `ValueError` が出る**テストで 1 本押さえておくと、
  検証を迂回する経路が後から生えたときに気付ける。
- リポジトリのテストは**このリポジトリの数だけ**。usecase ごとには要らない。
- SQLite ではなく**本番と同じ DB エンジン**で回す。制約やトランザクション挙動が違う。

---

## 6. ドメインイベントの検証

イベントは**集約の振る舞いの結果**なので、まず**ドメイン層で**検証する。

```python
def test_取り消すと OrderCancelled が積まれる() -> None:
    order = an_order(status=OrderStatus.PENDING)

    cancelled = order.cancel(reason=CancellationReason(value="顧客都合"))

    _, events = cancelled.pull_events()
    assert [type(e) for e in events] == [OrderCancelled]
    assert events[0].order_id == order.id


def test_取り消せない状態ではイベントが積まれない() -> None:
    order = an_order(status=OrderStatus.SHIPPED)

    with pytest.raises(ValueError):
        order.cancel(reason=CancellationReason(value="顧客都合"))
    assert order.pull_events()[1] == ()   # 失敗時に副作用がない
```

- **失敗時にイベントが出ないこと**を必ず 1 本書く。不変条件を満たす前に
  イベントを積むバグは、これでしか捕まらない。
- ハンドラは**冪等性を明示的にテストする**: 同じイベントを 2 回渡して、
  結果が 1 回のときと同じであることを検証する。
- 「確定後にディスパッチされる」ことは usecase のテストで見る
  (`RecordingEventBus` に、保存済みの状態が反映されている)。

---

## 7. 何をテストしないか

- **getter / `@property` 単体。** 振る舞いのテストが通れば通る。
- **`dataclass` が生成するもの**(`__eq__`、`__init__` の代入)。stdlib を信用する。
- **private メソッド。** 公開された振る舞い経由で覆う。
- **フェイク自身。** テスト用コードにテストは要らない。
- **カバレッジのためだけのテスト。** カバレッジは「テストされていない箇所」を
  見つける道具であって、目標値ではない。ドメイン層が高く、
  インフラ層が低いのは正常な形。

---

## アンチパターン

| アンチパターン | なぜ悪いか |
| --- | --- |
| ドメイン層のテストに `@pytest.mark.django_db` | ドメインが Django に依存している。層が壊れている |
| ドメイン層のテストで `patch` する | 純粋なので差し替える理由がない。依存が注入されていない |
| `mock.save.assert_called_once()` で満足する | 「呼んだ」しか言えない。正しく保存されたかは不明 |
| usecase のテストが実 DB を使う | 遅い。しかもリポジトリ実装のテストと重複している |
| private メソッドを直接テストする | リファクタリング耐性を失う。概念の抽出漏れのサイン |
| `validate()` を呼ぶテストがある | construct-then-validate になっている |
| セットアップが 20 行あるテスト | 何を検証しているか読めない。ビルダーへ |
| 正常系と異常系を 1 つの parametrize に混ぜる | テスト名から検証内容が読めない |
| 往復テストがなくマッピングが未検証 | 保存はできるが読み戻せない、が本番で出る |
| 失敗時にイベントが出ないテストがない | 不変条件より先にイベントを積むバグを見逃す |
| 本番と違う DB エンジンでリポジトリを試験 | 制約・トランザクション挙動の差を見逃す |

---

## ルール(チェックリスト)

- [ ] ドメイン層のテストが **DB なし・モックなし**で動く(`django_db` マークがない)
- [ ] 検証しているのは**戻り値の状態**であって、内部の呼び出し回数ではない
- [ ] frozen の性質(元インスタンスが変わらない)を検証している
- [ ] 不変条件を「**構築が失敗すること**」でテストしている(`pytest.raises` + `match=`)
- [ ] 正常系と異常系の `parametrize` が分かれている
- [ ] テストデータビルダーがあり、**テストが気にする値だけ**を渡している
- [ ] usecase のテストは **in-memory フェイク**を使い、DB を必要としない
- [ ] フェイクはリポジトリ抽象を**実装している**(抽象の変更で乖離しない)
- [ ] モックは**管理外の外部依存**にだけ使っている(DB には使っていない)
- [ ] リポジトリ実装に**往復テスト**があり、フィールドも明示的に検証している
- [ ] リポジトリのテストが**本番と同じ DB エンジン**で回っている
- [ ] イベントの検証がドメイン層にあり、**失敗時に積まれない**テストがある
- [ ] ハンドラの**冪等性**をテストしている(同じイベントを 2 回渡す)
- [ ] getter・`dataclass` 生成物・private メソッドをテストしていない
