---
name: ddd-django-pitfalls
description: Django で DDD をやるときに層を壊す固有の落とし穴。Django プロジェクトで DDD を実践するとき、モデルやシグナルにロジックが漏れているとき、トランザクションやバリデーションの挙動で悩むときに使う。扱う範囲は signals を使わない理由、save() のオーバーライド禁止、Manager/QuerySet にビジネスロジックを置かない、transaction.atomic のネストと on_commit の挙動、Django の validation とドメインの不変条件の二重化、遅延読み込みと集約の関係、migration とドメインのずれ、settings/ORM への依存の締め出し。
---

# DDD: Django 固有の落とし穴 (Django Pitfalls)

Django は**アクティブレコードとフレームワーク結合を前提**に作られている。DDD は
その逆(ドメインを何にも依存させない)を目指すので、放っておくと層が溶ける。
ここは「Django のどの機能が層を壊すか」と、その回避を扱う。

層の設計は
[ddd-application-layer](../ddd-application-layer/SKILL.md)、
永続化との分離は
[ddd-aggregate-repository-boundary](../ddd-aggregate-repository-boundary/SKILL.md)、
読み取りは
[ddd-read-model-cqrs](../ddd-read-model-cqrs/SKILL.md)。

---

## 1. signals を使わない

`post_save` / `pre_delete` などのシグナルは、**DDD では原則禁止**。

- **暗黙の副作用。** usecase を読んでも何が起きるか分からない。保存した瞬間に
  どこか別のファイルの処理が走る。
- **トランザクション境界が見えない。** `post_save` は commit 前に走る。
  まだ確定していない変更を前提に通知やメール送信をしてしまう。
- **順序が保証されない。** 複数のレシーバの実行順は登録順に依存する。
- **テストが壊れる。** フィクスチャ作成のたびに副作用が走る。

**代わりにドメインイベントを使う**([ddd-domain-events](../ddd-domain-events/SKILL.md))。
集約が「何が起きたか」を明示的に記録し、usecase が**コミット後に**ディスパッチする。

```python
# NG: 保存に反応する暗黙の副作用
@receiver(post_save, sender=OrderModel)
def notify(sender, instance, **kwargs):
    send_mail(...)          # ← まだコミットされていない

# OK: ドメインが事実を記録し、usecase が確定後に配る
cancelled = order.cancel()
drained, events = cancelled.pull_events()
self._orders.save(drained)
for e in events:
    transaction.on_commit(lambda e=e: self._bus.publish(e))
```

> 例外: 検索インデックス更新やキャッシュ破棄など、**ドメインと無関係な純粋な
> インフラ処理**に限れば許容できる。その場合も `transaction.on_commit` の中で行う。

---

## 2. `save()` をオーバーライドしない

```python
# NG: 保存にドメインロジックが紛れ込む
class OrderModel(models.Model):
    def save(self, *args, **kwargs):
        if self.status == "shipped":
            self.shipped_at = timezone.now()   # ← ドメインの判断
        super().save(*args, **kwargs)
```

- 永続化モデルは**テーブルの形**であって、不変条件の守り手ではない。
- `bulk_create` / `update()` / `QuerySet.update` は `save()` を**呼ばない**。
  ここに置いたルールは黙って飛ばされる。
- どの経路で保存されたかによって振る舞いが変わり、再現しないバグになる。

ロジックはドメインオブジェクトへ。モデルの `save()` は素のままにする。

---

## 3. Manager / QuerySet にビジネスロジックを置かない

```python
# NG: 業務ルールが ORM 層に居る
class OrderQuerySet(models.QuerySet):
    def cancellable(self):
        return self.exclude(status="shipped")   # ← 「取り消せる条件」はドメイン
```

「取り消せる注文とは何か」は**ドメインの知識**。ここに置くと:

- ドメイン層とクエリ層に**同じルールが二重化**する。必ずズレる。
- ルールが SQL の形に縛られ、変更しにくくなる。

**書き込み側**: 条件判定は集約のメソッド(`order.can_cancel()`)。
**読み取り側**: 一覧の絞り込みは query service に置く
([ddd-read-model-cqrs](../ddd-read-model-cqrs/SKILL.md))。QuerySet の
カスタムメソッドは query service 実装の**内側**に閉じる分には構わない。

---

## 4. トランザクションの落とし穴

### `atomic` のネストはロールバックしない

```python
with transaction.atomic():          # 外側
    ...
    with transaction.atomic():      # 内側 = SAVEPOINT
        ...
```

内側の `atomic` は独立したトランザクションではなく **SAVEPOINT**。内側で例外を
握り潰すと、外側はコミットされる。**usecase が複数の `atomic` に囲まれていないか**を
確認する。境界は usecase の1か所だけ
([ddd-application-layer](../ddd-application-layer/SKILL.md))。

### `ATOMIC_REQUESTS` はトランザクション境界を奪う

`ATOMIC_REQUESTS = True` にすると、**リクエスト全体**が1トランザクションになる。
usecase が境界を持てず、「1トランザクション = 1集約」が成立しない。DDD で
やるなら **False**(既定)にして、usecase で明示的に張る。

### `on_commit` はテストで走らない

`TestCase`(トランザクションをロールバックする)では `on_commit` のコールバックが
**実行されない**。イベントのディスパッチをテストしたいなら
`django.test.testcases.TestCase.captureOnCommitCallbacks` を使うか、
usecase のテストではフェイクの EventBus で検証する
([ddd-testing-strategy](../ddd-testing-strategy/SKILL.md))。

---

## 5. Django の validation とドメインの不変条件を二重化しない

Django には `full_clean()` / `validators` / フォームバリデーションがある。
ドメインにも `__post_init__` がある。**両方に同じルールを書くと必ずズレる。**

| 種類 | どこで | 何を守るか |
| --- | --- | --- |
| **ドメインの不変条件** | `__post_init__`(ドメイン層) | **業務ルール**。唯一の正 |
| DB 制約(`unique`, `NOT NULL`, FK) | migration | 最後の砦。データ破損を防ぐ |
| 入力バリデーション | serializer / form | **形式**(型・必須・長さ)だけ |

- **業務ルールを serializer に書かない。** 「出荷済みなら取り消せない」は
  serializer の仕事ではない。
- serializer は**形式**だけを見て、値オブジェクトへの変換で業務ルールが効くようにする。
- `full_clean()` をドメインの代わりに使わない。永続化モデルの検証であって、
  ドメインオブジェクトの検証ではない。

---

## 6. 遅延読み込みが層を貫通する

```python
# ドメイン層のつもりのコードが、実は SQL を発行している
if order.customer.is_premium:   # ← ここで SELECT が走る
```

- 集約は**境界の全体を一度に読む**。`select_related` / `prefetch_related` を
  リポジトリ実装の中で使い切る。
- ドメインオブジェクトに **Django のモデルインスタンスを持たせない。**
  持たせた瞬間、属性アクセスがクエリになる。
- 他の集約は **id で参照**する。オブジェクトを埋め込まない
  ([ddd-aggregate-repository-boundary](../ddd-aggregate-repository-boundary/SKILL.md))。

**検出**: テストで `assertNumQueries` を使うか、ドメイン層のテストを
`django_db` なしで走らせる。DB マークが要るなら、そこは層が壊れている。

---

## 7. migration とドメインのずれ

- **ドメインの変更が自動で migration にならない。** ドメインオブジェクトと
  Django モデルは別物なので、フィールドを増やしたら両方直す。
  リポジトリの往復テストがこのズレを検出する。
- **データ移行(RunPython)にドメインロジックを書かない。** migration は過去の
  スキーマに対して走る。将来ドメインが変わると、古い migration が動かなくなる。
  移行時点のロジックを migration 内に**べた書き**する。
- **`null=True` と `blank=True` を惰性で付けない。** ドメインが必須と言うなら
  DB も `NOT NULL` にする。DB が緩いと、復元時に不正な集約が生まれる。

---

## 8. ドメイン層から Django を締め出す

ドメイン層(`domain/`)に次があってはいけない。

```python
from django.db import models          # NG
from django.conf import settings      # NG
from django.utils import timezone     # NG — datetime.now(UTC) を引数で受け取る
from django.core.exceptions import ValidationError   # NG — 独自の DomainError を使う
from rest_framework import serializers               # NG
```

**検出は grep でできる。** CI か手元で回す。

```bash
grep -rn "^from django\|^import django\|^from rest_framework" --include="*.py" src/*/domain/ \
  && echo "ドメイン層に Django が漏れている" || echo "OK"
```

- 設定値が要るなら**コンストラクタか引数で渡す**。`settings` を直接読まない。
- 現在時刻は `timezone.now()` ではなく、**引数で受け取る**
  ([ddd-modeling-primitives](../ddd-modeling-primitives/SKILL.md))。
- 例外は `ValueError` / ドメイン固有の例外。HTTP への変換はインターフェース層。

---

## アンチパターン

| アンチパターン | なぜ悪いか |
| --- | --- |
| `post_save` などの signals でドメイン処理 | 暗黙の副作用。commit 前に走る。順序不定 |
| `save()` をオーバーライドしてルールを書く | `bulk_create` / `update()` で飛ばされる |
| QuerySet/Manager に業務ルール | ドメインと二重化し、必ずズレる |
| `ATOMIC_REQUESTS = True` のまま DDD | usecase がトランザクション境界を持てない |
| 内側の `atomic` で例外を握り潰す | SAVEPOINT なので外側はコミットされる |
| `on_commit` の検証を `TestCase` でやる | コールバックが実行されず、通ったように見える |
| 業務ルールを serializer に書く | ドメインの外にルールが出る |
| ドメインオブジェクトがモデルを保持 | 属性アクセスが SQL になり、層が消える |
| migration に現在のドメインロジックを呼ぶ | 将来ドメインが変わると過去の migration が壊れる |
| ドメイン層で `settings` / `timezone.now()` | 隠れた依存。テストも移植もできない |
| 惰性の `null=True` | DB が緩く、復元時に不正な集約が生まれる |

---

## ルール(チェックリスト)

- [ ] **signals をドメイン処理に使っていない**(ドメインイベントに置き換えた)
- [ ] モデルの `save()` を**オーバーライドしていない**
- [ ] QuerySet / Manager に**業務ルールがない**(判定は集約、絞り込みは query service)
- [ ] `ATOMIC_REQUESTS` が **False**。トランザクション境界は usecase の1か所
- [ ] `atomic` のネストで例外を握り潰していない
- [ ] `on_commit` の検証に `captureOnCommitCallbacks` かフェイクを使っている
- [ ] 業務ルールが serializer / `full_clean()` に**二重化していない**
- [ ] ドメインオブジェクトが **Django モデルを保持していない**
- [ ] 集約は `select_related` / `prefetch_related` で**一度に読んでいる**
- [ ] ドメイン層のテストに **`django_db` マークが不要**
- [ ] migration にドメインの呼び出しがない(移行時点のロジックをべた書き)
- [ ] **`grep` でドメイン層に `django` / `rest_framework` の import がない**
- [ ] 現在時刻・設定値を**引数で受け取っている**
