# composition root の組み立て

[ddd-application-layer](SKILL.md) 第 5 節の詳細。具象を組み立てる場所の実装、
`apps.py` の `ready()` を使う条件、依存のスコープ、DI コンテナを入れるかの判断。

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
