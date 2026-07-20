# 2エージェント・クロスレビュー定石 (v2)

**構成:** Main = Claude Code + Opus 4.8(reviewer#1 + 統合 + 決定/パッチ) ／ Sub = GLM-5.2 via OpenCode Zen(独立 reviewer#2、反対意見レンズ上乗せ)

**主軸:** モデルを増やすより、**入力・役割・出力・採否を固定する**。価値は2体の**不一致**にある — 平均化して消さない。

> severity・category の正は `rubric.md`、実行フローは `SKILL.md`、本書は方法論。チェックリストは再掲しない(二重管理を避ける)。

---

## A. 入力を固定する

### 1. レビューパケットを先に作る(Claude Code が生成)
`gather_artifact.sh` が機械項目(変更ファイル/diff・doc/テスト結果)を埋め、著者項目は Claude が記入してからレビュアーへ渡す。

```
- 背景
- 目的
- 非目的(non-goals)        ← 最重要。範囲外指摘を防ぐ
- 主要な設計判断
- 既知の不安点              ← 最重要。照準を合わせる
- 変更ファイル / diff or commit hash(PR)/ doc v1(設計)
- テスト結果
- レビューしてほしい観点
```

**full / minimal の2段**(→ G)。minimal でも **目的・非目的・diff・テスト結果は残す**(完全省略しない)。

---

## B. 役割と順序(2体版)

### 2. 最初のレビューは独立・ブラインド、そして独立性のスコープを意識する
先に片方の指摘を見せると引っ張られて多様性が死ぬ。

```
Claude Code : 成果物作成 → パケット化
GLM-5.2     : independent external review(ブラインド)
Claude Code : author-aware self-review(自分の所見を先にディスクへ)
              ── ここまで GLM の出力は見ない ──
Claude Code : 統合・採否判断 → (修正後) delta-review(→ E)
```

**Claude reviewer#1 は完全な独立レビューではない**(作成意図を知っており、自己正当化バイアスが残る)。対策:
- 本筋は **subagent 隔離** — Claude のレビューを、作成意図を持たない新コンテキスト/サブエージェントに投げる。
- 割り引くなら **設計・アーキテクチャ系の対立に限定**。correctness の対立では作成者知識はむしろ資産なので一律には下げない。

### 3. 役割は重ねないがハード分離もしない
Sub は1体。トピック2分割はできないので:
- **GLM-5.2**: フルレビュー + 「**反対意見・代替設計・隠れた前提**」レンズ上乗せ(別ラボの価値が最も出る所)。
- **Claude Code**: フルレビュー(reviewer#1)+ 統合 + トレードオフ判断 + 最終パッチ。

「security だけ見ろ」と禁止しない。主担当で強弱はつけ、**領域外の発見も必ず挙げさせる**(隙間と黙殺を防ぐ)。

---

## C. 出力を固定する

### 4. finding フォーマットを固定(`findings.schema.json` 準拠)

```
ID:           G-001 / C-001(レビュアー接頭辞。統合時に Claude が F-### を再採番)
Severity:     critical / high / medium / low
Category:     rubric.md / schema の enum 参照
Location:     file:line(diff)/ section(設計)
Issue:
Evidence:     根拠(diff行・該当仕様・観測挙動)— 幻覚レビュー対策
Failure case: いつ顕在化するか(入力・順序・負荷)
Suggested fix:
Confidence:   high / medium / low
Speculative:  yes / no
```

**Evidence は critical/high と correctness/security で必須**、critical/high は Failure case も必須(schema が強制)。nit は任意。

### 5. 規律プロンプト(両レビュアー共通)
```
Do not summarize first.
Start with findings ordered by severity.
Only include issues affecting correctness, security, maintainability, or operability.
Avoid style-only comments unless they create real maintenance risk.
```

### 6. confidence は「並び替え」用、「足切り」用ではない
AI の自信度は較正が悪い。処理順は `high severity × high confidence` から。ただし **low confidence × high severity は捨てず必ず人間へ**(本物の blocker をモデルが渋るケース)。投機は `Speculative: yes` で明示。

---

## D. 採否を判断する(品質の肝)

### 7. 対立は隔離する。ただし全部は人間に回さない
2体が同じ箇所で逆判断した点は単独指摘より高信号。**人間エスカレーションは条件付き**:

```
人間へ:
- high 以上で判断が割れた
- security / data loss / migration / public API に関わる
- 片方 reject、片方 must fix
- low confidence でも high severity
それ以外の低リスク対立:
- Claude が暫定判断し、サマリに「対立あり/暫定採否」を残すだけ
```

### 8. disposition と Finding ID ライフサイクル
統合時に Claude が各指摘へ canonical **F-###** を割り当て、分類する。

```
F-001  high / correctness   → must fix
F-002  medium / maintainab. → defer
F-003  high / design        → escalate(対立)
```

```
must fix / should fix / defer / reject
```
`reject` には理由。例: `Reject(F-007): 正しいが本PRの非目的。既存制約の変更が要るため別issue化。`
これで「多数決」が「設計判断」になる。

---

## E. 修正と再レビュー(2体版)

### 9. delta-review — 修正 diff だけ、対応 ID 付きで
全体再レビューは不要。修正後に見るべきは設計全体でなく **diff の正しさ**。

```
通常        : Claude self-check(修正 diff を must-fix の F-ID と照合)
高リスク    : GLM delta-review … 修正 diff + 「検証すべき must-fix の F-ID」を渡し、
              (a) 当該指摘が解消したか (b) 退行が出ていないか の2点だけ見させる
重大設計変更: 新セッションの GLM に修正 diff をレビューさせる(独立性回復)
```

高リスク = security / data loss / migration / public API。GLM に全体を見せ直さないのでコストも低い。

---

## F. 人間に渡す

### 10. 意思決定資料としてのサマリ(F-ID で追跡)
```
- 採用(F-001 fixed, F-004 fixed …)
- 却下(F-007 rejected — 理由)
- エスカレーション(F-003 escalated to human)
- 修正内容
- 残リスク
- テスト結果 / delta-review 結果
- 人間に見てほしいポイント(対立点を含む)
```

---

## G. stakes で段階化する(effort-routing)

| | lite(日常 PR) | full(重要設計 / 高リスク PR) |
|---|---|---|
| パケット(A) | **minimal**(目的・非目的・diff・テスト結果) | full |
| 独立レビュー(B) | GLM 1パス + Claude 統合 | 両者フル・ブラインド(可能なら Claude は subagent) |
| disposition(D) | must fix のみ | 全分類 + reject 理由 + 対立隔離 |
| 再レビュー(E) | Claude self-check | delta-review(高リスクは GLM、重大は新セッション) |
| 人間サマリ(F) | 簡略 | フル(F-ID 追跡) |
| **GLM effort** | **High** | **Max** |
| **深掘り Claude** | medium | high / max |

`small_model`(タイトル生成等)は常に minimal。深掘りパスにだけ高 effort を使う。

---

## 推奨フロー(full)

```
パケット化(著者項目を Claude が記入)
→ Claude author-aware self-review を先に保存(可能なら subagent)
→ GLM independent review(ブラインド)
→ findings を F-ID 付きで統合
→ high-risk conflict を隔離(→人間)
→ disposition(must / should / defer / reject)
→ must fix だけ修正
→ Claude self-check
→ high-risk(security / public API / data migration)だけ GLM delta-review
→ 人間用サマリ(残リスク・対立点・F-ID 追跡)
```

---

## v2 で取り込んだフィードバック

1. **Evidence + Failure case** を finding に追加(critical/high と correctness/security は必須、nit は任意)。schema で強制。
2. **Finding ID** を導入(レビュアー接頭辞 G-/C- → 統合で F-### 再採番)。修正・再レビュー・サマリを ID で追跡。
3. **lite でも minimal packet 必須**(完全省略をやめた)。
4. **対立のエスカレーションを条件化**(全件人間をやめ、high以上/security等/reject対must fix/low-conf×high-sev に限定)。
5. **delta-review**(修正 diff + must-fix ID だけ、高リスク時に GLM、重大時に新セッション)。
6. **独立性のスコープ化**(Claude self-review の割引は設計対立に限定、correctness は下げない。本筋は subagent 隔離)。
7. severity を **critical/high/medium/low** に統一(schema/rubric/SKILL と一致)。
