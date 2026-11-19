#!/bin/sh
# 只读自检：核对 HWNAT 相关 nvram 开关
#
# 用法: sh hwnt-check.sh
# 特性: 不修改任何配置、不重启任何服务、不写 nvram。
#
# 说明: 不同华硕系固件的键名并不完全一致，这里只查常见键；
#       查不到就报 UNKNOWN，不做猜测。

NVRAM="${NVRAM:-nvram}"
if ! "$NVRAM" get hw_nat_enable >/dev/null 2>&1; then
  if [ -x /usr/sbin/nvram ]; then
    NVRAM=/usr/sbin/nvram
  elif [ -x /sbin/nvram ]; then
    NVRAM=/sbin/nvram
  fi
fi

if ! "$NVRAM" get hw_nat_enable >/dev/null 2>&1; then
  echo "SKIP: 找不到可用的 nvram 命令（当前不是华硕系固件？）"
  exit 2
fi

echo "== HWNAT 开关 =="
echo "nvram 二进制: $NVRAM"

fail=0
unknown=0

for key in hw_nat_enable hw_nat_mode hw_nat_auto hw_nat_rebind; do
  val=$("$NVRAM" get "$key" 2>/dev/null)
  if [ -z "$val" ]; then
    echo "  [$key] <empty>  → UNKNOWN"
    unknown=$((unknown + 1))
    continue
  fi
  echo "  [$key] = $val"

  case "$key" in
    hw_nat_enable)
      [ "$val" = "1" ] || { echo "    → WARN: HWNAT 未启用"; fail=$((fail + 1)); }
      ;;
  esac
done

echo
if [ "$fail" -gt 0 ]; then
  echo "结果: WARN（HWNAT 未启用；若同时启用了本机透明转发/流控，请确认这是你想要的）"
  exit 1
fi
if [ "$unknown" -gt 0 ]; then
  echo "结果: PARTIAL（部分键位不存在，属正常差异，不影响只读结论）"
  exit 0
fi
echo "结果: PASS"
exit 0
