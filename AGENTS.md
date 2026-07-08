# AGENTS.md — AI TRPG（仮題）

**まず [CLAUDE.md](CLAUDE.md) を読むこと。** 本ファイルは Codex 等の AGENTS.md 慣習のエージェント向け入口で、内容は CLAUDE.md と同一の規約を指す。

## 要点（詳細は CLAUDE.md とリンク先）

- ドキュメントの読み順: `docs/constitution.md`（憲法・最優先）→ `docs/仕様書.md` → `docs/実装仕様書.md`
- 実装は **PR単位の作業キュー**（実装仕様書 §12）を上から消化する。次の作業は実装仕様書冒頭の「実装状況」に書いてある
- 作業ブランチは `pr/NN-名前`。マージゲートは `bash tools/checks.sh`（exit 0 必須）
- 絶対規則: AIはゲーム状態を変更しない（INV-1）/ 乱数・判定はコード側（INV-2）/ AI出力は閉じた語彙＋コード検証経由のみ（INV-3）/ 「判定確定→状態更新→保存→描写生成」の順序厳守（INV-6）/ `game/core/` から `game/ai/` `game/ui/` への依存禁止（ARCH-1）
- ドキュメント・コミットメッセージ・UI文字列は日本語。GDScript は型注釈必須
