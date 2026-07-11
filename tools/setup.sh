#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SCRIPT_DIR}/versions.sh"

# 相対パスの GODOT_BIN は受け取った時点で絶対パス化し、checks.sh と解釈を揃える。
if [[ -n "${GODOT_BIN:-}" && "${GODOT_BIN}" == */* && "${GODOT_BIN}" != /* ]]; then
    GODOT_BIN="$(pwd)/${GODOT_BIN}"
fi

readonly GODOT_ARCHIVE_NAME="Godot_v${GODOT_VERSION}_linux.x86_64.zip"
readonly GODOT_BINARY_NAME="Godot_v${GODOT_VERSION}_linux.x86_64"
readonly GODOT_URL="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/${GODOT_ARCHIVE_NAME}"
readonly GUT_ARCHIVE_NAME="Gut-v${GUT_VERSION}.tar.gz"
readonly GUT_URL="https://github.com/bitwes/Gut/archive/refs/tags/v${GUT_VERSION}.tar.gz"
readonly TOOLING_DIR="${REPO_ROOT}/.tooling"
readonly DOWNLOAD_DIR="${TOOLING_DIR}/downloads"

godot_stage=""
gut_stage=""

cleanup_stages() {
    if [[ -n "${godot_stage}" && -d "${godot_stage}" ]]; then
        rm -rf "${godot_stage}"
    fi
    if [[ -n "${gut_stage}" && -d "${gut_stage}" ]]; then
        rm -rf "${gut_stage}"
    fi
}

require_command() {
    local command_name="$1"
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        printf '必要なコマンドが見つかりません: %s\n' "${command_name}" >&2
        exit 1
    fi
}

download_file() {
    local url="$1"
    local destination="$2"
    local temporary="${destination}.tmp"

    if [[ -f "${destination}" ]]; then
        return
    fi

    rm -f "${temporary}"
    printf '取得中: %s\n' "${url}"
    curl \
        --fail \
        --location \
        --retry 3 \
        --retry-all-errors \
        --connect-timeout 20 \
        --output "${temporary}" \
        "${url}"
    mv "${temporary}" "${destination}"
}

validate_godot_binary() {
    local godot_binary="$1"
    local actual_version=""

    if ! actual_version="$("${godot_binary}" --version)"; then
        printf 'Godot のバージョン確認に失敗しました: %s\n' "${godot_binary}" >&2
        exit 1
    fi
    if [[ ! "${actual_version}" =~ ${GODOT_VERSION_REGEX} ]]; then
        printf 'Godot %s 系が必要です。検出した版: %s\n' \
            "${GODOT_VERSION_MAJOR_MINOR}" "${actual_version}" >&2
        exit 1
    fi
}

validate_zip() {
    local archive="$1"

    if command -v unzip >/dev/null 2>&1; then
        unzip -tq "${archive}" >/dev/null
    else
        python3 -m zipfile -t "${archive}" >/dev/null
    fi
}

extract_zip() {
    local archive="$1"
    local destination="$2"

    if command -v unzip >/dev/null 2>&1; then
        unzip -q "${archive}" -d "${destination}"
    else
        python3 -m zipfile -e "${archive}" "${destination}"
    fi
}

install_godot() {
    local godot_root="${TOOLING_DIR}/godot-${GODOT_VERSION}"
    local godot_binary="${godot_root}/${GODOT_BINARY_NAME}"
    local godot_archive="${DOWNLOAD_DIR}/${GODOT_ARCHIVE_NAME}"

    if [[ -n "${GODOT_BIN:-}" ]]; then
        local supplied_godot="${GODOT_BIN}"
        if [[ "${GODOT_BIN}" == */* ]]; then
            if [[ ! -x "${GODOT_BIN}" ]]; then
                printf 'GODOT_BIN が実行可能ファイルではありません: %s\n' "${GODOT_BIN}" >&2
                exit 1
            fi
        else
            supplied_godot="$(command -v "${GODOT_BIN}" 2>/dev/null || true)"
            if [[ -z "${supplied_godot}" ]]; then
                printf 'GODOT_BIN で指定したコマンドが見つかりません: %s\n' "${GODOT_BIN}" >&2
                exit 1
            fi
        fi
        validate_godot_binary "${supplied_godot}"
        printf 'GODOT_BIN を使用するため Godot の取得を省略します: %s\n' "${GODOT_BIN}"
        return
    fi

    if [[ "$(uname -m)" != "x86_64" ]]; then
        printf '自動取得は Linux x86_64 のみ対応しています。GODOT_BIN を指定してください。\n' >&2
        exit 1
    fi

    if [[ ! -x "${godot_binary}" ]]; then
        download_file "${GODOT_URL}" "${godot_archive}"
        validate_zip "${godot_archive}"

        godot_stage="${TOOLING_DIR}/.godot-stage-$$"
        mkdir -p "${godot_stage}"
        extract_zip "${godot_archive}" "${godot_stage}"
        if [[ ! -f "${godot_stage}/${GODOT_BINARY_NAME}" ]]; then
            printf 'Godot アーカイブに想定したバイナリがありません: %s\n' "${GODOT_BINARY_NAME}" >&2
            exit 1
        fi

        mkdir -p "${godot_root}"
        mv "${godot_stage}/${GODOT_BINARY_NAME}" "${godot_binary}"
        chmod +x "${godot_binary}"
    fi

    validate_godot_binary "${godot_binary}"
    ln -sfn "godot-${GODOT_VERSION}/${GODOT_BINARY_NAME}" "${TOOLING_DIR}/godot"
    printf 'Godot %s を準備しました。\n' "${GODOT_VERSION}"
}

install_gut() {
    local gut_root="${TOOLING_DIR}/gut-v${GUT_VERSION}"
    local gut_archive="${DOWNLOAD_DIR}/${GUT_ARCHIVE_NAME}"
    local gut_link="${REPO_ROOT}/addons/gut"
    local expected_link="../.tooling/gut-v${GUT_VERSION}/addons/gut"

    if [[ ! -f "${gut_root}/addons/gut/gut_cmdln.gd" ]]; then
        download_file "${GUT_URL}" "${gut_archive}"
        tar -tzf "${gut_archive}" >/dev/null

        gut_stage="${TOOLING_DIR}/.gut-stage-$$"
        mkdir -p "${gut_stage}"
        tar -xzf "${gut_archive}" --strip-components=1 -C "${gut_stage}"
        if [[ ! -f "${gut_stage}/addons/gut/gut_cmdln.gd" ]]; then
            printf 'GUT アーカイブに gut_cmdln.gd がありません。\n' >&2
            exit 1
        fi
        if [[ -e "${gut_root}" ]]; then
            rm -rf "${gut_root}"
        fi
        mv "${gut_stage}" "${gut_root}"
        gut_stage=""
    fi

    if ! grep -Fqx "version=\"${GUT_VERSION}\"" "${gut_root}/addons/gut/plugin.cfg"; then
        printf 'GUT の版確認に失敗しました。期待する版: %s\n' "${GUT_VERSION}" >&2
        exit 1
    fi

    if [[ -L "${gut_link}" ]]; then
        ln -sfn "${expected_link}" "${gut_link}"
    elif [[ -e "${gut_link}" ]]; then
        printf 'addons/gut が既に存在し、セットアップ管理のリンクではありません。\n' >&2
        exit 1
    else
        ln -s "${expected_link}" "${gut_link}"
    fi

    if [[ ! -f "${gut_link}/gut_cmdln.gd" ]]; then
        printf 'GUT の配置確認に失敗しました: %s\n' "${gut_link}" >&2
        exit 1
    fi
    printf 'GUT v%s を準備しました。\n' "${GUT_VERSION}"
}

trap cleanup_stages EXIT

require_command curl
require_command tar
if [[ -z "${GODOT_BIN:-}" ]] \
    && ! command -v unzip >/dev/null 2>&1 \
    && ! command -v python3 >/dev/null 2>&1; then
    printf 'ZIP 展開用に unzip または python3 が必要です。\n' >&2
    exit 1
fi

mkdir -p "${DOWNLOAD_DIR}" "${REPO_ROOT}/addons"
install_godot
install_gut

printf '開発ツールのセットアップが完了しました。\n'
