# 同時実行制御 (Concurrency Control)

[ddd-aggregate-repository-boundary](SKILL.md) 第 9 節の詳細。楽観的ロックの実装、
競合時の分岐、悲観的ロックへの切り替え判断、テストの書き方。

集約は整合性境界なので、**競合は集約単位で検出する**。

- **楽観的ロック**を既定にする。集約ルートにバージョンを持たせ、`save` 時に
  「読んだときのバージョンと一致するか」で更新する。不一致なら競合として失敗させる。
- バージョンは**永続化の関心**であってドメインの不変条件ではない。ドメインオブジェクトに
  持たせるか、リポジトリ側で持つかは選択だが、**ドメインの振る舞いがバージョンを
  読み書きしない**ようにする。

## 楽観的ロックの実装

**条件付き UPDATE の更新件数で判定する。** 読んでから比較するのでは、その間に
割り込まれる。

```python
class DjangoOrderRepository(OrderRepository):
    def save(self, order: Order) -> None:
        updated = OrderModel.objects.filter(
            pk=order.id, version=order.version,      # 読んだときのバージョン
        ).update(
            status=order.status.value,
            version=order.version + 1,               # 同じ文で進める
        )
        if updated == 0:
            raise ConcurrentModification(order.id)   # 誰かが先に更新した
```

- **`select` してから `if` で比較しない。** チェックと更新の間に割り込まれる。
  1 文の `UPDATE ... WHERE version = ?` にする。
- **バージョンは集約ルート単位**。子テーブルを更新しても、ルートのバージョンを進める。
  集約が整合性境界なので、競合も集約単位で見る。
- 更新件数 0 は「存在しない」か「競合」の両方を意味する。区別が必要なら
  存在確認を別に行う。

## 競合したらどうするか

**リトライは usecase より外側**。usecase の中で再試行すると、トランザクション境界と
絡んで読みにくくなる。

| 種類 | 対応 |
| --- | --- |
| **ユーザー操作**(画面からの更新) | リトライしない。**409 を返して再読み込みさせる** |
| **冪等な自動処理**(バッチ、イベントハンドラ) | 少回数リトライ。**集約を読み直してから**やり直す |
| どちらでもない | まず「本当に同じ集約を同時更新するのか」を疑う。境界が広すぎる可能性 |

- **リトライは必ず「読み直し → 再実行」**。古いオブジェクトのバージョンだけ
  上げ直すのは、更新の喪失そのもの。
- **リトライ回数に上限**を設け、超えたら失敗させる。無限に粘らない。
- 競合が頻発するなら、**集約が大きすぎる**サイン([SKILL.md](SKILL.md) 第 3 節)。

## 悲観的ロックに切り替える判断

**既定は楽観的ロック。** 次のときだけ悲観的ロック(`select_for_update`)を使う。

- 競合が**高頻度**で、リトライのコストが無視できない。
- **やり直しが不可能**(外部への送信など、途中で副作用が確定する)。
- 在庫の引当のように、**読んだ値を根拠に書く**処理で、正確さが最優先。

```python
def find_by_id_for_update(self, order_id: OrderId) -> Order | None:
    row = OrderModel.objects.select_for_update().filter(pk=order_id.value).first()
    ...
```

- **`select_for_update()` は `atomic` の中でしか効かない。** 外で呼ぶと
  `TransactionManagementError`。
- **usecase からロックの有無が見えてはいけない。** メソッド名で意図を表し
  (`find_by_id_for_update`)、実装の詳細はリポジトリに閉じる。
- **ロックを取る順序をコード全体で統一する**(常に id の昇順など)。
  順序がバラバラだとデッドロックする。
- **ロック中に外部 API を呼ばない。** 相手の遅延がそのままロック時間になる。
- `nowait=True` / `skip_locked=True` は、待たずに諦める場合に使う
  (ジョブキューの取り合いなど)。

## テスト

- **楽観ロックの競合は再現できる。** 同じ集約を 2 回読み、片方を保存してから
  もう片方を保存し、`ConcurrentModification` が出ることを検証する。
- 悲観ロックの検証には**実際の並行実行**が要るので、通常のテストでは
  「`atomic` の中で呼ばれているか」までを見る。
- 詳細は [ddd-testing-strategy](../ddd-testing-strategy/SKILL.md)。
