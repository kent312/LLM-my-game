#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly CORE_DIR="${REPO_ROOT}/game/core"
readonly FLOW_DIR="${REPO_ROOT}/game/flow"
readonly AI_DIR="${REPO_ROOT}/game/ai"
readonly UI_DIR="${REPO_ROOT}/game/ui"

# 検査対象が存在しないままチェックが黙って成功しないよう、必須ディレクトリを先に確認する。
for required_dir in "${CORE_DIR}" "${FLOW_DIR}" "${AI_DIR}" "${UI_DIR}"; do
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
        if (index($0, "INV4_ALLOW_NETWORK_TEST") > 0) {
            printf "%d:\n", NR
            next
        }
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

# ARCH-2: ゲームロジックは具象モックを知らず、LLMBackend 型だけに依存する。
# tests/ と game/ai/ はモックの定義・利用場所なので検査対象外とする。
declare -a logic_files=()
for logic_dir in "${CORE_DIR}" "${FLOW_DIR}" "${UI_DIR}"; do
    while IFS= read -r -d '' logic_file; do
        logic_files+=("${logic_file}")
    done < <(find "${logic_dir}" -type f -name '*.gd' -print0)
done

declare -a mock_violations=()
collect_logic_matches() {
    local pattern="$1"
    local mode="$2"
    local logic_file="" match=""

    for logic_file in "${logic_files[@]}"; do
        while IFS= read -r match; do
            if [[ -n "${match}" ]]; then
                mock_violations+=("${logic_file}:${match}")
            fi
        done < <(strip_gd_lines "${logic_file}" "${mode}" | grep -E "${pattern}" || true)
    done
}

collect_logic_matches "(^|[^[:alnum:]_])BackendMock([^[:alnum:]_]|$)" "code"
collect_logic_matches "(^|[^[:alnum:]_])backend_mock([.]gd)?([^[:alnum:]_]|$)" "text"

if (( ${#mock_violations[@]} > 0 )); then
    printf '依存規則違反: ゲームロジックが具象モック BackendMock を参照しています（ARCH-2）。\n' >&2
    printf '  %s\n' "${mock_violations[@]}" >&2
    exit 1
fi

# ARCH-2: UI/フローはbackend_*.gdの具象型を直接参照せず、LLMBackend契約だけを使う。
declare -a concrete_backend_violations=()
while IFS= read -r -d '' backend_file; do
    while IFS= read -r backend_class; do
        if [[ -z "${backend_class}" ]]; then
            continue
        fi
        for logic_file in "${logic_files[@]}"; do
            while IFS= read -r match; do
                if [[ -n "${match}" ]]; then
                    concrete_backend_violations+=("${logic_file}:${match}")
                fi
            done < <(
                strip_gd_lines "${logic_file}" "code" \
                    | grep -E "(^|[^[:alnum:]_])${backend_class}([^[:alnum:]_]|$)" \
                    || true
            )
        done
    done < <(
        sed -nE \
            's/^[[:space:]]*class_name[[:space:]]+([A-Za-z_][A-Za-z0-9_]*).*/\1/p' \
            "${backend_file}"
    )
done < <(find "${AI_DIR}" -maxdepth 1 -type f -name 'backend_*.gd' -print0)

if (( ${#concrete_backend_violations[@]} > 0 )); then
    printf '依存規則違反: UI/フローが具象LLMバックエンドを参照しています（ARCH-2）。\n' >&2
    printf '  %s\n' "${concrete_backend_violations[@]}" >&2
    exit 1
fi

# INV-4: 外部通信APIはOpenAI互換推論バックエンドだけに閉じ込める。
# addons/.tooling と生成キャッシュを除くリポジトリ全体の .gd/.tscn/.tres を走査する。
# tests/toolsで通信クラス名そのものを検査する必要がある行だけは、同じ行へ
# `INV4_ALLOW_NETWORK_TEST` と明記して許可理由をコードレビュー可能にする。
readonly EXTERNAL_BACKEND_FILE="${AI_DIR}/backend_openai.gd"
if [[ ! -f "${EXTERNAL_BACKEND_FILE}" ]]; then
    printf '依存規則違反: 外部推論バックエンドがありません: %s\n' \
        "${EXTERNAL_BACKEND_FILE}" >&2
    exit 1
fi

readonly NETWORK_API_PATTERN='(^|[^[:alnum:]_])(HTTPRequest|HTTPClient|StreamPeerTCP|StreamPeerTLS|PacketPeerUDP|TCPServer|UDPServer|ENetConnection|ENetMultiplayerPeer|WebRTCPeerConnection|WebSocketPeer|WebSocketMultiplayerPeer|UPNP)([^[:alnum:]_]|$)|(^|[^[:alnum:]_])IP[[:space:]]*[.][[:space:]]*resolve_hostname([^[:alnum:]_]|$)|(^|[^[:alnum:]_])OS[[:space:]]*[.][[:space:]]*(execute|create_process|shell_open)([^[:alnum:]_]|$)|(^|[^[:alnum:]_])JavaScriptBridge([^[:alnum:]_]|$)'
readonly BACKEND_FORBIDDEN_API_PATTERN='(^|[^[:alnum:]_])(StreamPeerTCP|StreamPeerTLS|PacketPeerUDP|TCPServer|UDPServer|ENetConnection|ENetMultiplayerPeer|WebRTCPeerConnection|WebSocketPeer|WebSocketMultiplayerPeer|UPNP)([^[:alnum:]_]|$)|(^|[^[:alnum:]_])IP[[:space:]]*[.][[:space:]]*resolve_hostname([^[:alnum:]_]|$)|(^|[^[:alnum:]_])OS[[:space:]]*[.][[:space:]]*(execute|create_process|shell_open)([^[:alnum:]_]|$)|(^|[^[:alnum:]_])JavaScriptBridge([^[:alnum:]_]|$)'

declare -a inv4_source_files=()
while IFS= read -r -d '' source_file; do
    inv4_source_files+=("${source_file}")
done < <(
    find "${REPO_ROOT}" \
        \( -path "${REPO_ROOT}/.git" \
            -o -path "${REPO_ROOT}/.tooling" \
            -o -path "${REPO_ROOT}/.godot" \
            -o -path "${REPO_ROOT}/addons" \) -prune \
        -o -type f \( -name '*.gd' -o -name '*.tscn' -o -name '*.tres' \) -print0
)

declare -a network_violations=()
for source_file in "${inv4_source_files[@]}"; do
    source_lines=""
    if [[ "${source_file}" == *.gd ]]; then
        source_lines="$(strip_gd_lines "${source_file}" "text")"
    else
        source_lines="$(awk '{ printf "%d:%s\n", NR, $0 }' "${source_file}")"
    fi
    pattern="${NETWORK_API_PATTERN}"
    if [[ "${source_file}" == "${EXTERNAL_BACKEND_FILE}" ]]; then
        pattern="${BACKEND_FORBIDDEN_API_PATTERN}"
    fi
    while IFS= read -r match; do
        if [[ -n "${match}" ]]; then
            network_violations+=("${source_file}:${match}")
        fi
    done < <(
        printf '%s\n' "${source_lines}" \
            | grep -Fv 'INV4_ALLOW_NETWORK_TEST' \
            | grep -E "${pattern}" \
            || true
    )
done

if (( ${#network_violations[@]} > 0 )); then
    printf 'INV-4違反: 許可されていない外部通信APIまたは動的生成があります。\n' >&2
    printf '  %s\n' "${network_violations[@]}" >&2
    exit 1
fi

declare -a backend_httpclient_violations=()
while IFS= read -r match; do
    if [[ -n "${match}" ]]; then
        backend_httpclient_violations+=("${EXTERNAL_BACKEND_FILE}:${match}")
    fi
done < <(
    strip_gd_lines "${EXTERNAL_BACKEND_FILE}" "text" \
        | grep -E '(^|[^[:alnum:]_])HTTPClient([^[:alnum:]_]|$)' \
        | grep -Ev 'HTTPClient[.]METHOD_POST' \
        || true
)
if (( ${#backend_httpclient_violations[@]} > 0 )); then
    printf 'INV-4違反: backend_openaiでHTTPClientの直接通信を使用できません。\n' >&2
    printf '  %s\n' "${backend_httpclient_violations[@]}" >&2
    exit 1
fi

if ! grep -Fq 'const CHAT_COMPLETIONS_PATH: String = "/v1/chat/completions"' \
    "${EXTERNAL_BACKEND_FILE}"; then
    printf 'INV-4違反: 外部送信先が固定の /v1/chat/completions ではありません。\n' >&2
    exit 1
fi
if ! perl -0777 -ne \
    'exit((/request[.]request\s*\(\s*endpoint\s*\+\s*CHAT_COMPLETIONS_PATH\s*,/) ? 0 : 1)' \
    "${EXTERNAL_BACKEND_FILE}"; then
    printf 'INV-4違反: request()の送信先が endpoint + CHAT_COMPLETIONS_PATH ではありません。\n' >&2
    exit 1
fi
direct_request_count="$(
    grep -Ec '[.]request[[:space:]]*[(]' "${EXTERNAL_BACKEND_FILE}" || true
)"
if [[ "${direct_request_count}" -ne 1 ]]; then
    printf 'INV-4違反: backend_openaiの直接request()呼び出しは固定推論経路1箇所だけにしてください。\n' >&2
    exit 1
fi

declare -a telemetry_violations=()
for source_file in "${inv4_source_files[@]}"; do
    while IFS= read -r match; do
        if [[ -n "${match}" ]]; then
            telemetry_violations+=("${source_file}:${match}")
        fi
    done < <(
        awk '{ printf "%d:%s\n", NR, $0 }' "${source_file}" \
            | grep -Fv 'INV4_ALLOW_NETWORK_TEST' \
            | grep -Ei \
                '(telemetry|analytics|crash[_ -]?report|play[_ -]?log|テレメトリ|プレイログ).*(request|send|送信)|'\
'(request|send|送信).*(telemetry|analytics|crash[_ -]?report|play[_ -]?log|テレメトリ|プレイログ)' \
            || true
    )
done
if (( ${#telemetry_violations[@]} > 0 )); then
    printf 'INV-4違反: ログ・テレメトリ送信コード候補があります。\n' >&2
    printf '  %s\n' "${telemetry_violations[@]}" >&2
    exit 1
fi
printf '外部通信境界チェック: backend_openai の推論リクエストのみ\n'

printf '依存規則チェック: 違反なし\n'
