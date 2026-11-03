# テスト設計技法の実装例

[test-design-techniques](SKILL.md) の各技法を pytest / Hypothesis で書いた例。
ビルダー(`an_application()` など)は
[ddd-testing-strategy](../ddd-testing-strategy/SKILL.md) の流儀に従う。

---

## 同値分割法 + 境界値分析

仕様: 年齢 0〜12 は子供、13〜64 は大人、65〜120 はシニア。それ以外は受け付けない。

| パーティション | 範囲 | 種別 |
| --- | --- | --- |
| 子供 | 0〜12 | 有効 |
| 大人 | 13〜64 | 有効 |
| シニア | 65〜120 | 有効 |
| 下限未満 | 〜-1 | 無効 |
| 上限超過 | 121〜 | 無効 |

区分の切り替わりは料金の業務ルールそのものなので 3 値で取る。

```python
@pytest.mark.parametrize(
    ("age", "expected"),
    [
        pytest.param(0, FareCategory.CHILD, id="子供の下限(0)"),
        pytest.param(1, FareCategory.CHILD, id="子供の下限の隣(1)"),
        pytest.param(11, FareCategory.CHILD, id="子供の上限の隣(11)"),
        pytest.param(12, FareCategory.CHILD, id="子供の上限(12)"),
        pytest.param(13, FareCategory.ADULT, id="大人の下限(13)"),
        pytest.param(14, FareCategory.ADULT, id="大人の下限の隣(14)"),
        pytest.param(63, FareCategory.ADULT, id="大人の上限の隣(63)"),
        pytest.param(64, FareCategory.ADULT, id="大人の上限(64)"),
        pytest.param(65, FareCategory.SENIOR, id="シニアの下限(65)"),
        pytest.param(66, FareCategory.SENIOR, id="シニアの下限の隣(66)"),
        pytest.param(119, FareCategory.SENIOR, id="シニアの上限の隣(119)"),
        pytest.param(120, FareCategory.SENIOR, id="シニアの上限(120)"),
    ],
)
def test_有効な年齢は区分に振り分けられる(age: int, expected: FareCategory) -> None:
    assert fare_category(age) is expected


@pytest.mark.parametrize(
    "age",
    [
        pytest.param(-1, id="下限未満の境界(-1)"),
        pytest.param(121, id="上限超過の境界(121)"),
    ],
)
def test_範囲外の年齢は受け付けない(age: int) -> None:
    with pytest.raises(ValueError, match="年齢"):
        fare_category(age)
```

- 有効パーティションの代表値(5、30、80)は書いていない。境界とその隣が各パーティションの中にあるので、
  代表値はそれで兼ねている。
- 無効な値は 1 ケースに 1 つ。引数が年齢だけなので自然にそうなるが、引数が増えたら
  意識して守る。

---

## デシジョンテーブルテスト

仕様: 離島は一律 1,500 円。それ以外は、会員か合計 5,000 円以上なら無料、どちらでもなければ 500 円。

| 条件 / 動作 | R1 | R2 | R3 | R4 |
| --- | --- | --- | --- | --- |
| 離島 | Y | N | N | N |
| 会員 | - | Y | N | N |
| 合計 5,000 円以上 | - | - | Y | N |
| **送料** | **1,500** | **0** | **0** | **500** |

8 通りの組み合わせが、「-」(結果に効かない条件)で 4 列に畳める。

```python
@pytest.mark.parametrize(
    ("remote_island", "member", "subtotal", "expected"),
    [
        # 「-」の条件には、結果に効かないことが分かる値を選ぶ
        pytest.param(True, True, yen(5000), yen(1500), id="R1 離島"),
        pytest.param(False, True, yen(4999), yen(0), id="R2 会員"),
        pytest.param(False, False, yen(5000), yen(0), id="R3 非会員で5000円以上"),
        pytest.param(False, False, yen(4999), yen(500), id="R4 非会員で5000円未満"),
    ],
)
def test_送料は規則の表に従う(
    remote_island: bool, member: bool, subtotal: Money, expected: Money
) -> None:
    assert shipping_fee(remote_island=remote_island, member=member, subtotal=subtotal) == expected
```

- 列が 1 行、id が列の名前。表に列を足したら、ここに 1 行足す。
- R1 の「-」には、他の列なら無料になる値(会員・5,000 円)を入れている。
  「離島の判定が先に効く」ことまで同時に確かめられる。
- 4,999 と 5,000 は境界値分析から来ている。技法は重ねてよい。

---

## 状態遷移テスト

全遷移(有効な遷移と無効な遷移の全ペア)は、遷移表から生成する
([ddd-state-transition](../ddd-state-transition/SKILL.md) 第 7 節)。

遷移の**並び**で壊れる不具合は、Hypothesis のステートフルテストに操作列を生成させる。

```python
from hypothesis import strategies as st
from hypothesis.stateful import RuleBasedStateMachine, invariant, rule

# 遷移先ごとに、その遷移を起こす業務の操作
_OPERATIONS = {
    ApplicationStatus.SUBMITTED: lambda a: a.submit(),
    ApplicationStatus.APPROVED: lambda a: a.approve(approved_by=REVIEWER, at=NOW),
    ApplicationStatus.REJECTED: lambda a: a.reject(rejected_by=REVIEWER, at=NOW),
    ApplicationStatus.CANCELLED: lambda a: a.cancel(),
}


class ApplicationLifecycle(RuleBasedStateMachine):
    def __init__(self) -> None:
        super().__init__()
        self.application = an_application(status=ApplicationStatus.DRAFT)

    @rule(to=st.sampled_from(list(_OPERATIONS)))
    def operate(self, to: ApplicationStatus) -> None:
        if to in _ALLOWED[self.application.status]:
            self.application = _OPERATIONS[to](self.application)
            assert self.application.status is to
        else:
            with pytest.raises(ValueError):
                _OPERATIONS[to](self.application)

    @invariant()
    def 承認日時は承認済みのときだけある(self) -> None:
        approved = self.application.status is ApplicationStatus.APPROVED
        assert (self.application.approved_at is not None) == approved


TestApplicationLifecycle = ApplicationLifecycle.TestCase
```

- 期待値の根拠は遷移表(`_ALLOWED`)。表そのものが業務と合っているかは、表を業務に
  確認して押さえる。このテストが見るのは、**操作をどう並べても**表と不変条件が守られること。
- 無効な操作で例外が出たあとも `self.application` は変わらないので、次の操作は同じ状態から
  試される(無効な遷移を 1 つずつ試すのと同じ)。

---

## 組み合わせテスト(ペアワイズ)

仕様: 帳票の出力。形式 3 種 × 文字コード 2 種 × 圧縮 3 種 × ヘッダ行の有無 2 種 = 36 通り。
JSON にはヘッダ行がない。

```python
from itertools import combinations, product

from allpairspy import AllPairs

_ENCODINGS = ["utf-8", "shift_jis"]
_COMPRESSIONS = ["none", "zip", "gzip"]

# JSON にはヘッダ行がないので、表形式と JSON でモデルを分けて生成する
_ROWS = [
    *(tuple(r) for r in AllPairs([["csv", "xlsx"], _ENCODINGS, _COMPRESSIONS, [True, False]])),
    *(tuple(r) for r in AllPairs([["json"], _ENCODINGS, _COMPRESSIONS, [False]])),
]


@pytest.mark.parametrize(("fmt", "encoding", "compression", "with_header"), _ROWS)
def test_出力した帳票を読み戻せる(
    fmt: str, encoding: str, compression: str, with_header: bool
) -> None:
    data = export_report(
        SAMPLE_ROWS, fmt=fmt, encoding=encoding, compression=compression, with_header=with_header
    )

    assert read_report(data, fmt=fmt, encoding=encoding, compression=compression) == SAMPLE_ROWS


def test_生成した組はあり得るペアをすべて含む() -> None:
    parameters = [["csv", "xlsx", "json"], _ENCODINGS, _COMPRESSIONS, [True, False]]
    impossible = {((0, "json"), (3, True))}
    expected = {
        ((i, x), (j, y))
        for (i, xs), (j, ys) in combinations(enumerate(parameters), 2)
        for x, y in product(xs, ys)
    } - impossible
    covered = {pair for row in _ROWS for pair in combinations(enumerate(row), 2)}

    assert expected - covered == set()


def test_JSON_にヘッダ行は指定できない() -> None:
    with pytest.raises(ValueError, match="ヘッダ"):
        export_report(SAMPLE_ROWS, fmt="json", encoding="utf-8", compression="none", with_header=True)
```

- 36 通りが 14 件になる。id は pytest が値から作る(`csv-utf-8-none-True`)ので、
  そのままで読める。
- JSON の組を別に生成しているので、`filter_func` を使わずに済む。同じ制約を
  `filter_func` で渡すと 9 件になるが、csv と zip のペアが抜ける。網羅の検査テストは
  その抜けを検出する。
- あり得ない組(JSON + ヘッダ行)が**拒否されること**は、別のテストで 1 件だけ確かめる。
- `allpairspy` は 2023 年 7 月の 2.5.1 から更新が止まっている。純 Python で今も動くが、
  README のとおり最小のケース集合は作らない。網羅の検査テストがあれば、道具を
  差し替えても同じテストで確かめられる。

---

## ランダムテスト(性質)

[ddd-modeling-primitives](../ddd-modeling-primitives/SKILL.md) の `Money.allocate` を例にする。
`yen(n)` は `Money(amount=Decimal(n), currency=JPY)` を作るテスト用の関数。

```python
from decimal import Decimal

from hypothesis import example, given
from hypothesis import strategies as st

amounts = st.integers(min_value=0, max_value=10**9).map(yen)
# 比率は有効パーティション(正の整数)だけを作る。0 や負値は別のテストで試す
ratios = st.lists(st.integers(min_value=1, max_value=100), min_size=1, max_size=10).map(tuple)


@given(amount=amounts, ratios=ratios)
@example(amount=yen(1000), ratios=(1, 1, 1))  # 端数が出る(1000 / 3)
@example(amount=yen(0), ratios=(1,))           # 金額の下限
def test_按分の合計は元の金額に一致する(amount: Money, ratios: tuple[int, ...]) -> None:
    shares = amount.allocate(ratios)

    assert sum((s.amount for s in shares), Decimal(0)) == amount.amount
    assert len(shares) == len(ratios)
```

- 期待値(各人の取り分)を書かず、**どの入力でも成り立つ性質**(合計の一致)を書いている。
- 端数が出る組と金額の下限は `@example` で固定し、毎回必ず試す。
- **性質では、端数を誰に配るかは確かめられない。** 先頭に配っても末尾に配っても
  合計は一致する。行き先は業務ルールなので、`1000 / 3` の期待値を具体的に書いた
  通常のテストを別に 1 本置く。

---

## メタモルフィックテスト

個々の取り分は端数の配り方に左右され、手で計算しにくい。代わりに入力の変え方と
出力の関係を確かめる。

```python
@given(amount=amounts, ratios=ratios, k=st.integers(min_value=2, max_value=10))
def test_比率をすべて_k_倍しても按分結果は変わらない(
    amount: Money, ratios: tuple[int, ...], k: int
) -> None:
    scaled = tuple(r * k for r in ratios)

    assert amount.allocate(scaled) == amount.allocate(ratios)
```

- 「比率 1:2 と 2:4 は同じ配分」は業務の言葉で言える関係。
- 元の入力(`amount`, `ratios`)は Hypothesis が作り、テストは変換(k 倍)と関係(等しい)
  だけを書く。

---

## カバレッジで抜けを測る

分岐の計測を既定にしておくと、コマンドに `--cov-branch` を付け忘れない。

```toml
# pyproject.toml
[tool.coverage.run]
branch = true

[tool.coverage.report]
show_missing = true
```

```bash
pytest --cov=<package>
```

`Missing` の列に `12->15` のように出たら、12 行目の分岐から 15 行目へ進む側が
一度も通っていない。その分岐が仕様のどの同値パーティションやデシジョンテーブルの列に当たるかを
確かめ、抜けていたパーティションか列をテストに足す。
