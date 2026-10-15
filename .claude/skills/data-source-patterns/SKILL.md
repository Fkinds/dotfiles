---
name: data-source-patterns
description: DB を読み書きするコード(データソース層)の形を選び、オブジェクトとテーブルを対応づける指針。Django モデルをそのままドメインとして使うか(Active Record)、ドメインオブジェクトと分けてリポジトリで変換するか(Data Mapper)決めるとき、ORM の呼び出しが view や serializer に散らばってきたとき、値オブジェクトや子の集まり・状態ごとの型をテーブルにどう保存するか迷うとき、admin や ModelSerializer がドメインの規則を素通りしていないか確かめるときに使う。扱う範囲は Table Data Gateway / Row Data Gateway / Active Record / Data Mapper の違いと選び方、トランザクションスクリプトでのクエリの集め方、Data Mapper での対応づけ(列への展開・JSON 列・子テーブル・継承)、Django の道具との付き合い方、生 SQL の置き場所。
---

# データソース層の設計 (Data Source Patterns)

**DB を読み書きするコードをどこに置き、どの形にするか。** 業務ロジックの形
([domain-logic-patterns](../domain-logic-patterns/SKILL.md))と対で決める。

出典は Martin Fowler『Patterns of Enterprise Application Architecture』の
Data Source Architectural Patterns と Object-Relational Structural Patterns。
各パターンの要約は[著者のカタログ](https://martinfowler.com/eaaCatalog/)にある。

関連スキル:

- リポジトリの契約(集約単位・取得と保存だけ)、復元時の不変条件 → [ddd-aggregate-repository-boundary](../ddd-aggregate-repository-boundary/SKILL.md)
- 一覧・検索・集計の置き場所 → [ddd-read-model-cqrs](../ddd-read-model-cqrs/SKILL.md)
- signals・`save()` のオーバーライド・遅延読み込みなど ORM の落とし穴 → [ddd-django-pitfalls](../ddd-django-pitfalls/SKILL.md)
- マッピングの往復テスト → [ddd-testing-strategy](../ddd-testing-strategy/SKILL.md)

---

## 1. 4 つの形

| 形 | DB を触るもの | 業務ロジック | Django での姿 |
| --- | --- | --- | --- |
| **Table Data Gateway** | テーブルごとの窓口。行の集合を返す | 持たない(呼び出し側にある) | app ごとのクエリ関数のモジュール |
| **Row Data Gateway** | 行ごとのオブジェクト。読み書きだけ | 持たない | メソッドを持たない Django モデル |
| **Active Record** | 行ごとのオブジェクト。読み書きと業務ロジックの両方 | 持つ | 振る舞いのメソッドを持つ Django モデル |
| **Data Mapper** | 変換役。ドメインオブジェクトは DB を知らない | ドメインオブジェクトが持つ | リポジトリ実装 + dataclass |

Django ではモデルを書いた時点で Row Data Gateway と Active Record が手に入る。
だから実際に決めるのは次の 3 つ。

1. 業務ロジックを Django モデルに載せるか(Active Record にするか)
2. Django モデルの手前に変換役を挟むか(Data Mapper にするか)
3. クエリの組み立てをどこに集めるか

---

## 2. 業務ロジックの形と組み合わせる

| 業務ロジックの形 | データソースの形 |
| --- | --- |
| トランザクションスクリプト | クエリ関数のモジュール(Table Data Gateway)+ メソッドを持たないモデル |
| ドメインモデル(軽量版) | Active Record |
| ドメインモデル(本格版) | Data Mapper |

組み合わせがずれているサイン:

- **Data Mapper なのに、ドメインオブジェクトが判断を持っていない。** 変換のコストだけを
  払っている。判断をオブジェクトへ移すか、トランザクションスクリプトに戻す。
- **Active Record なのに、モデルのメソッドが他のテーブルを次々に引く。** オブジェクトの
  形がテーブルからずれ始めている。Data Mapper へ移る時期。

---

## 3. Active Record か Data Mapper か — 永続化の側から見た基準

業務ルールの複雑さによる判断は [domain-logic-patterns](../domain-logic-patterns/SKILL.md)。
ここでは**永続化の事情**で判断を補う。

| 問い | Active Record に傾く | Data Mapper に傾く |
| --- | --- | --- |
| スキーマを決めるのは誰か | このアプリ。オブジェクトに合わせて変えられる | 既存 DB・他システムと共有・レガシーで**変えられない** |
| オブジェクトとテーブルの形 | 1 行 = 1 オブジェクト | 値オブジェクト・子の集まり・状態ごとの型で**ずれる** |
| Django の道具(admin・ModelForm・ModelSerializer) | 書き込みにも使いたい | 書き込みには使わないと決められる(第 6 節) |
| DB なしでテストしたい判断 | 少ない | 多い |
| 読み書き先 | DB だけ | 外部 API・別 DB と組み合わせて 1 つのオブジェクトを作る |

- **スキーマを変えられないなら、ほかが Active Record 寄りでも Data Mapper にする。**
  Active Record ではオブジェクトの形がテーブルの形に縛られ、ドメインの言葉で書けない。
- **第 6 節の道具を書き込みに使い続けるなら、Active Record のままにする。** Data Mapper に
  しても、道具が規則を素通りすれば守れるものがない。
- 切り替えは**集約ごと**でよい。app 全体を一度に移さない。ただし同じ概念を 2 つの経路で
  書き込まない([domain-logic-patterns](../domain-logic-patterns/SKILL.md) 第 6 節)。

---

## 4. トランザクションスクリプトでは、クエリを 1 か所に集める

ORM のチェーン(`filter` / `select_related` / `annotate`)が view・serializer・
Celery タスクに散らばると、同じ絞り込み条件がコピーされ、N+1 の対策も散らばる。
**クエリの組み立ては app ごとのモジュールに集め、呼び出し側は関数を呼ぶだけにする。**

```python
# loans/queries.py — loans テーブルへの問い合わせはここに集める
def active_loans_of(borrower_id: int) -> list[LoanModel]:
    return list(LoanModel.objects.filter(borrower_id=borrower_id, returned_at__isnull=True))


def overdue_loans(today: date) -> list[LoanModel]:
    return list(
        LoanModel.objects.filter(returned_at__isnull=True, due_date__lt=today)
        .select_related("item", "borrower")
    )
```

- **`QuerySet` ではなく評価済みの結果を返す。** `QuerySet` を返すと呼び出し側が `filter` を
  継ぎ足し、散らばりが戻る。条件が足りなければ関数を足す。ページングなど遅延評価が
  必要な場合だけ `QuerySet` を返し、継ぎ足しはしないと決めておく。
- **書き込みはスクリプト(`services.py` の関数)に置き、クエリ関数には置かない。**
  クエリ関数は読むだけ。
- **他の app のテーブルは、その app のクエリ関数を通して読む。** 直接 `filter` しない。
- 後でドメインモデルへ移ったら、「延滞とは何か」のような判断はドメインオブジェクトへ移り、
  一覧の絞り込みは query service へ移る
  ([ddd-django-pitfalls](../ddd-django-pitfalls/SKILL.md) 第 3 節、
  [ddd-read-model-cqrs](../ddd-read-model-cqrs/SKILL.md))。

---

## 5. Data Mapper での対応づけ

変換はリポジトリ実装の中に、**手書きの関数 2 本**(行 → ドメイン、ドメイン → 行)で書く。
汎用の自動マッパーは作らない。対応の規則がコードから見えなくなる。

| ドメイン側 | 既定の対応 | 別の対応と、それを選ぶ条件 |
| --- | --- | --- |
| 値オブジェクト(金額・期間・住所) | **同じテーブルの列に展開**(`total_amount` / `total_currency`) | 中身で検索・集計せず、形が変わりやすい → **JSON 列** |
| 任意の値オブジェクト | 構成列をすべて NULL 許容。全部 NULL ↔ `None` | 一部だけ NULL の行は壊れたデータとして復元で落とす |
| 子の集まり(注文明細) | **子テーブル + 親への外部キー** | — |
| 子の保存 | **全部消して入れ直す** | 子の行が外から参照される・件数が多い → **差分で更新** |
| 状態・種別 | 文字列の値の列([ddd-state-transition](../ddd-state-transition/SKILL.md) 第 6 節) | — |
| 状態ごとに型が違う | **1 テーブル + 状態の列**。状態ごとの列は NULL 許容にし、DB の制約で組み合わせを守る | 型ごとに列がほとんど重ならない → 型ごとのテーブル(抽象基底) |
| 識別子 | [ddd-modeling-primitives](../ddd-modeling-primitives/SKILL.md) | — |

- **マルチテーブル継承は使わない**(理由は [solid-principles](../solid-principles/SKILL.md))。
  ドメイン側の型の分け方を、テーブル継承に写さない。
- **JSON 列には形のバージョンを入れる。** 中身の形の変更は migration に現れないので、
  復元側が古い形を読み替える。
- **復元は通常のコンストラクタを通す**
  ([ddd-aggregate-repository-boundary](../ddd-aggregate-repository-boundary/SKILL.md) 第 8 節)。

それぞれの実装例(列への展開、JSON 列のバージョン、子の全置換と差分更新、状態ごとの型と
DB 制約)は [mapping.md](mapping.md)。リポジトリ実装を書くときに読む。

---

## 6. Data Mapper にすると、Django の道具が規則を素通りする

Django の道具の多くは**永続化モデルへ直接書き込む**。Data Mapper にした集約では、
ドメインオブジェクトを通らない書き込みの経路になる。

| 道具 | 起きること | 方針 |
| --- | --- | --- |
| admin | 管理画面から行を直接書き換える | **読み取り専用にする。** 書き換えが要る操作は admin action から usecase を呼ぶ |
| ModelForm / ModelSerializer の `save()` | 入力をそのまま行へ保存する | **入力の検証と変換にだけ使う。** 保存は usecase |
| `QuerySet.update()` / `bulk_create` / `bulk_update` | ドメインを通らない一括書き込み | **リポジトリ実装の中と移行スクリプトに限る** |
| データ migration(`RunPython`) | 行を直接書き換える | ドメインの規則に反する値を作らない。作ると復元で落ちる |
| テストの fixture・factory | 不正な組み合わせの行を作れる | テストデータはドメインの生成経路から作る([ddd-testing-strategy](../ddd-testing-strategy/SKILL.md)) |

**これらを書き込みに使うのをやめられないなら、その集約は Active Record のままにする**(第 3 節)。

---

## 7. 生 SQL を書く場所

ORM で書きにくいもの(ウィンドウ関数・再帰 CTE・一括 upsert・DB 固有の機能)は、
生 SQL で書いてよい。

- **置き場所**: 読み取りなら query service
  ([ddd-read-model-cqrs](../ddd-read-model-cqrs/SKILL.md))、書き込みならリポジトリ実装か
  クエリ関数のモジュール。**view や usecase に SQL を書かない。**
- **戻り値は dataclass に詰めて返す。** カーソルが返す tuple を外に出さない。列の順序に
  呼び出し側が依存する。
- **値は必ずプレースホルダで渡す**(`cursor.execute(sql, params)`)。文字列を連結しない。

---

## アンチパターン

| アンチパターン | なぜ悪いか |
| --- | --- |
| view・serializer・タスクがそれぞれ ORM のチェーンを組み立てる | 同じ条件がコピーされ、N+1 の対策も散らばる |
| クエリ関数が `QuerySet` を返し、呼び出し側が `filter` を継ぎ足す | 集めたはずのクエリが再び散らばる |
| 判断を持たないドメインオブジェクトのために Data Mapper を作る | 変換のコストだけを払う |
| 変えられないスキーマに Active Record で合わせる | オブジェクトがテーブルの形に縛られ、業務の言葉で書けない |
| Data Mapper にしたのに admin や ModelSerializer で書き込む | ドメインの規則を素通りする経路が残る |
| 汎用の自動マッパーを作る | 対応の規則が見えず、例外の扱いで壊れる |
| ドメインの型の分け方をマルチテーブル継承に写す | 暗黙の JOIN と、置き換えのきかない継承が残る |
| JSON 列の形を変えても復元側を直さない | 古い行が読めなくなる。migration にも現れない |
| view や usecase に生 SQL を書く | DB の形が業務の層に漏れる |

---

## ルール(チェックリスト)

- [ ] 業務ロジックの形と、データソースの形の組み合わせがずれていない(第 2 節)
- [ ] スキーマを変えられない集約は Data Mapper にした
- [ ] トランザクションスクリプトでは、クエリの組み立てが app ごとのモジュールに集まっている
- [ ] クエリ関数は評価済みの結果を返し、呼び出し側で `filter` を継ぎ足していない
- [ ] Data Mapper の変換が、リポジトリ実装の中の手書きの関数 2 本にまとまっている
- [ ] 値オブジェクトは列に展開し、JSON 列は「中身で検索しない」ものだけに使っている
- [ ] JSON 列に形のバージョンがあり、復元側が古い形を読み替える
- [ ] マルチテーブル継承を使っていない
- [ ] Data Mapper の集約に対して、admin・ModelForm・ModelSerializer が書き込んでいない
- [ ] `update()` / `bulk_create` / `bulk_update` がリポジトリ実装と移行スクリプトの外にない
- [ ] 生 SQL が query service・リポジトリ実装・クエリ関数の外になく、値をプレースホルダで渡している
