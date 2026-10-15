# ウィザードと下書きの実装例

[SKILL.md](SKILL.md) 第 3 節・第 7 節の実装例。ウィザード・下書き・入力の自動保存を
実装するときに読む。

---

## 1. ウィザードをクライアントに持たせる

状態はクライアント(React の state)が全ステップ分を持つ。サーバーは**ステップごとの検証**と
**最後の確定**だけを受け持ち、途中の状態を保存しない。

```python
# ステップごとの検証。保存はしない
class ValidateApplicationStepView(APIView):
    STEP_SERIALIZERS = {"applicant": ApplicantStepSerializer, "plan": PlanStepSerializer}

    def post(self, request, step: str):
        serializer_class = self.STEP_SERIALIZERS.get(step)
        if serializer_class is None:
            raise NotFound()
        serializer_class(data=request.data).is_valid(raise_exception=True)
        return Response(status=204)


# 確定。全ステップの入力を 1 回で受け取り、最初から全部検証し直す
class SubmitApplicationView(APIView):
    def post(self, request):
        serializer = SubmitApplicationSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        output = self.submit_application.execute(SubmitApplicationCommand(**serializer.validated_data))
        return Response(ApplicationSerializer(output).data, status=201)
```

- **確定時に、途中のステップで通った検証を信用しない。** クライアントは途中の値を
  書き換えられる。確定のシリアライザと usecase で全部やり直す。
- 料金のように**サーバーが決める値**は、ステップの検証で計算して見せてもよいが、
  確定時に計算し直す。クライアントから受け取らない。
- 二重送信の対策は [api-reliability](../api-reliability/SKILL.md) の Idempotency-Key。

---

## 2. 下書きを業務の状態にする — 型を分ける

下書きは項目が欠けていてよい。提出済みは全部の規則を満たす。**同じ型で両方を表さない。**

```python
@dataclass(frozen=True, kw_only=True)
class ApplicationDraft:
    id: ApplicationId
    owner: UserId
    plan: PlanCode | None = None           # 下書きでは未入力を許す
    start_date: date | None = None
    updated_at: datetime

    def submit(self, now: datetime) -> "SubmittedApplication":
        missing = [name for name in ("plan", "start_date") if getattr(self, name) is None]
        if missing:
            raise DraftIncomplete(missing)
        return SubmittedApplication(                 # ここで本体の不変条件がすべて検査される
            id=self.id, owner=self.owner, plan=self.plan, start_date=self.start_date, submitted_at=now,
        )


@dataclass(frozen=True, kw_only=True)
class SubmittedApplication:
    id: ApplicationId
    owner: UserId
    plan: PlanCode                           # 必須
    start_date: date
    submitted_at: datetime

    def __post_init__(self) -> None:
        if self.start_date < self.submitted_at.date():
            raise ValueError("開始日は提出日以降")
```

- テーブルは 1 つでよい。状態の列で型を選んで復元する
  ([data-source-patterns](../data-source-patterns/SKILL.md) の mapping.md 第 4 節)。
- 下書きの段階でも検査したい規則(形式が明らかに不正な値)は、値オブジェクトの側で守る。
  欠けていることだけを許す。
- 放置された下書きの扱い(30 日で取り下げ、など)は業務の規則として集約に持たせる。

---

## 3. 途中状態の表 — まだ業務の概念でないもの

本人が続きをするためだけの入力。業務の集約にはせず、入力をそのまま保存する。

```python
class CheckoutDraftModel(models.Model):
    owner_key = models.CharField(max_length=64, db_index=True)   # ユーザー ID か、匿名の ID
    payload = models.JSONField()                                 # {"v": 1, ...}
    expires_at = models.DateTimeField(db_index=True)
    updated_at = models.DateTimeField()
```

```python
# management/commands/purge_expired_drafts.py — 定期実行する
class Command(BaseCommand):
    def handle(self, *args, **options):
        now = timezone.now()
        while True:
            ids = list(CheckoutDraftModel.objects.filter(expires_at__lt=now).values_list("pk", flat=True)[:1000])
            if not ids:
                break
            CheckoutDraftModel.objects.filter(pk__in=ids).delete()   # 一度に大量に消さず、小分けにする
```

- 保存のたびに `expires_at` を延ばす。「最後に触ってから 7 日」のように決める。
- 匿名の ID は推測できない値にする(`secrets.token_urlsafe`)。他人の下書きを読めないように。
- ログインしたら、匿名の ID の下書きをユーザーに付け替える。同じ人の下書きが両方にあるなら、
  どちらを残すかを決めておく(新しいほう、など)。
- 確定するときは payload から集約を作る。**この時点で初めて業務の規則を通す。**

---

## 4. 入力を localStorage に自動保存する

同じ端末で、うっかり閉じた入力を取り戻すため。端末をまたぐ必要があるなら第 2 節か第 3 節。

```typescript
const KEY = "quote-form:v2";   // 形を変えたらバージョンを上げる

type SavedForm = { v: 2; savedAt: string; values: QuoteFormValues };

export function loadSavedForm(): QuoteFormValues | null {
  try {
    const raw = localStorage.getItem(KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as Partial<SavedForm>;
    if (parsed.v !== 2 || !parsed.values) return null;   // 古い形は捨てる
    return parsed.values;
  } catch {
    return null;   // 壊れた値・ストレージが使えない環境では、保存がなかったものとして扱う
  }
}

export function saveForm(values: QuoteFormValues): void {
  try {
    localStorage.setItem(KEY, JSON.stringify({ v: 2, savedAt: new Date().toISOString(), values }));
  } catch {
    // 容量超過・プライベートブラウズ。保存できなくても入力は続けられる
  }
}
```

- 入力のたびに保存せず、少し間を置いてまとめて保存する(debounce)。
- **送信に成功したら消す。** 残すと、次に開いたときに送信済みの内容が復元される。
- パスワード・カード番号・個人情報の項目は保存の対象から外す(SKILL.md 第 4 節)。
- 古いキー(`quote-form:v1`)は読み込み時に削除して、端末に残し続けない。
