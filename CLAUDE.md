# AI TRPG（仮題）

ルールはコード、物語はローカルLLM（llama.cpp + Qwen3 同梱）が担う1人用TRPG。Godot 4 製、Steam向け買い切りゲーム。現在は**設計フェーズ完了・実装未着手**（Phase 0 の技術検証から始める）。

## ドキュメント（この順で読む）

1. `docs/constitution.md` — **憲法**。不変条件（INV）とアーキテクチャ原則（ARCH）。すべてに優先する
2. `docs/仕様書.md` — プロダクト仕様（ゲームデザイン・判定ルール詳細は付録A）
3. `docs/実装仕様書.md` — 実装仕様。ディレクトリ構成、インターフェース、スキーマ、テストベクタ、PR単位の実装計画（§12）と受け入れ基準

## 作業開始時の手順

実装は **PR 単位**で進める（実装仕様書 §12 が作業キュー。ブランチ名・成果物・受け入れ条件・テストがPRごとに定義済み）。

1. `docs/実装仕様書.md` 冒頭の「実装状況」で次の PR を確認
2. `git log --oneline -10` で直近の作業を確認
3. §12 の該当 PR の受け入れ条件・テストケースに従って実装（`pr/NN-名前` ブランチ）
4. `bash tools/checks.sh` が exit 0 になったら、実装仕様書の「実装状況」を更新し、main へマージして push（GitHub PR は任意。マージコミットに受け入れ条件のチェックリストを記載。詳細は実装仕様書 §12.0）

## コマンド（PR-00 完了後に有効）

```bash
bash tools/setup.sh          # Godot と GUT を取得（冪等）
bash tools/checks.sh         # マージゲート: 全テスト＋依存規則チェック
bash tools/check_deps.sh     # core→ai/ui 依存禁止の静的チェックのみ
"$GODOT_BIN" --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit   # 全テスト
```

## 絶対に守ること（詳細は constitution.md）

- AIはゲーム状態を変更しない。乱数・判定・状態更新はすべてコード側（INV-1/2）
- AIの出力は閉じた語彙（GBNF＋コード再検証）を通してのみゲームロジックに入る（INV-3）
- 更新順序は「判定確定 → 状態更新 → 保存 → AI描写生成」。逆転禁止（INV-6）
- `game/core/` から `game/ai/` `game/ui/` への依存は禁止（ARCH-1）
- デフォルト完全オフライン。テレメトリ送信コードを書かない（INV-4）

## 規約

- ドキュメント・コミットメッセージ・UI文字列は日本語
- GDScript は型注釈必須、ユーザー向け文字列は `tr()` 経由
- `game/core/` の変更には対応する GUT テストを必ず追加
