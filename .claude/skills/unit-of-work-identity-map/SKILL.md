---
name: unit-of-work-identity-map
description: 1 回の業務処理の中で、読んだオブジェクトと書き込みをどう管理するかを決める。Django ORM には Unit of Work(処理中の変更を覚えてまとめて書く仕組み)も Identity Map(同じ行を 1 つのオブジェクトに保つ仕組み)も無く、その穴を設計で塞ぐ。UnitOfWork クラスやトランザクションの抽象を作るか迷ったとき、同時に操作した人がいないのに楽観ロックの競合が出るとき、save() が別の変更を消したとき、同じレコードを何度も取得しているとき、並び順の入れ替えで一意制約に当たるときに使う。
---

# Unit of Work と Identity Map — Django に無い 2 つの仕組み

- **Unit of Work**: 1 回の業務処理で作った・変えた・消したオブジェクトを覚えておき、
  最後にまとめて、正しい順序で DB に書く。
- **Identity Map**: 1 回の業務処理の中では、同じ行を表すオブジェクトを 1 つに保つ。
  2 度目の読み込みは、最初に作ったオブジェクトを返す。

Django ORM はどちらも持たない。`save()` は呼んだ瞬間に SQL を出し、`get()` は呼ぶたびに
別のインスタンスを返す(SQLAlchemy の `Session` は両方を持つ)。このスキルは、その穴を
**作り込まずに設計で塞ぐ**方針と、塞ぎきれないところの補い方を扱う。

出典は Martin Fowler『Patterns of Enterprise Application Architecture』の
Unit of Work と Identity Map。各パターンの要約は
[著者のカタログ](https://martinfowler.com/eaaCatalog/)にある。

関連スキル:

- トランザクションの境界は usecase → [ddd-application-layer](../ddd-application-layer/SKILL.md) 第 3 節
- 1 トランザクション 1 集約、楽観ロック → [ddd-aggregate-repository-boundary](../ddd-aggregate-repository-boundary/SKILL.md)
- 確定後のイベント配送 → [ddd-domain-events](../ddd-domain-events/SKILL.md)
- `atomic` の入れ子、`on_commit` のテスト → [ddd-django-pitfalls](../ddd-django-pitfalls/SKILL.md) 第 4 節
- 画面を開いてから保存するまでの競合 → [edit-conflict-control](../edit-conflict-control/SKILL.md)

---

## 1. 無いと何が起きるか

| 仕組み | 役割 | Django ORM | 無いと起きること |
| --- | --- | --- | --- |
| Unit of Work | 変更を覚え、最後にまとめて書く | 無い。`save()` / `delete()` がその場で SQL を出す | 保存し忘れ。全列を書いて他の変更を消す。書く順序で制約に当たる |
| Identity Map | 同じ行を 1 つのオブジェクトに保つ | 無い。`get()` のたびに別のインスタンス | 同じ行の 2 つのコピーが互いの変更を消す。同じ行を何度も読む |

**`transaction.atomic()` は Unit of Work ではない。** 「全部書くか、何も書かないか」を
保証するだけで、何を書くべきかは覚えていない。`save()` を呼ばなかった変更は、
`atomic` の中でも書かれない。

---

## 2. 既定 — 設計で要らなくする

frozen dataclass の集約を usecase が読み書きし、1 トランザクションで 1 集約だけを変える
形なら、2 つとも**作らずに済む**。

| PoEAA の仕組み | 代わりになるもの |
| --- | --- |
| Identity Map | usecase の**ローカル変数**。集約は usecase が 1 回だけ読み、以後はその変数を渡す |
| Unit of Work | usecase の `atomic` ブロックと、最後に呼ぶ `save()` |
| 書く順序の管理 | 書く集約が 1 つなので、順序の問題が集約の中に閉じる |

**frozen な集約では、変更を自動で追う Unit of Work は働かない。** 振る舞いは新しい
オブジェクトを返すので、読んだインスタンスを見張っていても変化は見えない。新しいほうを
Unit of Work に渡す必要があり、それは `save()` を呼ぶことと変わらない。SQLAlchemy の
`Session` をまねて「読んだものを最後に自動で書く」仕組みを作らない。

この既定が成り立つ条件:

- [ ] usecase が読んだ集約を、helper・ポリシー・ドメインサービスが id から**読み直さない**。
      オブジェクトを受け取り、新しいオブジェクトを返す
- [ ] 1 つの usecase で、同じ集約を 2 度 `find` しない
- [ ] 振る舞いの戻り値を受け取り、それを `save()` している(捨てると変更が消える)
- [ ] 1 トランザクションで変える集約は 1 つ(例外は ddd-aggregate-repository-boundary 第 4 節の 3 だけ)

崩れていたら、仕組みを足す前にこちらを直す。保存し忘れは、`save()` されたものだけを
覚える in-memory フェイクで usecase をテストすれば見つかる
([ddd-testing-strategy](../ddd-testing-strategy/SKILL.md) 第 4 節)。

---

## 3. トランザクションを抽象にするか

| 段階 | 形 | 選ぶ条件 |
| --- | --- | --- |
| **既定** | usecase に `transaction.atomic(durable=True)` を直接書く | 下の条件に当たらない |
| port にする | トランザクションの境界と `on_commit` だけを port にして注入する | usecase の層から `django` を締め出したい / usecase のテストで「確定した・しなかった」を DB なしで確かめたい |
| **作らない** | リポジトリを束ね、読んだ集約を覚えて最後に自動で書く Unit of Work | 第 2 節のとおり frozen な集約では働かない。リポジトリを束ねる理由も Django には無い(下) |

**Django では、リポジトリを Unit of Work に持たせる理由がない。** DB 接続はスレッドごとに
1 つで、リポジトリが ORM を呼べば、今開いている `atomic` に自動で参加する。SQLAlchemy の
例で Unit of Work がリポジトリを持つのは同じ `Session` を共有させるためで、Django には
その必要がない。例外は DB を複数使うとき(`using=`)で、別名の DB は別のトランザクションに
なり、両方を同時に確定する保証はない。

**境界の `atomic` には `durable=True` を付ける。** 外側に別の `atomic` があると
`RuntimeError` になるので、`ATOMIC_REQUESTS = True` や、usecase の中から別の usecase を
呼ぶ入れ子を実行時に見つけられる。Django の `TestCase` が各テストに張る外側の
トランザクションは例外として扱われるので、テストは壊れない。

コミット前に同期で配るイベントのハンドラ([ddd-domain-events](../ddd-domain-events/SKILL.md)
第 5 節)は、発行した usecase のトランザクションの中で動く。ハンドラから `durable=True` の
usecase を呼ぶと `RuntimeError` になるので、ハンドラは自分でトランザクションを開かない
処理として書く。

port にすると決めたら、port・Django の実装・テスト用のフェイクの書き方は
[transaction-port.md](transaction-port.md) を読む。

---

## 4. 同じ集約を 2 度読まない — Identity Map の代わり

| 症状 | 原因 |
| --- | --- |
| 同時に操作した人がいないのに、楽観ロックの競合(`ConcurrentModification`)が出る | 同じ処理の中で同じ集約を 2 回読み、両方を保存した。後の保存が古い版で書こうとした |
| 保存したはずの変更が、同じリクエストの中で消える(版を持たない表) | 2 つのコピーのうち、古いほうが後から書いた |
| 同じ SELECT がループの回数だけ出る | 参照先を 1 件ずつ読んでいる |

```python
# NG: helper が id から読み直す。order と helper の中で読んだものは別のコピー
with transaction.atomic(durable=True):
    order = self._orders.find_by_id(order_id)          # 版 3
    self._apply_coupon(order_id, coupon)                # 中で版 3 を読み、保存して版 4 にする
    confirmed = order.confirm(now=now)                  # 版 3 から作った
    self._orders.save(confirmed)                        # 版 3 で書こうとして競合する

# OK: オブジェクトを渡し、新しいオブジェクトを受け取る
with transaction.atomic(durable=True):
    order = self._orders.find_by_id(order_id)
    discounted = order.apply_coupon(coupon)
    confirmed = discounted.confirm(now=now)
    self._orders.save(confirmed)
```

**複数の参照先は、まとめて読んで辞書にする。** その辞書が、この処理だけの Identity Map
になる。

```python
# NG: 明細ごとに読む。同じ商品が 2 行にあれば 2 回読む
for line in cart.lines:
    product = self._products.find_by_id(line.product_id)

# OK: 1 回で読み、辞書で引く
products = self._products.find_by_ids({line.product_id for line in cart.lines})
missing = {line.product_id for line in cart.lines} - products.keys()
if missing:
    raise ProductNotFound(missing)
```

- リポジトリの実装は `ProductModel.objects.in_bulk(ids)` で `{pk: 行}` を取り、
  ドメインオブジェクトの辞書に変換して返す。見つからない id は辞書に入らないので、
  呼び出し側で確かめる。
- 一覧画面のために集約を N 件読むのは別の問題 →
  [ddd-read-model-cqrs](../ddd-read-model-cqrs/SKILL.md)。

**リポジトリにキャッシュを持たせない。** 持たせると、保存のたびにキャッシュの版も進める
必要が出て、ローカル変数で足りる問題に見合わない。どうしても持たせるなら寿命を 1 回の
usecase に限る(composition root がリクエストごとに作る)。プロセスで共有すると、別の
リクエストや別のスレッドに古い集約を返す。

---

## 5. Django のモデルを直接使うコード

Transaction Script や軽量の Domain Model
([domain-logic-patterns](../domain-logic-patterns/SKILL.md) 第 4 節)では、Django の
モデルインスタンスがそのまま業務のオブジェクトになる。ここでは 2 つの穴がそのまま事故になる。

```python
def close_month(member_id: int, today: date) -> None:
    member = Member.objects.get(pk=member_id)
    grant_monthly_bonus(member_id)      # 中で Member を get し、points を増やして save()
    member.last_closed_on = today
    member.save()                       # 古い points を含む全列を書く → ボーナスが消える
```

| 対策 | 書き方 | 防げるもの |
| --- | --- | --- |
| インスタンスを渡す | `grant_monthly_bonus(member)` | 同じ処理の中の 2 つのコピー |
| 書く列を絞る | `member.save(update_fields=["last_closed_on"])` | 他の処理(別のリクエストを含む)が書いた列を古い値で戻す |
| 加算は DB でやる | `Member.objects.filter(pk=member_id).update(points=F("points") + 100)` | 読んでから足すまでの割り込み |
| 書いたあと読み直す | `member.refresh_from_db(fields=["points"])` | 他の関数が書いたかもしれない値を、このあと使う |

- **`save()` は既定で全列を書く。** 例外は `only()` / `defer()` で読んだインスタンスで、
  読んだ列だけを書く。
- `F()` を属性に代入して `save()` したあと、その属性は式のまま残る。値として使う前に
  `refresh_from_db()` する。
- `select_for_update()` は他のトランザクションを待たせるだけで、同じ処理の中の 2 つの
  コピーを 1 つにはしない。
- `order.customer` はインスタンスごとにキャッシュされる。
  `Customer.objects.get(pk=order.customer_id)` で取ったものは別のコピー。

---

## 6. 書く順序と制約

Django は `save()` / `update()` / `delete()` の時点で SQL を出す。制約は、遅延させたもの
を除いてその文の時点で検査される。**書く順序は自分で決める。**

| 制約 | 検査される時点(Django が作る既定) | 気をつけること |
| --- | --- | --- |
| 外部キー | PostgreSQL・SQLite・Oracle は**確定時**(`DEFERRABLE INITIALLY DEFERRED` で作られる)。MySQL は**その文の時点** | MySQL では親を先に作り、子を先に消す。PostgreSQL では違反が `save()` ではなく確定時に出る |
| 一意制約 | **その文の時点**。PostgreSQL・Oracle なら `UniqueConstraint(deferrable=Deferrable.DEFERRED)` で確定時にできる | 値を入れ替えると途中の文が当たる(下) |

**値を入れ替えると、一意制約に途中で当たる。** 見積の明細の並び順(`position` に
一意制約)を入れ替えると、1 行目を 2 にした時点で、まだ 2 の行が残っている。

| 直し方 | 向いているとき |
| --- | --- |
| 子を消して入れ直す(全置換) | 子が少ない。保存を全置換にしているなら既にこれ([data-source-patterns](../data-source-patterns/SKILL.md) の mapping.md 第 3 節) |
| 一意制約を遅延させる | PostgreSQL で、差分で書きたい。`condition` / `include` 付きの制約は遅延にできない |
| 一度ずらしてから戻す(全行を負の値へ → 本来の値へ) | MySQL のように遅延制約が無い DB |

- **違反を捕まえて分岐する一意制約は遅延させない。** 違反が `save()` ではなく確定時に
  出るので、savepoint で捕まえる書き方(edit-conflict-control の
  [edit-lock.md](../edit-conflict-control/edit-lock.md) 第 2 節)が働かなくなる。
- 遅延させた制約の違反は、`atomic` を抜けるところで `IntegrityError` になる。usecase の
  中で業務の例外に変えられないので、遅延させた制約に当たるのは**コードの誤り**だけにする。

---

## アンチパターン

| アンチパターン | 何が起きるか |
| --- | --- |
| SQLAlchemy の `Session` をまねて、読んだ集約を自動で書く Unit of Work を自作する | frozen な集約の変化を追えず、結局 `save()` を呼ぶ。暗黙の書き込みが増えて追えなくなる |
| helper やポリシーが、usecase の読んだ集約を id から読み直す | 同じ集約のコピーが 2 つでき、自分自身と競合する |
| 明細ごとに参照先を 1 件ずつ読む | 同じ行を何度も読み、クエリが行の数だけ出る |
| リポジトリにプロセス共有のキャッシュを持たせる | 別のリクエストに古い集約を返す |
| Django モデルを `update_fields` なしで `save()` する | 他の処理が書いた列を古い値で戻す |
| 境界の `atomic` に `durable=True` を付けない | 入れ子になっても気付かず、内側で確定したつもりの変更が外側の失敗で巻き戻る |
| 捕まえて分岐する一意制約を遅延させる | 違反が確定時まで出ず、分岐が働かない |

---

## ルール(チェックリスト)

- [ ] 集約は usecase が 1 回だけ読み、以後はオブジェクトを渡している
- [ ] 同時に操作した人がいない競合を見たら、同じ処理での 2 度読みを最初に疑う
- [ ] 複数の参照先は `find_by_ids` でまとめて読み、足りない id を確かめている
- [ ] Unit of Work を自作していない。抽象にするのはトランザクションの境界と `on_commit` だけ
- [ ] 境界の `atomic` は `durable=True`
- [ ] リポジトリにキャッシュを持たせていない。持たせるなら寿命は 1 回の usecase
- [ ] Django のモデルを直接使うコードは、インスタンスを渡し、`update_fields` / `F()` で書いている
- [ ] 値を入れ替える一意制約は、全置換・遅延制約・二段階のどれで避けるか決めた
- [ ] 捕まえて分岐する一意制約は遅延させていない
