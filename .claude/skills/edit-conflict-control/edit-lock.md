# 編集ロックの実装

[SKILL.md](SKILL.md) 第 6 節の詳細。編集ロック(悲観的オフラインロック)を入れると
決めたときに読む。どの場合でも、保存時の版の確認(SKILL.md 第 3 節)と併用する。

---

## 1. ロック表

ロックは DB の行として記録する。**1 つの資源に 1 行**を一意制約で保証する。

```python
class EditLockModel(models.Model):
    resource_type = models.CharField(max_length=50)   # "reservation" など、集約の種類
    resource_id = models.CharField(max_length=64)     # 集約ルートの ID
    owner_id = models.UUIDField()
    acquired_at = models.DateTimeField()
    expires_at = models.DateTimeField()

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=["resource_type", "resource_id"], name="edit_lock_one_per_resource"),
        ]
```

- ロックは**集約ルートの単位**でかける(SKILL.md 第 4 節)。明細ごとにかけない。
- 業務のテーブルに `locked_by` 列を足す方式は取らない。ロックの都合で集約の版が進み、
  楽観的オフラインロックと干渉する。

---

## 2. 取得する

「誰も持っていなければ作る」を、確認してから作る 2 段階にしない。間に割り込まれる。
**作ってみて、一意制約の違反で「既に持たれている」を知る。**

```python
@dataclass(frozen=True, kw_only=True)
class LockHeld:
    owner_id: UUID
    expires_at: datetime


def acquire(resource_type: str, resource_id: str, owner_id: UUID, now: datetime, ttl: timedelta) -> EditLockModel | LockHeld:
    key = {"resource_type": resource_type, "resource_id": resource_id}
    with transaction.atomic():
        EditLockModel.objects.filter(**key, expires_at__lte=now).delete()   # 期限切れを片付ける
        try:
            with transaction.atomic():   # savepoint。一意制約違反で外側のトランザクションを壊さない
                return EditLockModel.objects.create(**key, owner_id=owner_id, acquired_at=now, expires_at=now + ttl)
        except IntegrityError:
            current = EditLockModel.objects.select_for_update().get(**key)
            if current.owner_id == owner_id:          # 自分のロック(別タブなど)なら延長する
                current.expires_at = now + ttl
                current.save(update_fields=["expires_at"])
                return current
            return LockHeld(owner_id=current.owner_id, expires_at=current.expires_at)
```

- `IntegrityError` の直後に相手が解除すると `get` が `DoesNotExist` になる。その場合は
  取得をもう一度だけ試す。
- `now` は引数で受け取る。テストで期限切れを再現できる。

---

## 3. 延長する

編集画面を開いている間、画面から定期的に延長のリクエストを送る。
**自分のロックで、まだ有効なものだけ**を延ばす。

```python
def renew(resource_type: str, resource_id: str, owner_id: UUID, now: datetime, ttl: timedelta) -> bool:
    updated = EditLockModel.objects.filter(
        resource_type=resource_type, resource_id=resource_id, owner_id=owner_id, expires_at__gt=now,
    ).update(expires_at=now + ttl)
    return updated == 1   # False なら失っている。画面で「編集ロックが外れました」と伝える
```

### 期限の決め方

| 値 | 目安 | 考えること |
| --- | --- | --- |
| 期限(TTL) | 10〜15 分 | 放置されたロックが外れるまで、他の人が待たされる時間 |
| 延長の間隔 | 期限の 1/3〜1/5 | 通信が 1〜2 回失敗しても期限切れにならない間隔 |

- 延長は**画面が表示されている間だけ**送る。タブが裏にあっても送るかは、
  「開きっぱなしで席を外した人のロックを残すか」で決める。
- 画面の操作がない時間が長いなら延長をやめる、という上限を設けると、開きっぱなしの
  ロックが残り続けない。

---

## 4. 保存時に確かめる

保存と同じトランザクションの中で、**ロックが自分のもので有効か**を確かめる。

```python
class UpdateQuotation:
    def execute(self, command: UpdateQuotationCommand) -> QuotationOutput:
        with transaction.atomic():
            if not self._locks.is_held_by(command.quotation_id, command.actor_id, now=self._clock.now()):
                raise EditLockLost(command.quotation_id)   # 期限切れ・強制解除のあと
            quotation = self._quotations.find_by_id(...)
            if quotation.version != command.expected_version:
                raise StaleVersion(current=quotation.version)
            ...
            self._quotations.save(updated)
            self._locks.release(command.quotation_id, command.actor_id)
```

- `is_held_by` は `select_for_update()` で読む。確認から保存までの間に強制解除されない。
- 保存したら解除する。続けて編集させるなら解除せず延長する。

---

## 5. 解除する

| 契機 | 方法 |
| --- | --- |
| 保存した・キャンセルした | 自分のロックを削除する |
| 画面を閉じた | `navigator.sendBeacon` で解除を送る。**届かない前提**で、期限で外れるようにしておく |
| 管理者・記録の責任者が外す | 強制解除。誰が外したかを記録し、外された人に伝える |

- 解除は `owner_id` を条件に含めて削除する。他人のロックを消さない(強制解除を除く)。

---

## 6. Redis に置く場合

`SET key value NX PX <ミリ秒>` で、取得と期限を 1 回の操作で行える。

- **保存のトランザクションと一緒に確かめられない。** 確認してから保存するまでの間に
  期限が切れうる。だから保存時の版の確認(SKILL.md 第 3 節)が唯一の最終防衛線になる。
- 解除は「値が自分のものなら消す」を Lua スクリプトで 1 回の操作にする。GET してから
  DEL すると、その間に他人が取ったロックを消す。
- 誰がロックしているかを一覧で出す要件があるなら、DB のほうが向く。

---

## 7. テスト

- `now` を受け取る作りにして、期限の前後を固定の時刻で検証する。
- 2 人目の取得が `LockHeld` になること、期限切れのロックを 2 人目が取得できること、
  期限切れのあとで 1 人目の保存が `EditLockLost` になることを確かめる。
- 一意制約による取り合いは、実際の DB を使うテストでだけ検証できる
  ([ddd-testing-strategy](../ddd-testing-strategy/SKILL.md))。
