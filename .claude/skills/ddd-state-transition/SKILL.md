---
name: ddd-state-transition
description: ドメインオブジェクトの状態と遷移の設計指針。bool フラグの乱立を Enum へ畳む判断、遷移表による許可された遷移の定義、遷移を集約のメソッドとして表現する方法、状態ごとに持つべきデータが違う場合の型の分け方、履歴と現在状態の関係、永続化と後方互換、遷移のテストを扱う。ステータスやフラグが増えてきたとき、あり得ない状態の組み合わせが作れてしまうとき、状態によって使わないフィールドが増えたとき、ライフサイクルの長いモデルを設計するときに使う。
allowed-tools:
  - Read
  - Grep
  - Glob
---

# DDD: 状態と遷移 (State & Transition)

**「どんな状態がありうるか」と「どこからどこへ行けるか」を型とコードで固定する。**
[ddd-domain-object-completeness](../ddd-domain-object-completeness/SKILL.md) の
「妥当な範囲だけをモデル化する」を、**時間軸(ライフサイクル)**に広げたもの。

複数の集約・複数日にまたがるプロセスの調整は
[ddd-long-running-process](../ddd-long-running-process/SKILL.md)、
状態が変わった事実を外へ伝えるのは
[ddd-domain-events](../ddd-domain-events/SKILL.md)。
**処理の受理と業務結果を別の軸として持つ**設計は
[operation-result-design](../operation-result-design/SKILL.md)。

---

## 1. bool フラグを畳む

**フラグが 2 つ以上あったら状態を疑う。** N 個の bool は 2^N 通りを表現でき、
その大半は業務上あり得ない。

```python
# NG: 16 通りのうち、意味があるのは 5 通り程度
is_draft: bool
is_submitted: bool
is_approved: bool
is_cancelled: bool
# → is_approved=True かつ is_cancelled=True が作れてしまう

# OK: 取りうる状態だけを列挙する
class ApplicationStatus(Enum):
    DRAFT = "draft"
    SUBMITTED = "submitted"
    APPROVED = "approved"
    REJECTED = "rejected"
    CANCELLED = "cancelled"
```

### 畳めるフラグ / 畳めないフラグ

| 種類 | 例 | 扱い |
| --- | --- | --- |
| **互いに排他**(同時に真にならない) | draft / submitted / approved | **`Enum` に畳む** |
| **独立して立つ** | `is_locked`(どの状態でも起きうる) | フラグのまま、または別の軸の `Enum` |
| 導出できる | `is_editable` = `status is DRAFT` | **持たない。`@property` で計算する** |

**導出できるフラグを保存しない。** 状態と食い違い、どちらが正か分からなくなる。

```python
@property
def is_editable(self) -> bool:
    return self.status is ApplicationStatus.DRAFT
```

---

## 2. 許可された遷移だけを定義する

**「どこからどこへ行けるか」をコードに書く。** 書かなければ、どこからでも行ける。

```python
_ALLOWED: dict[ApplicationStatus, frozenset[ApplicationStatus]] = {
    ApplicationStatus.DRAFT:     frozenset({ApplicationStatus.SUBMITTED,
                                            ApplicationStatus.CANCELLED}),
    ApplicationStatus.SUBMITTED: frozenset({ApplicationStatus.APPROVED,
                                            ApplicationStatus.REJECTED,
                                            ApplicationStatus.CANCELLED}),
    ApplicationStatus.APPROVED:  frozenset(),   # 終端
    ApplicationStatus.REJECTED:  frozenset(),   # 終端
    ApplicationStatus.CANCELLED: frozenset(),   # 終端
}


def can_transition_to(self, to: ApplicationStatus) -> bool:
    return to in _ALLOWED[self.status]
```

- **終端状態を明示する**(空集合)。「ここから先はない」が読める。
- 遷移表は**ドメイン層に置く**。usecase や serializer に散らさない。
- 表が読みにくいほど大きくなったら、**状態が多すぎる**か、
  **2 つの軸が混ざっている**(第 4 節)。

---

## 3. 遷移は「意図を表すメソッド」で起こす

**状態を直接代入させない。** 遷移表を持っていても、`status` を書き換えられるなら
意味がない。

```python
# NG: 状態を外から設定する。遷移表が迂回される
application.status = ApplicationStatus.APPROVED

# OK: 業務の操作として呼ぶ
approved = application.approve(approved_by=reviewer_id, at=now)
```

```python
def approve(self, *, approved_by: UserId, at: datetime) -> "Application":
    self._assert_can_transition_to(ApplicationStatus.APPROVED)
    # 遷移固有の事前条件(遷移表だけでは表せないもの)
    if self.reviewer_id == approved_by:
        raise ValueError("申請者は自分で承認できない")
    return replace(
        self,
        status=ApplicationStatus.APPROVED,
        approved_at=at,
        events=(*self.events, ApplicationApproved(application_id=self.id)),
    )
```

- **メソッド名は業務の言葉**(`approve` / `reject` / `withdraw`)。
  `set_status` / `change_state` は業務の言葉ではない。
- **遷移表 + 遷移固有の条件**の 2 段で守る。表は「経路」、メソッドは「条件」。
- **frozen なので新しいインスタンスを返す。** 元は変わらない。
- 遷移した事実をイベントとして積む
  ([ddd-domain-events](../ddd-domain-events/SKILL.md))。

---

## 4. 状態ごとにデータが違うとき

「承認済みのときだけ `approved_at` がある」ような場合、全部を `| None` で持つと
**どの状態で何が入っているかが型から消える**。

```python
# 問題: 状態と field の対応がコードのどこにも書かれていない
status: ApplicationStatus
approved_at: datetime | None
rejected_reason: str | None
cancelled_at: datetime | None
```

| 状況 | 対処 |
| --- | --- |
| `None` フィールドが 1〜2 個 | **そのままでよい。** 過剰設計を避ける |
| 状態ごとの付随データが 3 個以上 | 状態を**値オブジェクト**にして、データを一緒に持たせる |
| 状態ごとに**振る舞いが違う** | 状態ごとに**別の型**(State パターン) |

```python
# 状態に付随データを持たせる
@dataclass(frozen=True, kw_only=True)
class Approved(ValueObject):
    approved_at: datetime
    approved_by: UserId


@dataclass(frozen=True, kw_only=True)
class Rejected(ValueObject):
    rejected_at: datetime
    reason: RejectionReason


ApplicationState = Draft | Submitted | Approved | Rejected | Cancelled
```

`match` で網羅的に分岐でき、**状態を追加したときに分岐の漏れが見つかる**。

> **ただし既定は `Enum`。** 型を分けるのは、付随データか振る舞いが実際に違うときだけ。
> 状態が 5 個あるだけで型を 5 個作ると、読む量が増えるだけで何も守れない。

### 2 つの軸が混ざっていないか

`SUBMITTED_AND_LOCKED` のような複合状態が出てきたら、**独立した 2 つの軸**が
1 つの `Enum` に押し込まれている。状態数が掛け算で増える前に分ける。

```python
status: ApplicationStatus     # 申請の進行
lock: LockState               # 編集ロック(進行とは独立)
```

---

## 5. 現在状態と履歴

**現在状態を履歴から毎回計算しない**(それはイベントソーシング。採用していないなら過剰)。

- **現在状態はフィールドとして持つ。** 読み取りが速く、単純。
- **履歴が業務の関心なら、別に記録する**(状態遷移ログ / ドメインイベントの永続化)。
  「いつ誰が承認したか」を問われるなら、それは業務要件。
- 履歴は**集約に溜めない**。伸び続けるコレクションは集約を肥大させる
  ([ddd-aggregate-repository-boundary](../ddd-aggregate-repository-boundary/SKILL.md))。
  別テーブル + 読み取りモデルで出す。
- 「直前の状態」が遷移判断に要るなら、それは**フィールドとして持つ**
  (`previous_status`)。履歴を引きに行かない。

---

## 6. 永続化と後方互換

- **DB には値(文字列)で保存する。** `Enum` の `value` を保存し、`name` や連番に
  依存しない。並び順の変更でデータが壊れる。
- **未知の値を黙って受け入れない。** 復元時に `ApplicationStatus(value)` が
  `ValueError` を出すのは正しい挙動
  ([ddd-aggregate-repository-boundary](../ddd-aggregate-repository-boundary/SKILL.md))。
- **状態を削除・改名するときはデータ移行が要る。** `Enum` から消すだけでは
  既存行が読めなくなる。移行 migration とセットで。
- **Django の `choices` と `Enum` を二重管理しない。** `Enum` を単一の正とし、
  `choices` はそこから生成する。

```python
class ApplicationModel(models.Model):
    status = models.CharField(
        max_length=20,
        choices=[(s.value, s.name) for s in ApplicationStatus],  # Enum から生成
    )
```

---

## 7. 遷移のテスト

**遷移表があるなら、表を回してテストできる。**

```python
@pytest.mark.parametrize(
    ("frm", "to"),
    [(f, t) for f, tos in _ALLOWED.items() for t in tos],
)
def test_許可された遷移は成功する(frm, to) -> None:
    an_application(status=frm)._assert_can_transition_to(to)   # 例外が出ない


@pytest.mark.parametrize(
    ("frm", "to"),
    [(f, t) for f in ApplicationStatus for t in ApplicationStatus
     if t not in _ALLOWED[f]],
)
def test_許可されない遷移は失敗する(frm, to) -> None:
    with pytest.raises(ValueError):
        an_application(status=frm)._assert_can_transition_to(to)
```

- **禁止されている遷移こそテストする。** 許可の方は実装で自然に通る。
- 状態を追加したとき、**テストが自動で増える**(表から生成しているため)。
- 遷移固有の条件(「申請者は自分で承認できない」)は個別にテストする。
- 詳細は [ddd-testing-strategy](../ddd-testing-strategy/SKILL.md)。

---

## アンチパターン

| アンチパターン | なぜ悪いか |
| --- | --- |
| 排他的な状態を bool フラグの集合で持つ | あり得ない組み合わせが作れる |
| 導出できるフラグを保存する | 状態と食い違う。どちらが正か分からなくなる |
| 遷移表がなく、どこからでも遷移できる | 不正な経路を誰も止められない |
| `status` を外から代入できる | 遷移表もメソッドも迂回される |
| `set_status(x)` という API | 業務の意図が消える。何が起きたか分からない |
| 遷移判定が usecase / serializer にある | ドメインの外にルールが出る |
| 状態が 5 個あるだけで型を 5 個作る | 読む量が増えるだけ。既定は `Enum` |
| `SUBMITTED_AND_LOCKED` のような複合状態 | 独立した 2 軸が混ざり、状態数が掛け算で増える |
| 現在状態を毎回履歴から計算する | 遅く複雑。イベントソーシングでないなら過剰 |
| 履歴を集約の中に溜める | コレクションが伸び続け、集約が肥大する |
| `Enum` を連番で DB に保存する | 並び順の変更でデータが壊れる |
| Django の `choices` と `Enum` を二重管理 | 必ずズレる。`Enum` から生成する |
| 状態を `Enum` から消すだけ | 既存行が復元できなくなる |

---

## ルール(チェックリスト)

- [ ] 排他的なフラグを **`Enum` に畳んだ**。あり得ない組み合わせが作れない
- [ ] **導出できるフラグを保存していない**(`@property` で計算)
- [ ] **遷移表**をドメイン層に持ち、終端状態を明示した
- [ ] 遷移は**業務の言葉のメソッド**で起こす。`status` を外から代入できない
- [ ] 遷移表(経路)と**遷移固有の事前条件**の 2 段で守っている
- [ ] 遷移した事実を**ドメインイベント**として積んでいる(必要なら)
- [ ] 状態ごとのデータが多い場合だけ**型を分けた**(既定は `Enum` のまま)
- [ ] **独立した軸を別フィールドに分けた**(複合状態を作っていない)
- [ ] 現在状態を**フィールドで持ち**、履歴から計算していない
- [ ] 履歴が要るなら**集約の外**に記録している
- [ ] DB には `Enum` の**値(文字列)**を保存している
- [ ] Django の `choices` を **`Enum` から生成**している
- [ ] **禁止されている遷移**を、遷移表から生成したテストで検証している
