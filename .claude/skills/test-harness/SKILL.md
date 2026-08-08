---
name: test-harness
description: テストを実行する仕組みの整備。依存する資源で切る small/medium/large のサイズ分類、ディレクトリと marker の自動付与による付け忘れ防止、サイズ違反を機械的に検出する仕組み(DB 接続・ソケットの遮断)、conftest.py の階層設計と fixture のスコープ、CI でサイズごとに分けて走らせる構成、実行時間の上限と遅いテストの扱いを扱う。テストが遅くなってきたとき、どのテストをいつ走らせるか決めるとき、pytest の marker や conftest を設計するとき、CI の実行時間を分けたいときに使う。
allowed-tools:
  - Read
  - Grep
  - Glob
---

# テストハーネス (Test Harness)

**何をテストするか**は
[ddd-testing-strategy](../ddd-testing-strategy/SKILL.md)(層ごとの方針)。
ここは**どう走らせるか** — 分類、marker、conftest、CI 構成。

前提: pytest + Django。

**サイズは層と別の軸。** 層は「何を検証するか」、サイズは「何に依存するか」。
対応はするが、同じものではない。

---

## 1. サイズは「依存する資源」で決まる

**実行時間で決めない。** 時間はマシン性能で変わり、境界がぶれる。
**何に依存するか**は客観的に判定できる。

| サイズ | 依存してよい資源 | 禁止 | 対応する層 |
| --- | --- | --- | --- |
| **small** | プロセス内のメモリのみ | **DB・ネットワーク・ファイル I/O・時刻・乱数・sleep** | `domain/` `usecases/` |
| **medium** | localhost の DB / キャッシュ | **外部ホストへの通信** | `infrastructure/` `interfaces/` |
| **large** | 外部システム、ブラウザ | — | E2E、契約テスト |

- **既定は small。** 新しいテストはまず small で書けないか考える。
- **medium に落ちるのは、実 DB でしか出ないバグを検証するときだけ**
  (マッピングの往復、制約違反、トランザクション挙動)。
- **large は最小限。** 主要な導線 1〜2 本。ここを増やすと CI が壊れやすくなる。

### 時間は「上限」として別に持つ

分類の基準にはしないが、**逸脱の検出には使う**。

| サイズ | 1 テストの目安 | 合計の上限 |
| --- | --- | --- |
| small | < 100ms | 数十秒(毎回走らせられること) |
| medium | < 2s | 数分 |
| large | 制限しない | 別枠 |

**small が遅いのは、依存が紛れ込んでいるサイン。** 時間で分類せず、時間で異常を見つける。

---

## 2. ディレクトリで分け、marker は自動で付ける

**手で `@pytest.mark.small` を書かせない。付け忘れる。**

```text
src/tests/
├── conftest.py           # 全体共通(最小限)
├── small/
│   ├── conftest.py       # DB 遮断・ソケット遮断
│   ├── domain/
│   └── usecases/
├── medium/
│   ├── conftest.py       # DB fixture
│   ├── repositories/
│   └── api/
└── large/
    └── conftest.py
```

```python
# src/tests/conftest.py
def pytest_collection_modifyitems(config, items):
    """ディレクトリからサイズ marker を自動付与する。"""
    for item in items:
        parts = item.nodeid.split("/")
        for size in ("small", "medium", "large"):
            if size in parts:
                item.add_marker(getattr(pytest.mark, size))
                break
        else:
            raise pytest.UsageError(f"サイズ未分類のテスト: {item.nodeid}")
```

- **未分類をエラーにする。** 「どこにも属さないテスト」を作らせない。
- ディレクトリ構成は**サイズが第 1 階層**。層はその下。逆にすると、
  「small だけ走らせる」がパスで表現できなくなる。

```toml
# pyproject.toml
[tool.pytest.ini_options]
markers = [
    "small: プロセス内のみ。DB・ネットワーク・ファイル I/O なし",
    "medium: localhost の DB / サービスまで",
    "large: 外部システム・ブラウザ",
]
addopts = "--strict-markers"     # 未定義 marker をエラーに
```

---

## 3. 違反を機械的に止める

**規約は破られる。** small で DB を触れないように**物理的に塞ぐ**。

```python
# src/tests/small/conftest.py
import pytest


@pytest.fixture(autouse=True)
def _no_db(request):
    """small では DB アクセスを禁止する。"""
    if request.node.get_closest_marker("django_db"):
        pytest.fail(
            f"small テストで django_db が使われている: {request.node.nodeid}\n"
            "→ medium/ へ移すか、フェイクで書き直す"
        )


@pytest.fixture(autouse=True)
def _no_socket(socket_disabled):
    """外部通信を遮断する(pytest-socket)。"""
```

- **`django_db` の検出**が最も効く。ドメイン層のテストに DB マークが付いたら、
  テストではなく実装を疑う([ddd-testing-strategy](../ddd-testing-strategy/SKILL.md))。
- **ソケット遮断**(`pytest-socket` の `--disable-socket`)で、
  うっかりの外部通信を落とす。
- **時刻と乱数も固定する。** `datetime.now()` を呼ぶコードは、そもそも
  引数で受け取る設計にする([ddd-modeling-primitives](../ddd-modeling-primitives/SKILL.md))。
  fixture で固定して誤魔化さない。
- medium でも**外部ホストへの通信は遮断**する(localhost だけ許可)。

---

## 4. conftest.py の階層

**上に置くほど広く効く。上には最小限しか置かない。**

| 場所 | 置くもの |
| --- | --- |
| `tests/conftest.py` | サイズ marker の自動付与、全体で使うビルダーの import |
| `tests/small/conftest.py` | DB / ソケットの遮断 |
| `tests/medium/conftest.py` | DB fixture、API クライアント |
| `tests/medium/api/conftest.py` | 認証済みクライアントなど、その範囲だけの fixture |

- **`autouse=True` を上位に置かない。** 全テストに効いてしまい、
  何が有効か追えなくなる。効かせたい範囲の conftest に置く。
- **fixture の定義場所 = 有効範囲**。使う場所の近くに置く。
- **テストデータビルダーは fixture にしない。** 素の関数にして import する。
  fixture にすると引数に現れ、何を渡したのかが読みにくくなる
  ([ddd-testing-strategy](../ddd-testing-strategy/SKILL.md))。

---

## 5. fixture のスコープ

**既定は `function`。** 広いスコープはテスト間の結合を生む。

| スコープ | 使ってよいもの | 注意 |
| --- | --- | --- |
| `function`(既定) | ほぼ全部 | 迷ったらこれ |
| `module` / `package` | 読み取り専用の重い準備 | 変更されると後続が壊れる |
| `session` | DB の作成、コンテナ起動 | **状態を持つものは置かない** |

- **`django_db` は関数ごとにロールバックされる。** テスト間でデータは残らない。
  `transaction=True` にすると残るので、必要なときだけ。
- **session スコープの fixture が状態を持つと、テストの実行順で結果が変わる。**
  並列実行で顕在化する。
- **`--randomly-seed` などで順序をランダム化**しておくと、依存に早く気付ける。

---

## 6. 実行コマンドと CI

**既定は small だけ。** 開発中に毎回走らせるのは small。

```bash
pytest -m small                    # 開発中(数十秒)
pytest -m "small or medium"        # コミット前
pytest -m large                    # 手動 / 日次
```

```toml
# 既定を small に固定するなら
addopts = "--strict-markers -m small"
```

| タイミング | サイズ | 目安 |
| --- | --- | --- |
| 保存時 / 開発中 | small | 数十秒 |
| **PR の CI** | small + medium | 数分 |
| マージ後 / 日次 | large | 別ジョブ |

- **CI ではサイズごとにジョブを分ける。** small が落ちた時点で medium を
  走らせない(fail fast)。
- **small は並列化する**(`pytest-xdist`)。依存がないので安全に分散できる。
  medium は DB を共有するので、並列度に注意(`--dist loadscope` など)。
- **large の失敗で PR をブロックしない。** 外部要因で落ちるため。
  ただし**失敗を放置しない**仕組み(通知、担当)は要る。

---

## 7. 遅いテスト・不安定なテストの扱い

- **遅い small を放置しない。** 100ms を超えたら、依存が紛れているか、
  ループが大きすぎる。`--durations=10` で定期的に上位を見る。
- **flaky なテストを `skip` で隠さない。** 隠すと検証していないのに緑になる。
  原因(順序依存、時刻、並列)を特定するか、**消す**。
- **リトライ(`pytest-rerunfailures`)は large だけ。** small/medium で必要なら、
  それは設計の問題。
- **`xfail` は理由と期限を書く。** 恒久的な `xfail` は死んだテスト。

---

## アンチパターン

| アンチパターン | なぜ悪いか |
| --- | --- |
| 実行時間でサイズを分類する | マシン性能で境界がぶれる。依存資源で切る |
| marker を手で付けさせる | 必ず付け忘れる。ディレクトリから自動付与する |
| サイズ未分類のテストを許す | どのタイミングで走るか誰も分からない |
| small で `django_db` を使う | サイズの意味が消える。conftest で止める |
| 規約をドキュメントだけで守らせる | 破られる。機械的に落とす |
| 層をディレクトリの第 1 階層にする | 「small だけ走らせる」がパスで表現できない |
| `autouse=True` を最上位の conftest に置く | 全テストに効き、何が有効か追えない |
| テストデータビルダーを fixture にする | 引数に現れず、何を渡したか読めない |
| session スコープの fixture が状態を持つ | 実行順で結果が変わる。並列で壊れる |
| CI で全サイズを 1 ジョブで走らせる | small の失敗を知るのに数分待つ |
| flaky を `skip` で隠す | 検証していないのに緑になる |
| small/medium にリトライを入れる | 不安定さを覆い隠す。設計を直す |
| `xfail` を期限なしで放置する | 死んだテストが残る |
| large の失敗で PR をブロックする | 外部要因で開発が止まる |

---

## ルール(チェックリスト)

- [ ] サイズを**依存する資源**で定義した(実行時間で分類していない)
- [ ] ディレクトリの**第 1 階層がサイズ**で、層はその下にある
- [ ] marker が**ディレクトリから自動付与**され、未分類がエラーになる
- [ ] `--strict-markers` で未定義 marker を弾いている
- [ ] small で **`django_db` とソケットが機械的に塞がれている**
- [ ] medium で**外部ホストへの通信が遮断**されている
- [ ] `autouse=True` が**効かせたい範囲の conftest** にだけある
- [ ] fixture のスコープが既定 `function`。session スコープが状態を持っていない
- [ ] テストデータビルダーが fixture ではなく**素の関数**
- [ ] 開発中に走らせるのは **small だけ**で、数十秒に収まっている
- [ ] CI が**サイズごとにジョブ分割**され、small から順に走る
- [ ] small を**並列化**している
- [ ] `--durations` で遅いテストを定期的に見ている
- [ ] flaky を `skip` / リトライで隠していない
- [ ] `xfail` に理由と期限が書かれている
