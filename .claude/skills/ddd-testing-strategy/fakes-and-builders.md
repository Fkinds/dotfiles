# テストデータビルダーと in-memory フェイク

[ddd-testing-strategy](SKILL.md) 第 3・4 節の実装例。ビルダーの書き方と、
フェイクリポジトリを差し込んだユースケースのテスト。

## テストデータビルダー

テストが気にする値だけを渡し、残りは妥当な既定値で埋める。

```python
# tests/builders.py
def an_order(
    *,
    status: OrderStatus = OrderStatus.PENDING,
    lines: tuple[OrderLine, ...] | None = None,
    customer_id: CustomerId | None = None,
) -> Order:
    """テストに関係ある値だけを渡す。残りは妥当な既定値。"""
    return Order(
        status=status,
        lines=lines if lines is not None else (an_order_line(),),
        customer_id=customer_id or CustomerId(value=uuid.uuid4()),
    )
```

## in-memory フェイクと、それを使ったユースケースのテスト

フェイクは抽象(`OrderRepository`)を実装する。抽象を変えればフェイクも壊れるので、
実装との乖離が起きない。

```python
class InMemoryOrderRepository(OrderRepository):
    def __init__(self, initial: list[Order] | None = None) -> None:
        self._store = {o.id: o for o in (initial or [])}

    def find_by_id(self, order_id: OrderId) -> Order | None:
        return self._store.get(order_id)

    def save(self, order: Order) -> None:
        self._store[order.id] = order


class TestCancelOrder:
    def test_取り消すと状態が保存されイベントが発行される(self) -> None:
        order = an_order(status=OrderStatus.PENDING)
        orders = InMemoryOrderRepository([order])
        bus = RecordingEventBus()

        result = CancelOrder(orders, bus).execute(
            CancelOrderCommand(order_id=str(order.id), reason="顧客都合")
        )

        assert result.status == "cancelled"
        assert orders.find_by_id(order.id).status is OrderStatus.CANCELLED
        assert [type(e) for e in bus.published] == [OrderCancelled]
```
