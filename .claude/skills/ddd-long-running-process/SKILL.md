---
name: ddd-long-running-process
description: 複数のトランザクションにまたがる業務プロセスの進行と復旧を設計する。1 つの出来事で完結せず外部システムの応答を待つとき、イベントハンドラが数珠つなぎになって全体像を追えなくなったとき、worker が落ちても続きから再開させたいとき、inbox・補償・期限切れ・手動復旧を扱うとき、Saga や Process Manager を置くか決めるときに使う。
---

# DDD: 長期実行プロセス (Saga / Process Manager)

前提: Python 標準ライブラリの `dataclasses`。ドメイン層は **stdlib のみ**に依存する。
コード例と題材(注文、在庫、決済など)は論点を示すためのもので、実装の雛形ではない。

[ddd-domain-events](../ddd-domain-events/SKILL.md) は、ドメインで起きた事実の記録と配送を扱う。
このスキルでは、複数のメッセージとトランザクションをまたぐ業務プロセスの進行、復旧、
補償を扱う。

集約の境界は
[ddd-aggregate-repository-boundary](../ddd-aggregate-repository-boundary/SKILL.md)、
プロセス自体の状態設計は
[ddd-state-transition](../ddd-state-transition/SKILL.md)、
コンテキストをまたぐ場合は
[ddd-bounded-context](../ddd-bounded-context/SKILL.md)。

---

## 1. 使う場面

処理時間の長さではなく、複数のローカルトランザクションの間に進行状態を残す必要があるかで
判断する。数秒で終わる処理でも、別システムの応答や再送をまたぐなら対象になる。

次のいずれかに当てはまる場合は、長期実行プロセスとして設計する。

- 外部システムや別コンテキストからの応答を待つ。
- 次の処理が、前の処理結果や業務上の分岐によって変わる。
- 期限、再試行、補償、手動判断のいずれかがある。
- 「どこまで進み、次に何を待っているか」を問い合わせる必要がある。
- worker が停止しても、処理を続きから再開する必要がある。

次の処理には不要である。

- 1 回の DB トランザクションで完結する処理。
- 一つの出来事に対する、互いに独立した通知や投影更新。
- 進行状態を持たない単純なリトライ。

判断の目安は、復旧担当者が「次に何をすべきか」を永続データから決められるかどうかである。
ログの読み合わせや複数テーブルの推測が必要なら、プロセス状態が不足している。

## 2. 用語を分ける

Saga と Process Manager は同義ではない。

| 用語            | 意味                                                             |
| --------------- | ---------------------------------------------------------------- |
| Choreography    | 参加者がイベントに反応し、中央の調整役を置かずに処理を進める方式 |
| Orchestration   | 調整役が参加者へコマンドを送り、結果を受けて次の処理を決める方式 |
| Saga            | 複数のローカルトランザクションで整合性を保つパターン             |
| Process Manager | 進行状態を保持し、受信結果から次のメッセージを決める調整役       |

Saga は Choreography と Orchestration のどちらでも実装できる。Process Manager は
Orchestration の実装に使えるが、補償を伴わない業務ワークフローにも使える。

選択基準はステップ数ではない。

- 反応が互いに独立し、順序や全体の完了条件を共有しないなら Choreography が合う。
- 一つの業務結果に向けて順序、分岐、期限、補償を管理するなら Process Manager が合う。
- Choreography のまま全体像を追えなくなった場合は、暗黙のプロセスを Process Manager として
  明示する。

## 3. イベントを受け、コマンドを出す

イベントは起きた事実、コマンドは一つの宛先に依頼する操作である。調整役は結果イベントを
受け取り、次のコマンドを決める。イベント自体の設計と配送は
[ddd-domain-events](../ddd-domain-events/SKILL.md) に従う。

| 種類     | 例                       | 性質                                 |
| -------- | ------------------------ | ------------------------------------ |
| イベント | `ExternalReviewApproved` | 過去形。すでに確定した事実           |
| コマンド | `ConfirmOrder`           | 命令形。一つの担当先に実行を依頼する |

`ExternalApprovalRequested` を「次に実行してほしいこと」の意味で使うと、事実と依頼が混ざる。
依頼なら `RequestExternalApproval`、依頼の受付が確定した事実なら
`ExternalApprovalRequested` と名前を分ける。

処理の基本形は次のとおり。

```text
受信イベント
  -> inbox に受信内容と処理状態を記録
  -> プロセスをロックして状態遷移
  -> 履歴、inbox の結果、次のコマンドを outbox に保存
  -> commit
  -> relay がコマンドを配送
  -> 参加者が結果イベントを返す
```

inbox には `PENDING`、`APPLIED`、`QUARANTINED` などの処理状態を持たせる。適用が成立するときは、
プロセス状態、履歴、outbox、inbox の `APPLIED` を同じ DB トランザクションで確定する。これにより、
状態だけ進んで次のコマンドを失う空白をなくす。

受信の記録そのものは、その業務トランザクションと分けてコミットする。同じ境界に入れると、遷移が
拒否されたときに受信記録ごとロールバックされ、`QUARANTINED` に到達できないままブローカーの
再配送で同じ失敗を繰り返す。外部 API やブローカーはトランザクション内で呼ばない。outbox の relay
は同じコマンドを再配送しうるため、処理全体を `at-least-once` 前提で設計する。

```python
import uuid
from datetime import datetime


def handle_review_approved(
    *,
    message: ExternalReviewApproved,
    command_ids: tuple[uuid.UUID, ...],
    processed_at: datetime,  # タイムゾーン付き
) -> InboxResult:
    with transaction_manager():
        received = inbox.try_record_received(message, received_at=processed_at)
    if received.is_settled:
        return received

    try:
        with transaction_manager():
            process = process_repository.get_for_update(message.process_id)
            process, commands = process.on_review_approved(
                review_request_id=message.review_request_id,
                command_ids=command_ids,
                processed_at=processed_at,
            )
            process_repository.save(process)
            outbox.add_all(commands)
            return inbox.mark_applied(message.message_id)
    except ProcessPreconditionNotMet as pending:
        with transaction_manager():
            return inbox.mark_pending(
                message.message_id,
                awaiting=pending.awaiting,
                reevaluate_at=pending.reevaluate_at,
            )
    except ProcessTransitionRejected as rejected:
        with transaction_manager():
            outbox.add(QuarantineAlert.of(message, reason=rejected.reason))
            return inbox.mark_quarantined(
                message.message_id,
                reason=rejected.reason,
            )
```

`transaction_manager()` はトランザクション境界を表す port を指す。Django なら
`transaction.atomic` を包んだ実装を注入する。

- 決着済み (`APPLIED` / `QUARANTINED`) の受信は、記録した結果をそのまま返して `ACK` する。
  `PENDING` は決着していないため、再配送でもう一度遷移を試す。
- 受信記録と適用が別トランザクションなので、その間で停止すると inbox に受信だけが残る。次の
  再配送で遷移からやり直せる形にしておく。
- 重複の判定は inbox の `message_id` の一意制約に任せる。同時に届いた重複は insert に失敗し、
  決着済みの結果を読む経路へ回る。
- 一つの遷移が複数のコマンドを出すなら、コマンドごとに別の id を渡す。同じ id を使い回すと、
  relay の再送と購読側の冪等判定が二件目以降を重複として捨て、プロセスが来ない応答を待ち続ける。
  必要な個数が遷移によって変わるなら、`operation_id` を `process_id` とステップから決定的に導く
  ほうが、Usecase 側で個数を先読みするより破綻しにくい。

拒否の決着は、業務トランザクションが巻き戻ったあとに新しいトランザクションで書く。前提未達と
到達不能は別の結末なので、プロセス側で例外の型を分け、`except` で振り分ける。真偽値フラグ一つに
まとめると、`PENDING` にすべきメッセージを隔離する取り違えが型で防げなくなる。

| 拒否の種類                       | 決着          | 次に起きること                   |
| -------------------------------- | ------------- | -------------------------------- |
| 前提より先に届いた (正当)        | `PENDING`     | 状態変更時か定期処理が再評価する |
| 到達不能な状態、または照合不一致 | `QUARANTINED` | アラートを受けた担当者が調査する |

隔離のアラートは、コミット後にブローカーへ直接送らず outbox に入れる。送信前に停止すると、隔離
だけが残って誰も気づかない状態になる。`PENDING` 側にアラートは要らないが、待機期限を超えて
`QUARANTINED` へ移すときには同じ経路でアラートを出す。

参加者は各自の集約とトランザクションを所有する。Process Manager が別コンテキストの集約を
直接変更しない。

## 4. 進行状態を永続化する

Process Manager をドメインオブジェクトにするか Usecase 層の調整役にするかは、状態遷移に
業務ルールがあるかで決める。独自の識別子、ライフサイクル、不変条件を持つなら、集約として
扱う選択が合う。技術上の配送順序を管理するだけなら、Usecase 層の永続ステートマシンで
足りる。

状態は `Enum`、直和型、状態オブジェクトのいずれでもよい。bool フラグを増やすのではなく、
業務上あり得る状態だけを表現する。畳み方と遷移規則は
[ddd-state-transition](../ddd-state-transition/SKILL.md)。

プロセスには、判断と復旧に必要な情報を持たせる。

- `process_id`、現在の状態、ロック用 `version`。
- 各外部依頼の `operation_id` / `correlation_id`。
- 現在待っている応答、期限、次回再試行時刻、試行回数。
- 完了した処理、失敗理由、補償の進行状況。
- 最後に状態が変わった時刻と、必要なら `causation_id`。

他の集約は ID で参照する。外部システムのレスポンス全体をプロセスへ保存せず、後の判断や
照合に必要な値だけを保持する。

## 5. 重複、順序逆転、並行実行を分けて扱う

三つは別の問題であり、同じ仕組みでは解けない。

| 状況                                 | 対応                                                             |
| ------------------------------------ | ---------------------------------------------------------------- |
| 同じ `message_id` の再配送           | inbox に永続化した状態と結果を再利用し、`ACK` する               |
| 同じ業務操作が別 ID で再依頼         | 安定した `operation_id` と業務上の一意制約で結果を再利用する     |
| 適用済みの同じ事実が遅れて届いた     | 現在状態と `correlation_id` を照合し、no-op として記録する       |
| 前提より先に届いた、正当なメッセージ | inbox を `PENDING` にし、状態変更時か定期処理で再評価する        |
| 到達不能な状態、または照合不一致     | メッセージを隔離し、調査できる情報とともにアラートを出す         |
| 複数 worker の同時更新               | 行ロックまたは楽観ロックで直列化し、競合時に読み直して再判定する |

`no-op` にしてよいのは、同じメッセージか、すでに適用済みの同じ事実だけである。正当だが早く届いた
メッセージは矛盾ではない。受信内容、待っている前提、再評価時刻を inbox に永続化して `ACK` し、
状態変更時か定期処理で再評価する。再評価も同じプロセスをロックし、適用できたらプロセス状態、
`APPLIED` への変更、次の outbox を一つのトランザクションで確定する。ブローカーの再配送だけに
預けると、inbox の重複判定によって再評価されない。待機期限を超えても前提がそろわなければ
`QUARANTINED` に移し、アラートを出す。

現在状態では到達不能な事実や `correlation_id` の不一致まで黙って無視すると、外部システムとの
不整合を見落とす。隔離したメッセージは調査できるように残し、アラートを出す。

ロックは同じプロセスの状態遷移を直列化する。ブローカーの重複配送や外部 API の二重実行は
防げない。inbox と `operation_id` を併用する。排他方式の選択は
[ddd-aggregate-repository-boundary](../ddd-aggregate-repository-boundary/SKILL.md)。

別々の `process_id` が同じ在庫や口座を更新する競合もある。プロセス行のロックでは防げないため、
参加側の集約で一意制約、予約、version 検査などを行い、その結果をイベントとして返す。

## 6. 期限と再試行

期限と再試行時刻は永続化し、Celery beat などの定期処理が期限到来を検出する。スケジューラの
一度きりの予約だけに依存すると、予約消失やデプロイで処理を失う。

- 現在時刻は Usecase が現在時刻を返す port から取り、タイムゾーン付きの `datetime` として
  プロセスのメソッドへ渡す
  ([ddd-modeling-primitives](../ddd-modeling-primitives/SKILL.md))。
- 通常の結果とタイムアウトが競合したら、同じロックと状態遷移規則で一方だけを適用する。
- 一時障害には上限付きの再試行とバックオフを使う。上限到達後の状態と通知先を決める。
- 外部呼び出しの応答を失った場合は、再実行前に `operation_id` で結果を照会する。照会も
  冪等再実行もできなければ、自動処理を止めて手動判断へ送る。

タイムアウト後の処理は業務判断である。自動失効、催促、補償開始、担当者への通知のどれを
選ぶかを状態遷移として定義する。

## 7. 補償は新しい業務操作

確定済みのローカルトランザクションはロールバックできない。補償は過去を消す処理ではなく、
影響を打ち消す新しい業務操作である。元の記録と補償の記録をどちらも残す。

| ステップの性質     | 設計                                                   |
| ------------------ | ------------------------------------------------------ |
| 補償できる         | 引当解除、決済取消などの明示的な補償コマンドを用意する |
| 冪等に再実行できる | 同じ `operation_id` で再試行し、前進して回復する       |
| 結果が不明         | 外部状態を照会し、成功と失敗を確定してから次へ進む     |
| 取り消せない       | 失敗時の代替措置と、人が判断する条件を業務ルールにする |

取り消せない操作を後半に置けるなら、補償範囲を狭められる。ただし、法令、外部との取り決め、業務上の依存
関係が順序を決めるため、一律の規則にはしない。補償は成功処理の逆順になることが多いが、
依存関係が別の順序を求める場合はそちらに合わせる。

補償自体が失敗した場合は、元の失敗と区別して状態を保存する。上限付きで再試行し、解消しなければ
必要な外部 ID、最後のエラー、担当者が取るべき操作を添えてエスカレーションする。

## 8. 停止を検出し、復旧できるようにする

現在状態だけでは運用に足りない。少なくとも次を検索・表示できるようにする。

- 状態ごとの滞留件数と最長滞留時間。
- 期限超過、再試行上限の到達、補償中、隔離メッセージの件数。
- `process_id`、`message_id`、`correlation_id`、`causation_id`、外部 `operation_id`。
- 状態遷移、発行コマンド、受信イベント、失敗理由の時系列。
- 次回再試行時刻と、手動判断が必要な理由。

`FAILED` や `MANUAL_INTERVENTION_REQUIRED` を状態として持つか、ステップ状態から導出するかは
モデルに合わせる。どちらの場合も、停止を一覧でき、再試行可能か、補償が必要かを機械的に
判定できなければならない。読み取りモデルは
[ddd-read-model-cqrs](../ddd-read-model-cqrs/SKILL.md)。

手動介入は DB の直接更新ではなく、`RetryStep`、`StartCompensation`、
`ResolveManualIntervention` などの監査可能な操作として定義する。強制完了や強制中止は、
業務上許される場合だけ用意する。

## 9. 置き場所

```text
domain/
├── processes/
│   ├── order_fulfillment_process.py  # プロセス集約(状態と遷移)
│   └── order_fulfillment_state.py
└── repositories/
    └── order_fulfillment_process_repository.py # Repository Protocol
usecases/
├── advance_order_fulfillment.py      # 受信、状態遷移、次のコマンドの調整
├── recover_stalled_processes.py      # 停止検出と再開。定期実行から呼ぶ
└── ports/                            # 送信・トランザクション・現在時刻の port
infrastructure/
├── repositories/                     # process / inbox / outbox の永続化
├── serializers/                      # 送受信メッセージと保存形式の変換
├── tasks/                            # 定期走査と再試行の入口
└── containers/                       # ハンドラ、リポジトリ、relay の配線
```

- 業務ルールを持つプロセスはドメイン層(stdlib のみ)に置き、Celery や Django ORM を
  参照させない。
- Repository の Protocol はドメイン層、実装はインフラ層に置く
  ([ddd-aggregate-repository-boundary](../ddd-aggregate-repository-boundary/SKILL.md))。
- 送信・トランザクション・現在時刻の port は Usecase 層が定義し、実装の組み立ては
  composition root で行う([ddd-application-layer](../ddd-application-layer/SKILL.md))。
- Usecase を呼ぶ入口(定期実行、イベントハンドラ)は [adapter-design](../adapter-design/SKILL.md)
  に従う。

## アンチパターン

| アンチパターン                                            | 問題                                                 |
| --------------------------------------------------------- | ---------------------------------------------------- |
| ハンドラの連鎖に進行状態を隠す                            | 全体の進捗、期限、補償範囲を一か所で確認できない     |
| イベントとコマンドを同じ型・命名で扱う                    | 事実の通知と実行依頼の責務が曖昧になる               |
| 状態だけ保存し、次のメッセージを直接送る                  | 保存後・送信前の停止でプロセスが進まなくなる         |
| Process Manager が外部 API を DB トランザクション内で呼ぶ | ロック時間が延び、不明結果とロールバックが混ざる     |
| 楽観ロックだけで重複配送も防ごうとする                    | 状態競合は防げても同じ副作用を再実行する             |
| 不正な状態のメッセージをすべて `no-op` にする             | 順序逆転や外部不整合を検出できない                   |
| 進行状況を bool フラグの集合で持つ                        | 業務上あり得ない組み合わせを表現できる               |
| プロセス内で `datetime.now()` を呼ぶ                      | 期限判定をテストで再現できない                       |
| 補償失敗を元の `FAILED` にまとめる                        | 未解消の外部副作用を運用から見分けられない           |
| 受信記録を業務トランザクションと同じ境界に入れる          | 拒否時に受信記録ごと巻き戻り、隔離もアラートも出ない |
| 複数のコマンドに同じ id を使い回す                        | 購読側の冪等判定が二件目以降を捨て、応答待ちで止まる |
| 無限リトライで停止を隠す                                  | 恒久障害や不明結果に人が気づけない                   |
| 手動介入で DB を直接更新する                              | 不変条件と監査履歴を迂回する                         |
