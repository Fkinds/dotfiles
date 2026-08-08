---
name: ddd-long-running-process
description: 複数ステップ・長期間にまたがる業務プロセスの設計指針。コレオグラフィとオーケストレーションの使い分け、調整役(プロセスマネージャ / Saga)の責務と状態のモデル化、後戻りできない処理を打ち消す補償トランザクション、期限切れとタイムアウトの扱い、再実行と冪等性、失敗したプロセスの可視化と手動介入を扱う。イベントハンドラが数珠つなぎになってきたとき、申込から開始までのような数日がかりのプロセスを実装するとき、途中で失敗したときの取り消しを設計するときに使う。
allowed-tools:
  - Read
  - Grep
  - Glob
---

# DDD: 長期実行プロセス (Saga / Process Manager)

[ddd-domain-events](../ddd-domain-events/SKILL.md) は「イベント → ハンドラ」の
**1 段**を扱う。ここはその先 — **複数の集約・複数の日をまたぐ業務プロセス**をどう
組み立て、失敗したときにどう戻すか。

集約の境界は
[ddd-aggregate-repository-boundary](../ddd-aggregate-repository-boundary/SKILL.md)、
プロセス自体の状態設計は
[ddd-state-transition](../ddd-state-transition/SKILL.md)、
コンテキストをまたぐ場合は
[ddd-bounded-context](../ddd-bounded-context/SKILL.md)。

---

## 1. いつ必要か

**1 つのイベント → 1 つのハンドラで終わらないとき。**

必要:

- ステップが**複数**あり、順序と条件がある(申込 → 審査 → 契約 → 開始)。
- **待ち時間が長い**(外部機関の回答待ちが数日)。プロセスがプロセス外の時間を跨ぐ。
- 途中で失敗したとき、**すでに済んだ処理を打ち消す**必要がある。
- **期限**がある(N 日以内に回答がなければ失効)。

不要:

- 1 集約で完結する → メソッド呼び出し。
- 「イベント → 1 つの副作用」 → 普通のハンドラで足りる。
- 全部が同じトランザクションで終わる → そもそも 1 集約であるべき。

**判定**: 「途中で止まった状態」が業務上あり得るなら、プロセスとして実体化する。

---

## 2. コレオグラフィか、オーケストレーションか

| | コレオグラフィ (Choreography) | オーケストレーション (Orchestration) |
| --- | --- | --- |
| 形 | 各集約がイベントに反応して次を起こす | **調整役**が順序を持ち、各ステップを指示する |
| 全体像 | どこにも書かれていない | **1 か所に集まる** |
| 向き | 2〜3 ステップ、分岐なし | 4 ステップ以上、分岐・補償あり |
| 弱点 | **誰も全体を把握できない**。追跡困難 | 調整役が肥大しやすい |

**既定はコレオグラフィ、複雑になったらオーケストレーション。**

切り替えの合図:

- イベントの連鎖が **3 段**を超えた。
- 「今どこまで進んでいるか」を答えるのに複数テーブルを見る必要がある。
- 失敗時にどこまで戻すかが、どのハンドラにも書かれていない。

> [ddd-domain-events](../ddd-domain-events/SKILL.md) の「ハンドラの連鎖を深くしない」は
> **コレオグラフィをやめて調整役を立てろ**という意味。

---

## 3. 調整役は「状態を持つ」

プロセスマネージャ(Saga)は、**それ自体が状態を持つドメインオブジェクト**。
ステートレスなドメインサービスとは違う。

```python
@dataclass(frozen=True, kw_only=True, eq=False)
class SwitchingProcess(Entity):
    """他社から自社への切替プロセス。数日〜数週間かかる。"""

    application_id: ApplicationId       # 他の集約は id で参照
    state: SwitchingState
    deadline: datetime
    completed_steps: tuple[SwitchingStep, ...] = ()
    events: tuple[DomainEvent, ...] = ()

    def on_validated(self, *, at: datetime) -> "SwitchingProcess":
        self._assert_state(SwitchingState.VALIDATING)
        return replace(
            self,
            state=SwitchingState.AWAITING_EXTERNAL_APPROVAL,
            completed_steps=(*self.completed_steps, SwitchingStep.VALIDATED),
            events=(*self.events, ExternalApprovalRequested(process_id=self.id)),
        )
```

- **プロセスは 1 つの集約**。自分の状態だけを変更し、他の集約は id で参照する。
- **次にやることを「イベント/コマンド」として積む**。プロセスが直接他の集約を
  変更しない(1 トランザクション 1 集約の原則は変わらない)。
- **済んだステップを記録する。** 補償(第 5 節)で「どこまで戻すか」を決めるのに要る。
- **調整役に業務ルールを書きすぎない。** 「審査に通るか」は審査コンテキストの
  判断。プロセスは**順序と失敗時の処理**だけを持つ。

---

## 4. プロセスの状態を型で表す

進行状況をフラグの集合で持つと、あり得ない組み合わせが表現できてしまう。

```python
# NG: 組み合わせが 2^4 通り。あり得ない状態が作れる
is_validated: bool
is_approved: bool
is_cancelled: bool
is_completed: bool

# OK: 取りうる状態だけを列挙する
class SwitchingState(Enum):
    VALIDATING = "validating"
    AWAITING_EXTERNAL_APPROVAL = "awaiting_external_approval"
    SCHEDULED = "scheduled"
    COMPLETED = "completed"
    CANCELLED = "cancelled"
    FAILED = "failed"
```

遷移の妥当性(どこからどこへ行けるか)の設計は
[ddd-state-transition](../ddd-state-transition/SKILL.md)。

---

## 5. 補償トランザクション

**プロセス全体をロールバックすることはできない。** 各ステップは別々の
トランザクションで確定済みなので、**打ち消す操作を業務として定義する**。

```text
進行:  在庫引当 → 決済 → 出荷指示
失敗:            ↓ 決済失敗
補償:  引当解除 ←
```

- **補償は「取り消し」であって「なかったこと」ではない。** 記録は残る
  (`OrderCancelled` であって、注文レコードの削除ではない)。
- **補償できない操作を見極める。** メール送信、外部への通知、現金の受け渡しは
  取り消せない。**取り消せない操作は、後ろに置く**のが原則。
- **補償の順序は逆順。** 最後に成功したステップから戻る。
- **補償自体が失敗しうる。** リトライし、それでも駄目なら**人間に上げる**
  (第 8 節)。無限リトライで隠さない。

| ステップの性質 | 設計 |
| --- | --- |
| 取り消せる(DB 上の予約・引当) | 補償操作を定義する |
| 取り消せない(送信・出金) | **プロセスの後半に置く**。前半で検証を済ませる |
| 冪等に再実行できる | 補償より**再試行**で回復させる |

---

## 6. 期限とタイムアウト

長期プロセスは**待っている間に何も起きない**ことがある。それを検知する仕組みが要る。

- **プロセスに期限(`deadline`)を持たせる。** 「いつまでに次が起きるべきか」。
- **時間を外から入れる。** 定期実行(cron / Celery beat)が期限切れのプロセスを
  拾い、`on_timeout()` を呼ぶ。プロセス自身は時計を持たない。
- **現在時刻は引数で受け取る**([ddd-modeling-primitives](../ddd-modeling-primitives/SKILL.md))。
  プロセス内で `datetime.now()` を呼ばない。
- タイムアウトの結果は**業務判断**。自動失効か、催促か、人間に上げるか。

```python
def on_timeout(self, *, now: datetime) -> "SwitchingProcess":
    if now < self.deadline:
        raise ValueError("まだ期限内")
    return replace(self, state=SwitchingState.FAILED,
                   events=(*self.events, SwitchingExpired(process_id=self.id)))
```

---

## 7. 再実行と冪等性

**同じステップが 2 回動く前提で書く。** イベントの再送、cron の重複起動、
手動の再実行が必ず起きる。

- **済んだステップを記録し、既に済んでいたら何もしない**(no-op で返す)。
  例外にしない — 再送のたびにエラーになる。
- **外部呼び出しには冪等キーを渡す**(決済 API の idempotency key など)。
- 同じプロセスが**並行して動かない**ようにする。プロセス集約に対する
  楽観的ロックで十分
  ([ddd-aggregate-repository-boundary](../ddd-aggregate-repository-boundary/SKILL.md))。

---

## 8. 失敗を見えるようにする

**長期プロセスは必ず詰まる。** 詰まったことに気付けない設計が最大の問題。

- **`FAILED` / `STUCK` を状態として持つ。** 「進んでいない」を検出可能にする。
- **一覧できるようにする**(管理画面 / クエリ)。「今止まっているプロセス」を
  読み取りモデルで出す([ddd-read-model-cqrs](../ddd-read-model-cqrs/SKILL.md))。
- **手動介入の口を用意する。** 再実行・強制完了・強制中止。運用は必ず必要になる。
  介入も**ドメインの操作として定義する**(DB を直接 UPDATE させない)。
- **何が起きたかを残す。** 済んだステップと失敗理由。事後の調査はこれが頼り。

### 置き場所

```text
domain/
├── processes/
│   ├── switching_process.py     # プロセス集約(状態 + 遷移)
│   └── switching_state.py
├── events/
└── repositories/
    └── switching_process_repository.py
usecases/
├── advance_switching_process.py  # イベント受信 → プロセスを進める
└── expire_switching_processes.py # 定期実行から呼ぶ
infrastructure/
└── events/handlers/              # イベント → usecase の配線
```

- **プロセスはドメイン層**(stdlib のみ)。cron も Celery も知らない。
- 定期実行の設定はインフラ層。usecase を呼ぶだけ。

---

## アンチパターン

| アンチパターン | なぜ悪いか |
| --- | --- |
| イベントハンドラを 4 段以上つなぐ | 全体像がどこにもなく、追跡も変更も不能になる |
| プロセスの状態をどこにも持たない | 「今どこまで進んだか」を答えられない |
| 調整役が複数の集約を直接更新する | 1 トランザクション 1 集約の違反が場所を変えて再発 |
| 進行状況を bool フラグの集合で持つ | あり得ない組み合わせが表現できる |
| プロセス全体をトランザクションで囲もうとする | 数日にわたる処理を囲めない。補償で設計する |
| 補償操作を定義せず、失敗したら放置 | 引当や仮押さえが残り続ける |
| 取り消せない操作(送信・出金)を前半に置く | 後で失敗しても戻せない |
| プロセス内で `datetime.now()` を呼ぶ | 期限のテストができない |
| ステップの再実行で例外を投げる | 再送のたびに失敗する。no-op にする |
| 失敗状態を持たず、無限リトライで隠す | 詰まっていることに誰も気付かない |
| 手動介入を DB 直更新でやる | 不変条件を迂回する。ドメインの操作として定義する |

---

## ルール(チェックリスト)

- [ ] 「途中で止まった状態」が業務上あり得るので、プロセスを**実体化**した
- [ ] 連鎖が 3 段を超えたので**コレオグラフィから調整役へ**切り替えた(または 2 段以内で収まっている)
- [ ] プロセスが**1 つの集約**で、自分の状態だけを変更している
- [ ] 他の集約への作用は**イベント / コマンド経由**。直接更新していない
- [ ] 進行状況が **`Enum`** で、bool フラグの集合になっていない
- [ ] **済んだステップを記録**している(補償の範囲決定に使う)
- [ ] 各ステップに**補償操作**を定義した(または補償不要と判断した)
- [ ] **取り消せない操作をプロセスの後半**に置いた
- [ ] 補償の失敗をリトライし、駄目なら**人間に上げる**経路がある
- [ ] **期限**を持ち、定期実行が期限切れを拾う。時刻は引数で受け取っている
- [ ] ステップの**再実行が no-op** になる(例外を投げない)
- [ ] 外部呼び出しに**冪等キー**を渡している
- [ ] **失敗状態を持ち、一覧できる**。手動介入がドメインの操作として定義されている
- [ ] プロセス定義がドメイン層(stdlib のみ)にあり、cron / Celery を知らない
