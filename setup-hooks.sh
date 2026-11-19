#!/bin/sh
# 启用仓库自带的 pre-commit 钩子（扫描凭证与协议链接）
# 用法：sh setup-hooks.sh
set -e
cd "$(dirname "$0")"
git config core.hooksPath .githooks
chmod +x .githooks/pre-commit 2>/dev/null || true
echo "core.hooksPath = $(git config core.hooksPath)"
echo "已启用。提交前会自动扫描暂存内容；如需临时跳过：git commit --no-verify（不建议）"
