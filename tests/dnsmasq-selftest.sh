#!/bin/sh
# =====================================================================
# dnsmasq 配置自检（只读）
#
#   sh tests/dnsmasq-selftest.sh [-d 片段目录] [-c 主配置] [-b dnsmasq路径]
#
# 做三件事：
#   1) 扫描片段里重复的全局关键字（这是最容易把 dnsmasq 直接搞挂的原因）
#   2) 用 dnsmasq --test 做纯语法校验（不会启动、不会 reload）
#   3) 汇总 PASS / WARN / FAIL
#
# 不带参数时，默认检查仓库里的 merlin/dnsmasq.conf.add.example。
# 建议改配置后先跑本脚本，再决定要不要重启服务。
# =====================================================================
set -u

FRAG_DIR=""
MAIN_CONF=""
DNSMASQ_BIN="${DNSMASQ_BIN:-dnsmasq}"

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    -d) FRAG_DIR="${2:-}"; shift 2 ;;
    -c) MAIN_CONF="${2:-}"; shift 2 ;;
    -b) DNSMASQ_BIN="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 2 ;;
  esac
done

TMP=$(mktemp -d 2>/dev/null) || TMP="/tmp/dnsmasq-selftest.$$"
mkdir -p "$TMP/conf.d" || { echo "FAIL: 无法创建临时目录 $TMP"; exit 2; }
trap 'rm -rf "$TMP"' EXIT INT TERM

FAIL=0
WARN=0

# ---------- 收集片段 ----------
: > "$TMP/files.list"
if [ -n "$FRAG_DIR" ]; then
  if [ ! -d "$FRAG_DIR" ]; then
    echo "FAIL: 片段目录不存在: $FRAG_DIR"
    exit 1
  fi
  find "$FRAG_DIR" -maxdepth 1 -type f -name '*.conf' 2>/dev/null > "$TMP/files.list"
else
  HERE=$(cd "$(dirname "$0")" && pwd)
  SAMPLE="$HERE/../merlin/dnsmasq.conf.add.example"
  if [ -f "$SAMPLE" ]; then
    printf '%s\n' "$SAMPLE" > "$TMP/files.list"
  fi
fi

COUNT=$(wc -l < "$TMP/files.list" | tr -d ' ')
if [ "${COUNT:-0}" -eq 0 ]; then
  echo "FAIL: 没有找到任何 .conf 片段（用 -d 指定目录）"
  exit 1
fi
echo "== 待检查片段: $COUNT 个 =="

i=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  i=$((i + 1))
  cp "$f" "$TMP/conf.d/frag-$i.conf"
  echo "  - $f"
done < "$TMP/files.list"

# ---------- 1. 重复关键字 ----------
# 可重复出现的关键字（白名单）与致命的全局关键字分开处理
REPEATABLE=" server address ipset interface except-interface dhcp-range dhcp-host dhcp-option rev-server local host-record cname srv-host addn-hosts bogus-nxdomain localise-queries "

echo
echo "== 1. 重复关键字检查 =="
DUPS=$(awk -v rep="$REPEATABLE" '
  /^[[:space:]]*#/ { next }
  /^[[:space:]]*$/ { next }
  {
    line = $0
    sub(/^[[:space:]]+/, "", line)
    kw = line
    sub(/[=[:space:]].*$/, "", kw)
    if (index(rep, " " kw " ") > 0) next
    cnt[kw]++
    where[kw] = where[kw] " " FILENAME
  }
  END {
    for (k in cnt) if (cnt[k] > 1) printf "%s %d %s\n", k, cnt[k], where[k]
  }
' "$TMP"/conf.d/*.conf 2>/dev/null)

if [ -n "$DUPS" ]; then
  printf '%s\n' "$DUPS" | while IFS= read -r row; do
    kw=${row%% *}
    case "$kw" in
      user|group|port|cache-size|conf-dir|resolv-file|log-facility|dns-forward-max)
        echo "  FAIL: [$kw] 出现多次（全局关键字，重复会导致 dnsmasq 拒绝启动）" ;;
      *)
        echo "  WARN: [$kw] 出现多次，请确认该选项是幂等的" ;;
    esac
  done
  # 单独标一次 FAIL 计数（不依赖子 shell）
  echo "$DUPS" | grep -q -E '^(user|group|port|cache-size|conf-dir|resolv-file|log-facility|dns-forward-max) ' && FAIL=$((FAIL + 1))
  WARN=$((WARN + 1))
else
  echo "  PASS: 未发现重复的全局关键字"
fi

# ---------- 2. 片段内不应再写 conf-dir ----------
if grep -l -E '^[[:space:]]*conf-dir[[:space:]=]' "$TMP"/conf.d/*.conf >/dev/null 2>&1; then
  echo "  WARN: 片段内出现 conf-dir，容易造成嵌套扫描，建议移到主配置"
  WARN=$((WARN + 1))
fi

# ---------- 3. dnsmasq --test ----------
echo
echo "== 2. dnsmasq --test =="
if [ -n "$MAIN_CONF" ] && [ -f "$MAIN_CONF" ]; then
  TEST_CONF="$MAIN_CONF"
  echo "  使用主配置: $TEST_CONF"
else
  TEST_CONF="$TMP/main.conf"
  printf 'conf-dir=%s,*.conf\n' "$TMP/conf.d" > "$TEST_CONF"
fi

if command -v "$DNSMASQ_BIN" >/dev/null 2>&1; then
  if "$DNSMASQ_BIN" --test -C "$TEST_CONF" 2>"$TMP/test.err"; then
    echo "  PASS: 语法校验通过"
  else
    echo "  FAIL: dnsmasq 报错"
    sed 's/^/        /' "$TMP/test.err"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  SKIP: 找不到 $DNSMASQ_BIN（片段层面检查已完成）"
fi

# ---------- 汇总 ----------
echo
if [ "$FAIL" -gt 0 ]; then
  echo "结果: FAIL ($FAIL 项失败, $WARN 项告警) —— 不要重启 dnsmasq"
  exit 1
fi
if [ "$WARN" -gt 0 ]; then
  echo "结果: WARN ($WARN 项告警) —— 确认后再动服务"
  exit 0
fi
echo "结果: PASS"
exit 0
