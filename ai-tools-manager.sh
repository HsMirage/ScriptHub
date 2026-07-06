#!/usr/bin/env bash
set -euo pipefail

main() {
  local url="https://raw.githubusercontent.com/HsMirage/ScriptHub/main/AI/AI%E5%B7%A5%E5%85%B7%E5%AE%89%E8%A3%85%E7%AE%A1%E7%90%86%E8%84%9A%E6%9C%AC.sh"

  if command -v curl >/dev/null 2>&1; then
    exec bash <(curl -fsSL "$url") "$@"
  fi

  if command -v wget >/dev/null 2>&1; then
    local tmp
    tmp=$(mktemp)
    wget -qO "$tmp" "$url"
    exec bash "$tmp" "$@"
  fi

  echo "未找到 curl 或 wget，无法下载 AI 工具安装管理脚本。" >&2
  exit 1
}

main "$@"
