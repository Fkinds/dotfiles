# Data Mapper の対応づけ — 実装例

[SKILL.md](SKILL.md) 第 5 節の表の実装例。リポジトリ実装を書くときに読む。
`Money` / `Currency` は [ddd-modeling-primitives](../ddd-modeling-primitives/SKILL.md)、
状態ごとの型は [ddd-state-transition](../ddd-state-transition/SKILL.md) の定義を前提にする。

---

## 1. 値オブジェクトを列に展開する

列名は `<属性名>_<要素名>` にそろえる。どの列がどの値オブジェクトに属するかが名前で分かる。

```python
# infrastructure/models.py
class OrderModel(models.Model):
    total_amount = models.DecimalField(max_digits=12, decimal_places=2)
    total_currency = models.CharField(max_length=3)
    # 任意の値オブジェクト: 構成列はすべて NULL 許容
    gift_postal_code = models.CharField(max_length=8, null=True)
    gift_address_line = models.CharField(max_length=200, null=True)
```

```python
# infrastructure/repositories/django_order_repository.py
def _to_domain(row: OrderModel) -> Order:
    return Order(
        id=OrderId(value=row.pk),
        total=Money(amount=row.total_amount, currency=Currency[row.total_currency]),
        gift_address=_address_or_none(row.gift_postal_code, row.gift_address_line),
    )


def _address_or_none(postal_code: str | None, line: str | None) -> Address | None:
    if postal_code is None and line is None:
        return None
    if postal_code is None or line is None:
        # 一部だけ NULL は、どの書き込み経路からも作られないはずの行。黙って補わない
        raise ValueError(f"住所の列が一部だけ NULL: {postal_code!r}, {line!r}")
    return Address(postal_code=PostalCode(value=postal_code), line=line)


def _apply(order: Order, row: OrderModel) -> None:
    row.total_amount = order.total.amount
    row.total_currency = order.total.currency.code
    row.gift_postal_code = order.gift_address.postal_code.value if order.gift_address else None
    row.gift_address_line = order.gift_address.line if order.gift_address else None
```

「全部 NULL か、全部埋まっているか」は DB の制約でも守れる。

```python
class Meta:
    constraints = [
        models.CheckConstraint(
            condition=Q(gift_postal_code__isnull=True, gift_address_line__isnull=True)
            | Q(gift_postal_code__isnull=False, gift_address_line__isnull=False),
            name="order_gift_address_all_or_nothing",
        ),
    ]
```

`condition=` は Django 5.1 以降の引数名。それより前は `check=`。

---

## 2. JSON 列に入れる

選ぶ条件: **中身で検索・集計しない**、**丸ごと読み書きする**、**形が変わりやすい**。
例: 通知の受け取り設定、画面の表示設定。

中身の形を変えても migration には現れないので、**形のバージョンを JSON の中に持たせ、
復元側で古い形を読み替える。**

```python
def _prefs_to_json(prefs: NotificationPreferences) -> dict:
    return {"v": 2, "channels": [c.value for c in prefs.channels], "quiet_hours": prefs.quiet_hours.to_str()}


def _prefs_from_json(raw: dict) -> NotificationPreferences:
    match raw.get("v", 1):
        case 1:
            # v1 はメールの on/off だけを持っていた
            channels = {Channel.EMAIL} if raw["email"] else set()
            return NotificationPreferences(channels=frozenset(channels), quiet_hours=QuietHours.none())
        case 2:
            return NotificationPreferences(
                channels=frozenset(Channel(c) for c in raw["channels"]),
                quiet_hours=QuietHours.parse(raw["quiet_hours"]),
            )
        case unknown:
            raise ValueError(f"未知の形のバージョン: {unknown!r}")
```

- 書き込みは常に最新の形。古い形は読むときだけ受け入れる。
- 中身で絞り込みたくなったら、その要素は列に出す時期。

---

## 3. 子の集まりを保存する

### 全部消して入れ直す(既定)

子の行が外から参照されないなら、これが最も単純で、差分の取り違えも起きない。

```python
def save(self, order: Order) -> None:
    with transaction.atomic():
        row, _ = OrderModel.objects.update_or_create(pk=order.id.value, defaults=_row_fields(order))
        OrderLineModel.objects.filter(order_id=row.pk).delete()
        OrderLineModel.objects.bulk_create(
            [OrderLineModel(order_id=row.pk, line_no=line.line_no, **_line_fields(line)) for line in order.lines]
        )
```

### 差分で更新する

次のどれかに当たるときに選ぶ。

- 子の行が外から参照される(出荷明細が注文明細の行を指している)
- 件数が多く、毎回の全置換が重い
- 子の行の作成日時など、行そのものの履歴を残したい

```python
def _save_lines(self, order_pk: int, lines: tuple[OrderLine, ...]) -> None:
    keep = [line.line_no for line in lines]
    OrderLineModel.objects.filter(order_id=order_pk).exclude(line_no__in=keep).delete()
    for line in lines:
        OrderLineModel.objects.update_or_create(
            order_id=order_pk, line_no=line.line_no, defaults=_line_fields(line)
        )
```

- 子の同一性は**親の中で一意なキー**(`line_no`)で取る。DB の自動採番の ID を
  ドメインに持ち込まない。
- `(order_id, line_no)` に一意制約を付ける。

---

## 4. 状態ごとの型を 1 テーブルに対応づける

ドメインでは状態ごとに型が分かれていても、テーブルは 1 つにして状態の列で区別する。
状態ごとの列は NULL 許容にし、**どの状態でどの列が埋まるか**を DB の制約で守る。

```python
class ApplicationModel(models.Model):
    status = models.CharField(max_length=20, choices=[(s.value, s.name) for s in ApplicationStatus])
    body = models.TextField()
    submitted_at = models.DateTimeField(null=True)
    approved_at = models.DateTimeField(null=True)
    approved_by_id = models.UUIDField(null=True)
    rejected_at = models.DateTimeField(null=True)
    rejection_reason = models.TextField(null=True)

    class Meta:
        constraints = [
            models.CheckConstraint(
                condition=~Q(status="approved") | Q(approved_at__isnull=False, approved_by_id__isnull=False),
                name="application_approved_has_approval",
            ),
            models.CheckConstraint(
                condition=~Q(status="rejected") | Q(rejected_at__isnull=False, rejection_reason__isnull=False),
                name="application_rejected_has_reason",
            ),
        ]
```

```python
def _state_from(row: ApplicationModel) -> ApplicationState:
    match ApplicationStatus(row.status):
        case ApplicationStatus.DRAFT:
            return Draft()
        case ApplicationStatus.SUBMITTED:
            return Submitted(submitted_at=row.submitted_at)
        case ApplicationStatus.APPROVED:
            return Approved(approved_at=row.approved_at, approved_by=UserId(value=row.approved_by_id))
        case ApplicationStatus.REJECTED:
            return Rejected(rejected_at=row.rejected_at, reason=RejectionReason(value=row.rejection_reason))
```

- `match` を網羅的に書くと、状態を足したときに変換の漏れが型検査で見つかる。
- 状態を変えるときは、前の状態の列を消すかどうかを決めて書く。承認後に却下へ
  戻せないなら、`approved_at` が残っていても害はないが、残すと決めたことを書いておく。

### 型ごとのテーブルにするとき

型ごとの列がほとんど重ならず、型をまたいだ一覧も要らないなら、型ごとにテーブルを分ける。
共通の列は抽象基底(`abstract = True`)で共有する。型をまたいだ一覧が要るなら
`UNION` になるので、1 テーブルに戻すか、一覧用の読み取りモデルを作る
([ddd-read-model-cqrs](../ddd-read-model-cqrs/SKILL.md))。
