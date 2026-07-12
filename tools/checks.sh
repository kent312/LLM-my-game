#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly INVOCATION_DIR="$(pwd)"
readonly GENERATED_DIR="${REPO_ROOT}/game/data/generated"

source "${SCRIPT_DIR}/versions.sh"

resolve_godot_bin() {
    local candidate=""

    if [[ -n "${GODOT_BIN:-}" ]]; then
        if [[ "${GODOT_BIN}" == */* ]]; then
            candidate="${GODOT_BIN}"
            # 相対パスは呼び出し元の作業ディレクトリ基準で解決する（setup.sh と同じ解釈）。
            if [[ "${candidate}" != /* ]]; then
                candidate="${INVOCATION_DIR}/${candidate}"
            fi
        else
            candidate="$(command -v "${GODOT_BIN}" 2>/dev/null || true)"
        fi
    else
        candidate="${REPO_ROOT}/.tooling/godot"
    fi

    if [[ -z "${candidate}" || ! -x "${candidate}" ]]; then
        printf 'Godot が見つかりません。先に bash tools/setup.sh を実行してください。\n' >&2
        return 1
    fi
    printf '%s\n' "${candidate}"
}

cd "${REPO_ROOT}"

bash tools/check_deps.sh

# 「readonly VAR="$(...)"」はコマンド置換の失敗を隠して set -e を素通りさせるため、代入と分ける。
GODOT_EXECUTABLE="$(resolve_godot_bin)"
readonly GODOT_EXECUTABLE

if [[ ! -f addons/gut/gut_cmdln.gd ]]; then
    printf 'GUT が見つかりません。先に bash tools/setup.sh を実行してください。\n' >&2
    exit 1
fi
if ! grep -Fqx "version=\"${GUT_VERSION}\"" addons/gut/plugin.cfg; then
    printf 'GUT v%s が必要です。bash tools/setup.sh を再実行してください。\n' "${GUT_VERSION}" >&2
    exit 1
fi

GODOT_VERSION_ACTUAL="$("${GODOT_EXECUTABLE}" --version)"
readonly GODOT_VERSION_ACTUAL
if [[ ! "${GODOT_VERSION_ACTUAL}" =~ ${GODOT_VERSION_REGEX} ]]; then
    printf 'Godot %s 系が必要です。検出した版: %s\n' \
        "${GODOT_VERSION_MAJOR_MINOR}" "${GODOT_VERSION_ACTUAL}" >&2
    exit 1
fi
printf 'Godot: %s\n' "${GODOT_VERSION_ACTUAL}"

if [[ ! -d "${GENERATED_DIR}" ]]; then
    printf '文法生成物ディレクトリがありません: %s\n' "${GENERATED_DIR}" >&2
    exit 1
fi

CHECK_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/llmtrpg-checks.XXXXXX")"
readonly CHECK_TMP_DIR
trap 'rm -rf -- "${CHECK_TMP_DIR}"' EXIT

# CI・サンドボックスでもホーム配下を汚さず実行できるよう、Godot のユーザーデータを隔離する。
export XDG_DATA_HOME="${CHECK_TMP_DIR}/xdg-data"
export XDG_CACHE_HOME="${CHECK_TMP_DIR}/xdg-cache"
export XDG_CONFIG_HOME="${CHECK_TMP_DIR}/xdg-config"
mkdir -p "${XDG_DATA_HOME}" "${XDG_CACHE_HOME}" "${XDG_CONFIG_HOME}"

readonly GRAMMAR_TMP_DIR="${CHECK_TMP_DIR}/generated"
mkdir -p "${GRAMMAR_TMP_DIR}"

"${GODOT_EXECUTABLE}" \
    --headless \
    --path "${REPO_ROOT}" \
    -s res://tools/gen_grammar.gd \
    -- \
    --input "${REPO_ROOT}/game/data/skill_tags.json" \
    --output "${GRAMMAR_TMP_DIR}"

if ! diff -ru -- "${GENERATED_DIR}" "${GRAMMAR_TMP_DIR}"; then
    printf '文法生成物が最新ではありません。tools/gen_grammar.gd で再生成してください。\n' >&2
    exit 1
fi
printf '文法生成物チェック: 差分なし\n'

"${GODOT_EXECUTABLE}" --headless --import --path "${REPO_ROOT}"

declare -a test_files=()
while IFS= read -r -d '' test_file; do
    test_files+=("${test_file}")
done < <(find tests -type f -name 'test_*.gd' -print0)

if (( ${#test_files[@]} == 0 )); then
    printf 'GUTテスト: 0件（成功）\n'
else
    printf 'GUTテスト: %dファイルを実行します。\n' "${#test_files[@]}"
    "${GODOT_EXECUTABLE}" \
        --headless \
        --path "${REPO_ROOT}" \
        -s addons/gut/gut_cmdln.gd \
        -gdir=res://tests \
        -ginclude_subdirs \
        -gexit
fi

printf '全チェックに合格しました。\n'
