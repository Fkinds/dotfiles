---
name: ci-test-performance
description: CI でのテスト実行を速くする具体策。ボトルネックの測り方、DB セットアップの再利用(--reuse-db・マイグレーション回避・テンプレート DB)、pytest-xdist の並列度とワーカーごとの DB 分離、Django のテスト専用設定(パスワードハッシャ・ログ・キャッシュ)、依存と Docker レイヤのキャッシュ、変更差分に基づく選択実行、GitHub Actions のジョブ分割と matrix を扱う。CI が遅いとき、DB のセットアップに時間がかかるとき、並列化で DB が衝突するとき、どこが遅いのか分からないときに使う。
allowed-tools:
  - Read
  - Grep
  - Glob
---

# CI テストの高速化 (CI Test Performance)

テストの**分類と配置**(small/medium/large、marker、conftest)は
[test-harness](../test-harness/SKILL.md)。ここは**速度そのもの**を上げる手段。

前提: pytest + pytest-django + GitHub Actions。

**順序が重要。** 上から順に効果が大きく、コストが小さい。
下の手段(選択実行、キャッシュの作り込み)から手を付けると、労力の割に効かない。

---

## 1. まず測る

**推測で最適化しない。** ほとんどの場合、遅いのは一部のテストか、テスト以外の工程。

```bash
pytest --durations=20                      # 遅いテスト上位 20
pytest --durations=0 --durations-min=1.0   # 1 秒以上を全部
pytest --collect-only -q | wc -l           # 収集数(収集自体が遅いこともある)
```

CI 全体では、**工程ごとの時間**を見る。

| 工程 | よくある割合 | 効く手段 |
| --- | --- | --- |
| 依存インストール | 大きい | キャッシュ(第 6 節) |
| **DB セットアップ / マイグレーション** | **大きい** | 第 3 節 |
| テスト実行 | — | 並列化(第 4 節) |
| 収集 (collection) | 稀に大きい | 収集対象の絞り込み |

**「テストが遅い」と思ったら、実は依存インストールとマイグレーションだった**
というのが最頻。先に工程を分解する。

---

## 2. そもそも DB を使わない

**最も効く。** DB を使わないテストは 1〜2 桁速い。

- ドメイン層と usecase は **DB なしで書ける**
  ([ddd-testing-strategy](../ddd-testing-strategy/SKILL.md))。
- **small で `django_db` を機械的に塞ぐ**と、なし崩しに増えない
  ([test-harness](../test-harness/SKILL.md))。
- 既存テストで `django_db` が付いているものを数え、**減らせる比率**を見る。

```bash
grep -rl "django_db" src/tests/ | wc -l          # DB を使うテストファイル数
```

**この節を飛ばして並列化に進まない。** 遅いテストを並列に流しても、
CI 費用が増えるだけで根本は変わらない。

---

## 3. DB のセットアップを再利用する

DB を使うと決めたら、**毎回作り直さない**。

```bash
pytest --reuse-db          # 既存のテスト DB を再利用(既定は毎回 drop/create)
pytest --create-db         # 明示的に作り直す(スキーマを変えたとき)
pytest --no-migrations     # マイグレーションを流さず、モデルから直接スキーマを作る
```

| 手段 | 効果 | 注意 |
| --- | --- | --- |
| **`--reuse-db`** | 作成・マイグレーションを飛ばす | スキーマ変更時は `--create-db` が要る |
| **`--no-migrations`** | **マイグレーションが多いほど激減** | マイグレーション自体は検証されなくなる |
| テンプレート DB (PostgreSQL) | `CREATE DATABASE ... TEMPLATE` で複製 | 並列時に効く(第 4 節) |

- **`--no-migrations` を既定にするなら、マイグレーションの検証を別ジョブで行う。**
  「マイグレーションを流して起動する」だけの medium テストを 1 本置く。
  これがないと、本番でだけ落ちる。
- **CI では毎回クリーンな DB になる**ので、`--reuse-db` はローカル向け。
  CI で効かせるなら DB をキャッシュするのではなく、**`--no-migrations`** を使う。
- データ投入は**テスト内でビルダー**([ddd-testing-strategy](../ddd-testing-strategy/SKILL.md))。
  巨大な fixture ファイル(`loaddata`)は遅く、壊れやすい。

---

## 4. 並列化とワーカーごとの DB 分離

```bash
pytest -n auto             # CPU 数に合わせる(pytest-xdist)
pytest -n 4 --dist loadscope
```

**pytest-django は、ワーカーごとに別の DB を自動で作る**(`test_xxx_gw0`,
`test_xxx_gw1`, …)。ここが競合の温床。

| 設定 | 意味 | 使いどころ |
| --- | --- | --- |
| `--dist load`(既定) | テスト単位で分散 | small(依存がない) |
| **`--dist loadscope`** | **クラス / モジュール単位**で分散 | medium。同じ fixture を使い回せる |
| `--dist loadfile` | ファイル単位 | モジュールスコープの重い準備がある場合 |

- **small は `-n auto` で素直に速くなる。** 依存がないので分散が安全。
- **medium の並列度は DB の接続数と相談。** ワーカー数だけ DB が増えるので、
  接続上限・メモリ・ディスクを超えると**かえって遅くなる**。
- **PostgreSQL ならテンプレート DB**が効く。1 回だけマイグレーションを流した DB を
  テンプレートにし、ワーカーはそこから複製する。
- **並列で落ちるようになったら、それは元々バグっている。** 順序依存・
  session スコープの状態・共有ファイルを疑う([test-harness](../test-harness/SKILL.md))。
  並列度を下げて隠さない。

---

## 5. Django のテスト専用設定

**本番設定のままテストを走らせない。** 特にパスワードハッシュは効く。

```python
# settings/test.py
PASSWORD_HASHERS = ["django.contrib.auth.hashers.MD5PasswordHasher"]  # bcrypt は遅い
DEBUG = False                       # True だとクエリを溜め込みメモリを食う
LOGGING = {"version": 1, "disable_existing_loggers": True}
EMAIL_BACKEND = "django.core.mail.backends.locmem.EmailBackend"
CACHES = {"default": {"BACKEND": "...locmem.LocMemCache"}}
STORAGES = {...}                    # 外部ストレージを使わない
```

| 設定 | 効果 |
| --- | --- |
| **`PASSWORD_HASHERS` を MD5 に** | ユーザーを作るテストが多いほど効く。**定番かつ効果大** |
| `DEBUG = False` | クエリログの蓄積を止める |
| ログを無効化 | I/O とフォーマットのコストを削る |
| メール・キャッシュ・ストレージをメモリに | 外部依存を消す |

- **テスト専用設定は本番と別ファイルに。** `if TESTING:` の分岐を本番設定に
  入れない([ddd-django-pitfalls](../ddd-django-pitfalls/SKILL.md))。
- `TransactionTestCase` / `pytest.mark.django_db(transaction=True)` は
  **テーブルを truncate するので遅い**。必要なときだけ使う。

---

## 6. キャッシュ (GitHub Actions)

```yaml
- uses: actions/setup-python@v5
  with:
    python-version: "3.12"
    cache: pip                    # or poetry / uv

- uses: actions/cache@v4          # Docker を使うなら層もキャッシュ
  with:
    path: ~/.cache/pytest
    key: pytest-${{ hashFiles('pyproject.toml') }}
```

- **キャッシュキーはロックファイルのハッシュ**にする。`pyproject.toml` だけだと
  依存の解決結果が変わっても当たってしまう。
- **キャッシュが効いているか確認する。** miss し続けているキャッシュは、
  保存のコストだけ払っている。ログで hit/miss を見る。
- **サービスコンテナで DB を立てる**なら、起動待ちを `--health-cmd` で行う。
  `sleep` で待つと不安定かつ遅い。

```yaml
services:
  postgres:
    image: postgres:16
    options: >-
      --health-cmd pg_isready --health-interval 10s --health-retries 5
```

---

## 7. ジョブを分ける (GitHub Actions)

```yaml
jobs:
  small:
    steps:
      - run: pytest -m small -n auto        # 数十秒
  medium:
    needs: small                            # small が緑のときだけ
    services: { postgres: ... }
    steps:
      - run: pytest -m medium --no-migrations --dist loadscope -n 4
  large:
    if: github.event_name == 'schedule'     # 日次
```

- **`needs` で直列にする。** small が落ちているのに medium を回すのは無駄。
- **large は PR をブロックしない**(外部要因で落ちる)。ただし失敗の通知は要る。
- **matrix で分割するのは、単一ジョブが長すぎるときだけ。** ジョブ起動の
  オーバーヘッド(依存インストール)が毎回かかるので、細かく割ると逆効果。
- **`timeout-minutes` を設定する。** ハングしたジョブが枠を占有し続けるのを防ぐ。

---

## 8. 選択実行(最後の手段)

**変更に関係するテストだけ走らせる。** 効果は大きいが、**取りこぼしのリスク**がある。

| 手段 | 仕組み | リスク |
| --- | --- | --- |
| パスベース(変更ファイルからディレクトリを推定) | 単純 | 依存を見ないので漏れる |
| `pytest-testmon` | 実行時のカバレッジで依存を追跡 | DB が絡むと精度が落ちる |

- **PR では選択実行、マージ前 / 日次で全実行**、という組み合わせにする。
  選択実行だけにしない。
- **ここに手を付ける前に、第 2〜5 節をやり切る。** 選択実行は複雑さを持ち込む割に、
  DB を減らす効果より小さいことが多い。

---

## アンチパターン

| アンチパターン | なぜ悪いか |
| --- | --- |
| 測らずに最適化する | 遅いのが依存インストールやマイグレーションのことが多い |
| DB を減らさずに並列化する | CI 費用が増えるだけで根本は変わらない |
| `--no-migrations` にしてマイグレーション検証を捨てる | 本番でだけ落ちる。別ジョブで検証する |
| CI で `--reuse-db` に頼る | CI は毎回クリーン。効かない |
| 巨大な fixture ファイルを `loaddata` する | 遅く、スキーマ変更で壊れる |
| 並列で落ちるので並列度を下げる | 元々あるバグを隠している |
| ワーカー数を増やしすぎる | DB 接続とメモリを食い、かえって遅くなる |
| 本番設定のままテストする | bcrypt・ログ・外部ストレージがそのまま効く |
| 本番設定に `if TESTING:` を書く | 設定が読めなくなる。ファイルを分ける |
| `transaction=True` を既定にする | truncate が走り遅い |
| キャッシュキーが `pyproject.toml` だけ | 依存の解決結果が変わっても当たる |
| DB の起動を `sleep` で待つ | 不安定かつ遅い。health check を使う |
| matrix で細かく割りすぎる | ジョブ起動のオーバーヘッドが毎回かかる |
| `timeout-minutes` を設定しない | ハングしたジョブが枠を占有する |
| 選択実行だけで済ませる | 取りこぼしが本番に出る。全実行を別に持つ |

---

## ルール(チェックリスト)

- [ ] **まず測った**(`--durations`、工程ごとの時間)
- [ ] 遅い原因が**テスト実行なのか、依存/マイグレーションなのか**を切り分けた
- [ ] **DB を使うテストの比率**を把握し、減らせるものを減らした
- [ ] `--no-migrations` を使うなら、**マイグレーション検証を別ジョブ**に持っている
- [ ] データ投入が**ビルダー**で、巨大な `loaddata` に頼っていない
- [ ] small を **`-n auto`** で並列化している
- [ ] medium の並列度を **DB 接続数・メモリと相談**して決めた
- [ ] 並列で落ちるテストを**並列度を下げて隠していない**
- [ ] テスト専用設定があり、**`PASSWORD_HASHERS` が MD5**、ログが無効
- [ ] 本番設定に `if TESTING:` の分岐がない
- [ ] キャッシュキーが**ロックファイルのハッシュ**で、hit しているか確認した
- [ ] DB の起動待ちが **health check**(`sleep` ではない)
- [ ] CI が**サイズごとにジョブ分割**され、`needs` で直列になっている
- [ ] large が PR をブロックしない。ただし失敗の通知はある
- [ ] `timeout-minutes` が設定されている
- [ ] 選択実行を使うなら、**全実行を別のタイミング**で持っている
