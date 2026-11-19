#!/bin/sh
# =====================================================================
# 回环保护自检（只读）
#
#   sh tests/loopback-guard.sh <盒子IP> [链名，默认 PREROUTING]
#
# 检查 nat 表里是否存在这样的顺序：
#   先  -s <盒子IP> -j RETURN / ACCEPT     （放行盒子自己的出站流量）
#   后  -j REDIRECT / DNAT / TPROXY        （内网客户的透明转发）
#
# 顺序反了 = 盒子向上游发解析请求时又被自己人劫持，形成回环。
# 本脚本只读规则，不写、不 flush、不重启。
# =====================================================================
set -u

BOX_IP="${1:-}"
CHAIN="${2:-PREROUTING}"

if [ -z "$BOX_IP" ]; then
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi

if command -v iptables-save >/dev/null 2>&1; then
  DUMP=$(iptables-save -t nat 2>/dev/null)
elif command -v iptables >/dev/null 2>&1; then
  DUMP=$(iptables -t nat -S 2>/dev/null)
else
  echo "SKIP: 当前环境没有 iptables / iptables-save（请在边界路由上运行）"
  exit 2
fi

if [ -z "$DUMP" ]; then
  echo "FAIL: 读不到 nat 表（权限不足？）"
  exit 1
fi

PREFIX="-A $CHAIN"

echo "== 链: $CHAIN   放行源: $BOX_IP =="
printf '%s\n' "$DUMP" | grep -n -E "^-A $CHAIN " | sed 's/^/  /'

GUARD_LINE=$(printf '%s\n' "$DUMP" | awk -v p="$PREFIX" -v ip="$BOX_IP" '
  index($0, p " ") == 1 {
    n++
    if (index($0, "-s " ip) > 0 && $0 ~ /-j (RETURN|ACCEPT)$/) { print n; exit }
  }
')

REDIRECT_LINE=$(printf '%s\n' "$DUMP" | awk -v p="$PREFIX" '
  index($0, p " ") == 1 {
    n++
    if ($0 ~ /-j (REDIRECT|DNAT|TPROXY)/) { print n; exit }
  }
')

ANY_REDIRECT=$(printf '%s\n' "$DUMP" | grep -c -E "^-A $CHAIN .*-j (REDIRECT|DNAT|TPROXY)")

echo
if [ -z "$GUARD_LINE" ]; then
  echo "FAIL: 没有找到针对 $BOX_IP 的 RETURN/ACCEPT 放行规则"
  echo "      盒子自身的出站流量会被后续重定向规则再次劫持，存在回环风险"
  exit 1
fi
echo "PASS: 放行规则位于 $CHAIN 第 $GUARD_LINE 条"

if [ "${ANY_REDIRECT:-0}" -eq 0 ]; then
  echo "INFO: 当前链内没有任何 REDIRECT/DNAT/TPROXY，无需比较顺序"
  exit 0
fi

if [ -z "$REDIRECT_LINE" ]; then
  echo "WARN: 没解析到重定向规则行号，请手工核对顺序"
  exit 0
fi
echo "INFO: 第一条重定向规则位于第 $REDIRECT_LINE 条"

if [ "$GUARD_LINE" -lt "$REDIRECT_LINE" ]; then
  echo "结果: PASS —— 先放行后重定向，顺序正确"
  exit 0
fi

echo "结果: FAIL —— 重定向排在放行之前，盒子的解析请求会被劫持"
exit 1
