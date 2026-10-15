# トランザクションの port

[SKILL.md](SKILL.md) 第 3 節の詳細。トランザクションの境界を port にすると決めたときに読む。
port が持つのは**境界と `on_commit` だけ**で、リポジトリは持たない(理由は SKILL.md 第 3 節)。

---

## 1. port — usecase の層に置く

```python
# usecases/ports.py
from collections.abc import Callable
from contextlib import AbstractContextManager
from typing import Protocol


class Transaction(Protocol):
    def atomic(self) -> AbstractContextManager[None]:
        """業務処理 1 回分の境界。入れ子にしない。"""
        ...

    def on_commit(self, callback: Callable[[], None]) -> None:
        """確定したら実行する。確定しなければ実行しない。"""
        ...
```

- **usecase の層に置く。** ドメイン層はトランザクションを知らない
  ([ddd-application-layer](../ddd-application-layer/SKILL.md) 第 3 節)。
- port にしたら、usecase の層の禁止 import に `django` を足せる
  ([layer-enforcement.md](../ddd-application-layer/layer-enforcement.md))。
- 名前は既存のコードに合わせる。ddd-domain-events などの例にある
  `transaction_manager()` も同じ役割の port を指す。

---

## 2. Django の実装 — インフラ層に置く

```python
# infrastructure/transaction.py
from django.db import transaction


class DjangoTransaction:
    def __init__(self, using: str | None = None) -> None:
        self._using = using

    def atomic(self) -> AbstractContextManager[None]:
        return transaction.atomic(using=self._using, durable=True)

    def on_commit(self, callback: Callable[[], None]) -> None:
        transaction.on_commit(callback, using=self._using, robust=True)
```

- **`durable=True`** で入れ子を実行時に見つける(SKILL.md 第 3 節)。
- **`robust=True`**(Django 4.2 以降)を付ける。付けないと、確定後のコールバックが例外を
  出したとき、その例外が `atomic` を抜けるところから usecase の呼び出し元まで届く。
  DB は確定済みなのに失敗の応答が返り、クライアントが再送すると二重に処理される。
  残りのコールバックも実行されない。`robust=True` ならログに出して続ける。
- コールバックで失ってはいけない処理(外部への配送)をしない。確定とコールバックの間で
  プロセスが止まれば失われる。失えないものは outbox
  ([ddd-domain-events](../ddd-domain-events/SKILL.md) 第 5 節)。

### usecase と composition root

```python
class ConfirmOrder:
    def __init__(self, orders: OrderRepository, tx: Transaction, bus: EventBus) -> None:
        self._orders = orders
        self._tx = tx
        self._bus = bus

    def execute(self, command: ConfirmOrderCommand) -> ConfirmOrderOutput:
        with self._tx.atomic():
            order = self._orders.find_by_id(OrderId(command.order_id))
            if order is None:
                raise OrderNotFound(command.order_id)
            confirmed, events = order.confirm(now=command.requested_at).pull_events()
            self._orders.save(confirmed)
            for event in events:
                self._tx.on_commit(partial(self._bus.publish, event))
        return ConfirmOrderOutput.from_domain(confirmed)


# infrastructure/factories.py
def build_confirm_order() -> ConfirmOrder:
    return ConfirmOrder(DjangoOrderRepository(), DjangoTransaction(), DjangoEventBus())
```

- コールバックに `lambda: self._bus.publish(event)` と書くと、ループの最後の `event` が
  全部のコールバックに渡る。`partial` か、既定引数で値を固定する。

---

## 3. テスト用のフェイク

```python
# tests/fakes.py
from contextlib import contextmanager


class FakeTransaction:
    def __init__(self) -> None:
        self.commits = 0
        self.rollbacks = 0
        self._pending: list[Callable[[], None]] = []
        self._active = False

    @contextmanager
    def atomic(self) -> Iterator[None]:
        if self._active:
            raise RuntimeError("トランザクションが入れ子になっている")   # durable=True と同じ
        self._active = True
        try:
            yield
        except BaseException:
            self.rollbacks += 1
            self._pending.clear()
            raise
        else:
            self.commits += 1
            callbacks, self._pending = self._pending, []
            for callback in callbacks:
                callback()
        finally:
            self._active = False

    def on_commit(self, callback: Callable[[], None]) -> None:
        if not self._active:
            callback()   # Django もトランザクションの外では即時に実行する
            return
        self._pending.append(callback)
```

```python
class TestConfirmOrder:
    def test_確定したら_確定後にイベントを配る(self) -> None:
        tx, bus = FakeTransaction(), RecordingEventBus()
        orders = InMemoryOrderRepository([an_order(status=OrderStatus.PENDING)])

        ConfirmOrder(orders, tx, bus).execute(a_confirm_command())

        assert tx.commits == 1
        assert [type(e) for e in bus.published] == [OrderConfirmed]

    def test_確定できない注文なら_確定もせず配りもしない(self) -> None:
        tx, bus = FakeTransaction(), RecordingEventBus()
        orders = InMemoryOrderRepository([an_order(status=OrderStatus.CANCELLED)])

        with pytest.raises(OrderNotConfirmable):
            ConfirmOrder(orders, tx, bus).execute(a_confirm_command())

        assert tx.commits == 0
        assert bus.published == []
```

- **in-memory のリポジトリは巻き戻らない。** `save()` のあとで例外が出ても、フェイクには
  保存した状態が残る。失敗時に何も残らないことは `commits == 0` で確かめ、DB が実際に
  巻き戻ることは実 DB のテストに任せる
  ([ddd-testing-strategy](../ddd-testing-strategy/SKILL.md))。
- 実 DB のテストで `on_commit` を確かめるときは `captureOnCommitCallbacks` を使う
  ([ddd-django-pitfalls](../ddd-django-pitfalls/SKILL.md) 第 4 節)。`TestCase` は
  各テストをトランザクションで包んで確定しないので、そのままではコールバックが走らない。
- フェイクとビルダー(`an_order` など)の置き場所は ddd-testing-strategy の
  fakes-and-builders.md に合わせる。
