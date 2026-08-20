# composition root の組み立て

[ddd-application-layer](SKILL.md) 第 5 節の詳細。

## 目次

- **composition root の実装** — ファクトリ関数、置き場所、設定値の渡し方
- **実装の切り替え — Real / Fake / Noop** — 設定で具象を選ぶ、分岐の中で import する、
  設定漏れの既定、Noop に差し替えたテストが検証していないもの
- **`apps.py` の `ready()` を使うとき** — 起動時に 1 回だけやること
- **スコープ** — 使い捨てを既定にする
- **DI コンテナを入れるか** — 入れてよい条件

## composition root の実装

**ファクトリ関数から始める。** DI コンテナは、これで足りなくなってから。

```python
# infrastructure/factories.py  ← ここが composition root
def build_cancel_order() -> CancelOrder:
    return CancelOrder(DjangoOrderRepository(), DjangoEventBus())


# interfaces/views.py
class CancelOrderView(APIView):
    def post(self, request, order_id):
        usecase = build_cancel_order()          # 具象を知るのはここだけ
        output = usecase.execute(CancelOrderCommand(...))
```

- **`infrastructure/` に置く。** ここだけが全層を知ってよい。`usecases/` や
  `domain/` にファクトリを置くと、内側が外側を import することになる。
- **view に `DjangoOrderRepository()` を直接書かない。** 差し替え点が
  view の数だけ増える。
- 設定値(API キー、URL)はここで `settings` から読んで**引数として渡す**。
  usecase もドメインも `settings` を知らない
  ([ddd-django-pitfalls](../ddd-django-pitfalls/SKILL.md))。

## 実装の切り替え — Real / Fake / Noop

**ポートごとに複数の実装を持ち、どれを使うかは設定で決める。** 切り替えを用意して
おかないと、テストや開発でも本番アダプタが動くか、モックで塞ぐ羽目になる。

| 実装 | 何をするか | 使う場面 |
| --- | --- | --- |
| **Real** | 本物を叩く | 本番・ステージング |
| **Fake** | 副作用を起こさず、**検証できる状態を持つ**(送った内容を配列に貯める等) | ローカル開発、E2E、デモ |
| **Noop** | 何もせず成功を返す | 副作用だけ止めたい環境 |

```python
# infrastructure/factories.py
def build_order_notifier() -> OrderNotifier:
    match settings.ADAPTERS["notifier"]:
        case "real":
            from .adapters.notifier.real import EmailOrderNotifier   # ← 関数の中で import
            return EmailOrderNotifier(api_key=settings.SENDGRID_API_KEY, timeout=5.0)
        case "fake":
            from .adapters.notifier.fake import FakeOrderNotifier
            return FakeOrderNotifier()
        case "noop":
            from .adapters.notifier.noop import NoopOrderNotifier
            return NoopOrderNotifier()
        case other:
            raise ImproperlyConfigured(f"未知のアダプタ設定: {other!r}")
```

- **import は分岐の中に書く。** モジュールトップで 3 つとも import すると、テストでも
  `real.py` が読まれ、その先の SDK 初期化や認証情報の要求まで走る。**アプリの import
  グラフから本番アダプタを外すのが、この分岐の主目的。**
- **未知の値は例外にする。** 黙って既定へ落とすと、設定ミスが本番まで気付かれない。
- 設定は環境ごとに置く。`base.py` に安全側の既定、`production.py` で Real に上書き。

```python
# settings/base.py        ADAPTERS = {"notifier": "noop", "payment": "noop"}
# settings/production.py  ADAPTERS = {"notifier": "real", "payment": "real"}
# settings/test.py        ADAPTERS = {"notifier": "fake", "payment": "fake"}
```

**既定は副作用の向きで決める。**

| ポートの性質 | 設定漏れのときの既定 | 理由 |
| --- | --- | --- |
| 外向きの副作用(送信・課金・通知) | **Noop** | 誤爆は取り返しがつかない。何も起きない方が安全 |
| 読み取り(取得・照会) | **例外** | 黙って空を返すと、業務判断が静かに狂う |

- **本番設定で Fake / Noop を選べないようにする。** `production.py` で値を検証し、
  `real` 以外なら起動時に落とす。ローカルの設定が本番に紛れ込む事故を防ぐ。
- **Fake と、単体テストのフェイクは別物。** ここでの Fake は**アプリを fake モードで
  起動する**ための実装で `infrastructure/` に置く。usecase の単体テストに直接注入する
  in-memory 実装は `tests/` に置く([ddd-testing-strategy](../ddd-testing-strategy/SKILL.md))。
  同じ Protocol を実装するが、寿命も置き場も違う。

### Noop に差し替えたテストは、その副作用を検証していない

当たり前に見えて、**テストが緑であることを根拠に本番を信用してしまう**事故はここから出る。

| Noop にしたもの | そのテストで分からなくなること |
| --- | --- |
| トランザクション | ロールバックの成否、1 トランザクションに複数の集約が入っていないか、`on_commit` の発火 |
| 通知・メール | 宛先と本文の組み立て、そもそも送っているか |
| 外部 API | リクエストの形、失敗時の分岐 |

**Noop で回すテストと、実物で検証するテストは別に要る。** 前者だけだと、テストは緑のまま
本番で壊れる。トランザクションなら実 DB の medium テストで境界を検証する
([test-harness](../test-harness/SKILL.md))。
[ddd-django-pitfalls](../ddd-django-pitfalls/SKILL.md) の「`on_commit` の検証を
`TestCase` でやると、コールバックが実行されないまま通ったように見える」は同じ形の罠。

**Noop を選ぶ理由は「速いから」ではない。** その依存を持たない環境でコードを動かすため。
速度を理由にすると、実物で検証すべきテストまで Noop に倒れる。

## `apps.py` の `ready()` を使うとき

シグナル配線やイベントハンドラの登録など、**起動時に 1 回だけ**やることはここ。

```python
class SalesConfig(AppConfig):
    def ready(self) -> None:
        from .infrastructure.events import register_handlers
        register_handlers(event_bus)     # import は ready() の中で(循環回避)
```

- **`ready()` でリポジトリのインスタンスを作らない。** 起動時に 1 個作って
  使い回すと、リクエスト間で状態を共有してしまう。
- import は関数の内側に書く。モジュールトップに置くとアプリ読み込み中に
  評価され、循環 import になりやすい。

## スコープ — 使い捨てを既定にする

| スコープ | 対象 | 判断 |
| --- | --- | --- |
| **リクエストごとに生成** | usecase、リポジトリ | **既定。**状態を持たないので生成コストは無視できる |
| プロセス全体で共有 | 設定オブジェクト、接続プール | 状態がスレッドセーフなときだけ |

**リポジトリを使い回さない。** Django の `objects` はリクエストごとの
トランザクションと結びつくので、使い捨てが安全。

## DI コンテナを入れるか

**既定は入れない。** `dependency-injector` などは Django では過剰になりやすい。

入れてよいのは、次が両方とも当てはまるとき。

- ファクトリ関数が **20 個以上**になり、依存の重複が目立つ。
- 環境(本番 / ステージング / テスト)で**実装を切り替える**必要が実在する。

入れる場合も、**コンテナを知ってよいのは composition root だけ**。usecase が
コンテナから依存を引きに行く(サービスロケータ)のは、注入ではない。

```python
# NG: サービスロケータ。依存がシグネチャに現れず、テストで差し替えにくい
class CancelOrder:
    def execute(self, ...):
        orders = container.resolve(OrderRepository)
```
