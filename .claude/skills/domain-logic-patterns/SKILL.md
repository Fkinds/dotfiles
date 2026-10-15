---
name: domain-logic-patterns
description: 業務ロジックをどの形で書くか(トランザクションスクリプト / テーブルモジュール / ドメインモデル)を選ぶ指針。新しい機能やアプリの設計を始めるとき、DDD を入れるべきか迷うとき、CRUD で足りるか判断するとき、view や service 関数に同じ if が増えてきたとき、Django モデルにロジックを持たせるか分離するか決めるときに使う。扱う範囲は 3 つの形の違い、業務ルールの複雑さの測り方、Django での軽量版と本格版のドメインモデル、形を切り替えるサイン、1 つのプロジェクト内での使い分け、Service Layer を置くかどうか。
---

# 業務ロジックの組み立て方 (Domain Logic Patterns)

**業務ロジックをどの形で書くかを、機能ごとに最初に選ぶ。** 他の `ddd-*` スキルは
「ドメインモデルで書く」と決めた後の設計を扱う。ここはその手前の判断。

出典は Martin Fowler『Patterns of Enterprise Application Architecture』の
Domain Logic Patterns。各パターンの要約は
[著者のカタログ](https://martinfowler.com/eaaCatalog/)にある。

関連スキル:

- どの領域に設計コストをかけるか(コア / 支援 / 汎用) → [ddd-bounded-context](../ddd-bounded-context/SKILL.md)
- 既存の手続き的なコードをドメインモデルへ移す手順 → [ddd-legacy-refactoring](../ddd-legacy-refactoring/SKILL.md)
- ドメインモデルを採った後の usecase の書き方 → [ddd-application-layer](../ddd-application-layer/SKILL.md)
- 層や抽象を足すかどうか → [clean-architecture-boundaries](../clean-architecture-boundaries/SKILL.md)

---

## 1. 3 つの形

| 形 | 業務ロジックの置き場所 | Django での姿 |
| --- | --- | --- |
| **トランザクションスクリプト** | 業務操作 1 つにつき手続き 1 つ。その中で読み込み・判断・書き込みを順に行う | `services.py` の関数や view が ORM を直接触る |
| **テーブルモジュール** | テーブル 1 つにつきクラス 1 つ。行の集合をまとめて扱う | 独自の `QuerySet` メソッド(`Order.objects.overdue().total()`) |
| **ドメインモデル** | 業務の概念ごとのオブジェクト。データと振る舞いを一緒に持つ | 軽量版: Django モデルのメソッド / 本格版: ORM から分離した dataclass(第 4 節) |

- **テーブルモジュールは Django では主役にしない。** 行の集合を受け渡す仕組み
  (.NET の DataSet など)が中心の環境向けの形で、Django では集計や一括更新に
  部分的に現れるくらい。
- 実際の選択は**トランザクションスクリプトか、ドメインモデルか**になる。

---

## 2. 選ぶ基準は「業務ルールの複雑さ」

2 つの形は、**始めるコスト**と**ルールが増えたときのコストの伸び方**が違う。

| | トランザクションスクリプト | ドメインモデル |
| --- | --- | --- |
| 始めるコスト | **最小**。手続きを書くだけ | 高い。概念の切り出し、永続化との対応づけ |
| ルールが増えたとき | 条件分岐と重複が増え、**変更コストが急に上がる** | 判断が 1 か所に集まるので、**伸びが緩やか** |
| チームに求めるもの | ほぼなし | オブジェクト設計に慣れていること |

**どこで逆転するかは事前に測れない。** だから次の問いで複雑さを見積もる。

### 複雑さを測る問い

- [ ] 同じ判断(「この予約は取り消せるか」)が 2 つ以上の操作で使われる、または使われる予定がある
- [ ] 状態があり、状態によって許される操作が変わる
- [ ] 計算に例外規則がある(会員ランク・期間・地域で変わる)
- [ ] 業務担当者との会話に、テーブル名でない業務用語(「引当」「締め」「仮押さえ」)が出てくる
- [ ] 1 回の操作で、複数のフィールドにまたがる整合性を守る必要がある
- [ ] 今後もルールが増え続けると分かっている

### 判定

| 状況 | 選ぶ形 |
| --- | --- |
| 画面とテーブルがほぼ 1 対 1。判断は入力チェック程度(CRUD) | **トランザクションスクリプト**。DRF の `ModelViewSet` のままでよい |
| 上のチェックが 0〜1 個 | **トランザクションスクリプト** |
| 上のチェックが 2〜3 個 | **ドメインモデル(軽量版)** から始める |
| 上のチェックが 4 個以上、またはコアドメイン | **ドメインモデル(本格版)** |
| 行の集合への集計・一括更新が中心 | `QuerySet` で書く。ドメインモデルにしない |
| 汎用サブドメイン(認証・通知・帳票) | 書かない。既製品を使う([ddd-bounded-context](../ddd-bounded-context/SKILL.md)) |

- **後からの切り替えは高くつく。** トランザクションスクリプトからドメインモデルへの移行は、
  呼び出し元をすべて書き換える作業になる。**複雑になると分かっている領域は最初から
  ドメインモデルで始める。**
- **分からないならトランザクションスクリプトで始めてよい。** ただし、切り替えるサイン
  (第 5 節)をそのときに決めて残しておく。
- サブドメインの分類は「どこに投資するか」、ここは「ロジックをどの形で書くか」。
  たいてい一致するが、**支援サブドメインでもルールが複雑ならドメインモデルにする**。

---

## 3. 同じルールを 2 つの形で書いた例

予約の取り消し。開始の 3 日前を過ぎたら取消料がかかり、開始後は取り消せない。

```python
# トランザクションスクリプト: 操作ごとの関数が ORM を直接触る
def cancel_reservation(reservation_id: int, now: datetime) -> None:
    with transaction.atomic():
        r = ReservationModel.objects.select_for_update().get(pk=reservation_id)
        if now >= r.starts_at:
            raise ReservationError("開始後は取り消せない")
        fee = r.price * Decimal("0.3") if r.starts_at - now < timedelta(days=3) else Decimal(0)
        r.status = "cancelled"
        r.cancellation_fee = fee
        r.save()
```

これで十分な間は、これでよい。問題は**同じ判断を使う 2 つ目の操作**が来たとき。

```python
# 日程変更にも同じ判断が要る → コピーが始まる
def reschedule_reservation(reservation_id: int, new_start: datetime, now: datetime) -> None:
    ...
    if now >= r.starts_at:                                    # ← コピー 1
        raise ReservationError("開始後は変更できない")
    fee = r.price * Decimal("0.3") if r.starts_at - now < timedelta(days=3) else Decimal(0)  # ← コピー 2
```

ドメインモデルにすると、判断は 1 か所に集まる。

```python
LATE_WINDOW = timedelta(days=3)
LATE_FEE_RATE = Decimal("0.3")


@dataclass(frozen=True, kw_only=True)
class Reservation:
    price: Decimal
    starts_at: datetime
    status: ReservationStatus

    def change_fee(self, now: datetime) -> Decimal:
        if now >= self.starts_at:
            raise ReservationAlreadyStarted()
        return self.price * LATE_FEE_RATE if self.starts_at - now < LATE_WINDOW else Decimal(0)

    def cancel(self, now: datetime) -> "Reservation": ...
    def reschedule(self, new_start: datetime, now: datetime) -> "Reservation": ...
```

**判断がコピーされ始めた時点が、形を見直す時点。**

---

## 4. Django でのドメインモデルは 2 段階

Django のモデルは、行 1 つをオブジェクト 1 つで表し、保存もそのオブジェクトが行う
(Active Record)。ドメインモデルをどこまで ORM から離すかで 2 段階ある。

| | 軽量版: Django モデルに振る舞いを持たせる | 本格版: ORM から分離する |
| --- | --- | --- |
| 形 | `ReservationModel.cancel(now)` | `Reservation`(dataclass)+ リポジトリ + 変換 |
| 永続化の形 | Django モデルそのもの(Active Record) | リポジトリ実装が ORM と相互変換(Data Mapper) |
| 向く | オブジェクトの形がテーブルの形とほぼ同じ | 値オブジェクト・状態ごとの型など、**テーブルの形とずれる** |
| テスト | DB が要る | **DB なしで回る** |
| 追加コスト | ほぼなし | 変換とリポジトリの維持 |
| 設計の指針 | 下の 3 つのルール | [ddd-domain-object-completeness](../ddd-domain-object-completeness/SKILL.md) / [ddd-aggregate-repository-boundary](../ddd-aggregate-repository-boundary/SKILL.md) |

**軽量版でも守る 3 つのルール。** 守っておけば、本格版へ機械的に上げられる。

1. **振る舞いのメソッドの中で `save()` を呼ばない。** 判断と状態変更だけを行い、
   保存は呼び出し側に任せる。
2. **`save()` をオーバーライドしない、signals を使わない。** 理由は
   [ddd-django-pitfalls](../ddd-django-pitfalls/SKILL.md)。
3. **フィールドを外から直接書き換えない。** `r.status = "cancelled"` ではなく
   `r.cancel(now)` を呼ぶ。

### 軽量版から本格版へ上げるサイン

- オブジェクトの形がテーブルの形からずれ始めた(値オブジェクトにしたいフィールド群、
  状態ごとに使うフィールドが違う、1 テーブルに 2 つの概念が同居)
- DB なしでテストしたい判断が増えた
- モデルのメソッドが、他のモデルを次々に import し始めた

上げる手順は [ddd-legacy-refactoring](../ddd-legacy-refactoring/SKILL.md) の第 4 節。

---

## 5. 形を切り替えるサイン

### トランザクションスクリプト → ドメインモデル

- 同じ判断(条件式・計算)が **2 つ目の操作**にコピーされた
- 複数の関数の冒頭に、同じ前提チェックが並んでいる
- ステータスによる `if` / `elif` が増え続けている
  ([ddd-state-transition](../ddd-state-transition/SKILL.md))
- バグを直すたびに「別の関数も同じように直す」が発生する
- 関数が別の業務関数を呼び、呼び出しの連鎖を追わないと結果が分からない

### ドメインモデル → トランザクションスクリプト(戻す判断)

- ドメインオブジェクトが**データを持つだけで、判断をしていない**。判断は usecase に
  ある([貧血ドメインモデル](https://martinfowler.com/bliki/AnemicDomainModel.html))。
  ドメインモデルのコストを払って、トランザクションスクリプトの利点しか得ていない。
  **判断をオブジェクトへ移すか、層をたたんで手続きに戻すかのどちらかにする。**
- 対象がコアドメインでないと分かり、ルールも増えていない。

---

## 6. 1 つのプロジェクトで使い分ける

- **形は機能(Django app・境界づけられたコンテキスト)ごとに選ぶ。** 予約はドメインモデル、
  お知らせ管理はトランザクションスクリプト、が普通にあり得る。
- **同じ概念に 2 つの形を混ぜない。** `Reservation` をドメインモデルにしたなら、
  ほかの場所で `ReservationModel.objects.filter(...).update(status=...)` と直接書き換えない。
  ドメインモデルが守っている規則を素通りする。
- 例外は**読み取りと集計**。一覧・検索・集計は、ドメインモデルを通さずに
  `QuerySet` で書いてよい([ddd-read-model-cqrs](../ddd-read-model-cqrs/SKILL.md))。
- **どの形を選んだかを残す。** app の README か CLAUDE.md に「この app はトランザクション
  スクリプト」と 1 行書けば、混在が意図的な選択だと分かる。

---

## 7. Service Layer を置くか

業務操作の入口を一か所にまとめる層(usecase / application service)。

| 状況 | 判断 |
| --- | --- |
| 入口が DRF の view だけで、ロジックが単純 | **置かない。** view から直接呼ぶ |
| 同じ操作を view・管理コマンド・Celery タスクなど複数の入口から呼ぶ | **置く** |
| トランザクションや認可を操作単位で一か所に集めたい | **置く** |
| ドメインモデル(本格版)を採った | **置く**。ドメインを組み立てる役が要る |

- トランザクションスクリプトでは、**スクリプト自体が Service Layer になる。**
  別の層を重ねない。
- ドメインモデルの上に置く場合は**薄く保つ**。書き方は
  [ddd-application-layer](../ddd-application-layer/SKILL.md)、入口ごとの分担は
  [adapter-design](../adapter-design/SKILL.md)。

---

## アンチパターン

| アンチパターン | なぜ悪いか |
| --- | --- |
| CRUD の画面にも集約・リポジトリ・usecase を一式作る | 判断がないのに、ドメインモデルのコストだけを払う |
| 複雑になると分かっている領域を手続きで始める | 後からの移行は、呼び出し元をすべて書き換える作業になる |
| データしか持たないドメインオブジェクトと、判断を全部持つ usecase | ドメインモデルの見た目をしたトランザクションスクリプト |
| 同じ概念を、ドメインモデル経由と ORM 直書きの両方で更新する | ドメインモデルが守る規則を素通りする |
| Django モデルのメソッドの中で `save()` まで呼ぶ | 判断と永続化が混ざり、本格版へ上げられない |
| 判断のコピーが増えても形を見直さない | 直し漏れが出続ける |
| 形の選択をどこにも残さない | 混在が意図的か、ただの不統一か区別できない |

---

## ルール(チェックリスト)

- [ ] 機能ごとに、**複雑さを測る問い**に答えてから形を選んだ
- [ ] CRUD の領域にドメインモデル一式を持ち込んでいない
- [ ] 複雑になると分かっている領域は、最初からドメインモデルで始めた
- [ ] トランザクションスクリプトで始めた場合、**切り替えるサイン**を決めて残した
- [ ] 軽量版のドメインモデルで、メソッド内の `save()`・`save()` のオーバーライド・
      signals・フィールドの直接書き換えがない
- [ ] ドメインオブジェクトが判断を持っている(データだけの入れ物になっていない)
- [ ] 同じ概念を 2 つの形で更新していない(読み取りと集計は除く)
- [ ] Service Layer を、複数の入口・操作単位の制御・本格版のドメインモデルの
      いずれかがある場合だけ置いた
- [ ] どの app がどの形かを README か CLAUDE.md に残した
