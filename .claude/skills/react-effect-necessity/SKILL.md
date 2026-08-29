---
name: react-effect-necessity
description: その useEffect が本当に要るかを判断する決定木。useEffect を書こうとしているとき、Effect が増えて追えなくなったとき、state が一拍遅れて同期するとき、Effect が無限ループするとき、props の変更に合わせて state を作り直したいときに使う。扱う範囲は「外部システムと同期しているか」から始まる 6 分岐の決定木、分岐ごとの行き先(レンダリング中の計算・イベントハンドラ・useMemo・key によるリセット・useSyncExternalStore)、Effect を使ってよい場合の見分け、疑わしい Effect を機械的に洗い出す方法。
---

# React: その useEffect は要らない

**Effect を書く前に、必ずこの木を通す。** 出典は
[You Might Not Need an Effect](https://react.dev/learn/you-might-not-need-an-effect)。

各分岐の**実装の詳細は書かない** — 外部スキル `react-best-practices` が持っている。
ここが持つのは**入口の判断**と、外部にない 2 つの分岐だけ。

## 決定木

```
その Effect は「外部システム」と同期している?
│  外部システム = React の外にあるもの。DOM API、ブラウザイベント、
│  WebSocket、タイマー、サードパーティ製ウィジェット、ネットワーク
│
├─ はい → Effect でよい(下の「Effect を使ってよい場合」へ)
│
└─ いいえ → 要らない。以下のどれか
   │
   ├─ props / state からデータを変換している
   │    → レンダリング中に計算する
   │
   ├─ ユーザー操作に反応している(送信・クリック・入力)
   │    → イベントハンドラに移す
   │
   ├─ 計算が本当に重い(実測した)
   │    → useMemo
   │
   ├─ props が変わったら state を作り直したい
   │    → key を渡してコンポーネントごと作り直す
   │
   └─ React の外のストアを購読している
        → useSyncExternalStore
```

## 分岐ごとの行き先

| 分岐 | 対処 | 詳細 |
| --- | --- | --- |
| データ変換 | レンダリング中に計算 | `react-best-practices` の `rerender-derived-state-no-effect` / `rerender-derived-state` |
| ユーザー操作 | イベントハンドラ | 同 `rerender-move-effect-to-event` |
| 重い計算 | `useMemo` | 同 `rerender-memo` / `rerender-simple-expression-in-memo` |
| **state のリセット** | **`key`** | **下記**(外部スキルにない) |
| **外部ストア購読** | **`useSyncExternalStore`** | **下記**(外部スキルにない) |

## props が変わったら state をリセットする → `key`

Effect で「props が変わったら setState する」と、**一度古い値で描画してから再描画**される。
一拍遅れて見えるのはこれ。

```jsx
// NG: 描画 → Effect → 再描画。userId が変わった直後は前のユーザーの comment が出る
function Profile({ userId }) {
  const [comment, setComment] = useState('');
  useEffect(() => { setComment(''); }, [userId]);

// OK: key が変わるとコンポーネントが作り直され、state は初期値から始まる
function ProfilePage({ userId }) {
  return <Profile key={userId} userId={userId} />;
}
function Profile({ userId }) {
  const [comment, setComment] = useState('');   // userId ごとに独立
```

- **リセットしたい state を持つコンポーネントの親で `key` を渡す。** 自分自身に
  `key` は付けられない。
- **一部の state だけ調整したい**場合は、レンダリング中に `setState` を呼ぶ形もある
  (React が再帰的に即再描画するので Effect より速い)。ただし読みにくいので、
  まず `key` で作り直せないかを先に検討する。

## 外部ストアを購読する → `useSyncExternalStore`

`window` のイベントや外部ライブラリのストアを Effect で購読して state に写すと、
**Concurrent Rendering で表示が裂ける**(tearing)。専用のフックがある。

```jsx
// NG: 購読して state に写す
const [isOnline, setIsOnline] = useState(true);
useEffect(() => {
  const on = () => setIsOnline(true), off = () => setIsOnline(false);
  window.addEventListener('online', on);
  window.addEventListener('offline', off);
  return () => { /* ... */ };
}, []);

// OK
const isOnline = useSyncExternalStore(
  (cb) => {                                    // 購読。戻り値は解除関数
    window.addEventListener('online', cb);
    window.addEventListener('offline', cb);
    return () => {
      window.removeEventListener('online', cb);
      window.removeEventListener('offline', cb);
    };
  },
  () => navigator.onLine,                      // クライアントでの現在値
  () => true,                                  // サーバでの値(SSR 時)
);
```

**第 3 引数を省略すると SSR で落ちる。** サーバには `navigator` がない。

## Effect を使ってよい場合

「外界と繋ぐ」ものだけ。判断に迷ったら **「React を消してもこの処理は要るか」** を問う。
要るなら外部システムとの同期。

- DOM を直接操作する(フォーカス、スクロール位置、measure)
- `window` / `document` のイベント購読(ただし上記の `useSyncExternalStore` を先に検討)
- タイマー、`setInterval`
- WebSocket、EventSource の接続
- サードパーティ製ウィジェットの初期化と破棄
- アナリティクスの送信(**ページ表示**に対して。ボタン押下ならイベントハンドラ)

データ取得は Effect でも書けるが、競合状態・キャンセル・キャッシュを自前で扱うことになる。
フレームワークの仕組み(Server Components、ルーターの loader、TanStack Query 等)がある
なら**そちらを使う**。

## 疑わしい Effect を洗い出す

`useEffect` の中で `setState` を呼んでいるものは、**ほぼ上の 5 分岐のどれか**。
まず候補を機械的に集めてから、1 つずつ木に通す。

```bash
# useEffect の中で set* を呼んでいる箇所(複数行にまたがるので -U)
# ripgrep の ts 型は .tsx も含む。--type tsx は存在しないので付けない
rg -U --type ts 'useEffect\(\s*\(\)\s*=>\s*\{[^}]*\bset[A-Z]\w*\(' src/ -n

# 依存配列が空でない Effect(props/state に反応している)
rg -U --type ts 'useEffect\([\s\S]*?\},\s*\[[^\]]+\]\)' src/ -c
```

**これは候補を挙げるだけで、判定はしない。** 外部システムとの同期でも `setState` は
呼ぶ(接続状態を state に持つなど)。木に通すのは人(または Claude)の仕事。
