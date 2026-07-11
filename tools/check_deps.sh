#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly CORE_DIR="${REPO_ROOT}/game/core"
readonly AI_DIR="${REPO_ROOT}/game/ai"
readonly UI_DIR="${REPO_ROOT}/game/ui"

# 検査対象が存在しないままチェックが黙って成功しないよう、必須ディレクトリを先に確認する。
for required_dir in "${CORE_DIR}" "${AI_DIR}" "${UI_DIR}"; do
    if [[ ! -d "${required_dir}" ]]; then
        printf '依存規則チェック: 必須ディレクトリがありません: %s\n' "${required_dir}" >&2
        exit 1
    fi
done

declare -a core_files=()
while IFS= read -r -d '' core_file; do
    core_files+=("${core_file}")
done < <(find "${CORE_DIR}" -type f -name '*.gd' -print0)

# GDScript の行からコメントを除去し「行番号:内容」で出力する。
# mode=text: 文字列リテラルは残す（パス参照の検査用）
# mode=code: 文字列リテラルも除去する（コメント・文字列内のクラス名を誤検出しないため）
strip_gd_lines() {
    local file="$1"
    local mode="$2"

    awk -v mode="${mode}" -v sq="'" '
    {
        line = $0
        out = ""
        in_string = 0
        quote = ""
        for (i = 1; i <= length(line); i++) {
            c = substr(line, i, 1)
            if (in_string) {
                if (c == "\\") {
                    if (mode == "text") out = out c substr(line, i + 1, 1)
                    i++
                    continue
                }
                if (c == quote) {
                    in_string = 0
                    if (mode == "text") out = out c
                } else if (mode == "text") {
                    out = out c
                }
                continue
            }
            if (c == "\"" || c == sq) {
                in_string = 1
                quote = c
                if (mode == "text") out = out c
                continue
            }
            if (c == "#") break
            out = out c
        }
        printf "%d:%s\n", NR, out
    }' "${file}"
}

declare -a violations=()

collect_matches() {
    local pattern="$1"
    local mode="$2"
    local core_file="" match=""

    for core_file in "${core_files[@]}"; do
        while IFS= read -r match; do
            if [[ -n "${match}" ]]; then
                violations+=("${core_file}:${match}")
            fi
        done < <(strip_gd_lines "${core_file}" "${mode}" | grep -E "${pattern}" || true)
    done
}

# パス参照は preload/load/extends を含め、形式を問わず禁止する。
# 「../../game/ai/...」のように game/ を経由する相対パスも検出する。
collect_matches "res://game/(ai|ui)(/|[\"'])" "text"
collect_matches "(^|[\"'])(\.\./)+(game/)?(ai|ui)(/|[\"'])" "text"

# AI/UI 側で class_name 宣言された型への直接参照も禁止する。
declare -a forbidden_classes=()
while IFS= read -r -d '' source_file; do
    while IFS= read -r declared_class; do
        if [[ -n "${declared_class}" ]]; then
            forbidden_classes+=("${declared_class}")
        fi
    done < <(
        sed -nE \
            's/^[[:space:]]*class_name[[:space:]]+([A-Za-z_][A-Za-z0-9_]*).*/\1/p' \
            "${source_file}"
    )
done < <(find "${AI_DIR}" "${UI_DIR}" -type f -name '*.gd' -print0)

if (( ${#forbidden_classes[@]} > 0 )); then
    mapfile -t forbidden_classes < <(printf '%s\n' "${forbidden_classes[@]}" | sort -u)
    for declared_class in "${forbidden_classes[@]}"; do
        collect_matches "(^|[^[:alnum:]_])${declared_class}([^[:alnum:]_]|$)" "code"
    done
fi

if (( ${#violations[@]} > 0 )); then
    printf '依存規則違反: game/core から game/ai または game/ui を参照しています。\n' >&2
    printf '  %s\n' "${violations[@]}" >&2
    exit 1
fi

printf '依存規則チェック: 違反なし\n'
