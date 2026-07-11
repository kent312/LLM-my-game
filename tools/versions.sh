#!/usr/bin/env bash
# 版番号の一元管理。tools/setup.sh と tools/checks.sh の両方から source する。
# 版を上げるときはこのファイルだけを更新する。

readonly GODOT_VERSION="4.7-stable"
readonly GODOT_VERSION_MAJOR_MINOR="${GODOT_VERSION%%-*}"
readonly GODOT_VERSION_REGEX="^${GODOT_VERSION_MAJOR_MINOR//./\\.}(\\.|\$)"
readonly GUT_VERSION="9.7.1"
