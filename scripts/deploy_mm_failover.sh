#!/usr/bin/env bash
# 把仓内 mm-failover 镜像铺到本机（macmini）并核对指纹。
#
# 为什么有它：网关原先只活在本机 ~/.local/bin/ ⇒ **主机重建就丢**，
# 而这套网关是 codex 车道的 502 止血线。进仓之后仓内是**真值源**，
# 重建后跑这一个脚本即可复原。
#
# 纪律：
#   · **不碰任何凭证**。key 一律从环境变量读，仓内与宿主都不存。
#   · 铺完必须跑**自检**（起真服 + /healthz），自检不过就不重启服务。
#   · `--skip-selftest` 是**测试专用**开关（默认关闭；显式传参才生效，
#     禁用环境变量形式）：只有待安装副本与上次自检通过的副本逐字节
#     相同（md5 门控）时才跳过自检；生产部署（launchd/手动）永远不传。
#   · 指纹对不上 ⇒ **拒绝铺**（除非 --force）：防止把改动过的副本盖上去。
#   · **第三版本闸门**（2026-10-28 · 工单 #2085）：仓内真源、provenance 指纹、
#     宿主部署副本曾经是**三份各不相同的文件**（真源本身落后，部署一次就把
#     宿主打回已下架的模型）。⇒ 除了「仓内 ↔ 指纹」这一道，还要看
#     **宿主副本是不是上次自己铺下去的那一份** ⇒ 部署台账
#     （$DEST_DIR/.mm-failover.deployed.md5）记着上次铺下去的 md5。
#     宿主副本与台账对不上 ⇒ 它是**来路不明的第三版本** ⇒ 拒绝铺
#     （除非 --force），避免"又一次 sed 出来的副本"被当成真源铺出去。
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# 源目录可被覆盖（测试要拿一个**篡改过**的副本去验「拒绝」这条牙）⇒
# 默认仍是仓内真值源。
SVC="${MM_FAILOVER_SRC:-$ROOT/services/mm-failover}"
DEST_DIR="${MM_FAILOVER_DIR:-$HOME/.local/bin}"
FORCE=0
SKIP_SELFTEST=0
for _arg in "$@"; do
  case "$_arg" in
    --force) FORCE=1 ;;
    --skip-selftest) SKIP_SELFTEST=1 ;;
    *) echo "::error::unknown argument: $_arg" >&2; exit 2 ;;
  esac
done

# 部署台账：上次铺下去的每个文件的 md5（文件名用**部署后的名字**）。
LEDGER="$DEST_DIR/.mm-failover.deployed.md5"

# 自检台账：上次自检**通过**的每个文件的 md5（与部署台账分开记——
# 部署台账在自检前就更新，自检失败那次也会记进去，所以它不能证明
# “这份字节跑通过自检”；只有这里记的 md5 才能给 --skip-selftest 门控）。
SELFTESTED="$DEST_DIR/.mm-failover.selftested.md5"

md5_of() {
  if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | cut -d' ' -f1; else md5 -q "$1"; fi
}

want_fingerprint() { # $1 = 文件名
  awk -v f="$1" '$1==f {print $2}' "$SVC/provenance.md" | head -1
}

ledger_md5() { # $1 = 部署后的文件名
  [ -f "$LEDGER" ] || return 0
  awk -v f="$1" '$2==f {print $1}' "$LEDGER" | head -1
}

selftested_md5() { # $1 = 部署后的文件名
  [ -f "$SELFTESTED" ] || return 0
  awk -v f="$1" '$2==f {print $1}' "$SELFTESTED" | head -1
}

dest_name() { # $1 = 仓内文件名
  case "$1" in
    mm_failover.py)         echo "mm-failover.py" ;;
    mm_failover_selftest.py) echo "mm-failover-selftest.py" ;;
  esac
}

mkdir -p "$DEST_DIR"
_ledger_new="$LEDGER.tmp.$$"
: >"$_ledger_new"
for f in mm_failover.py mm_failover_selftest.py; do
  src="$SVC/$f"
  [ -f "$src" ] || { echo "missing source: $src" >&2; exit 1; }
  want="$(want_fingerprint "$f")"
  got="$(md5_of "$src")"
  if [ -z "$want" ]; then
    echo "::error::no fingerprint registered for $f in provenance.md — refusing to deploy an unaccounted file" >&2
    exit 1
  fi
  if [ "$want" != "$got" ]; then
    echo "::error::fingerprint mismatch for $f: want=$want got=$got" >&2
    echo "       the snapshot was edited without updating provenance.md — that is the rot the ratchet exists to catch" >&2
    [ "$FORCE" -eq 1 ] || exit 1
    echo "       --force given ⇒ deploying anyway" >&2
  fi
  # 宿主侧沿用**原名**（launchd plist 指向 mm-failover.py；自检同理）
  dname="$(dest_name "$f")"
  dest="$DEST_DIR/$dname"
  if [ -f "$dest" ] && [ "$(md5_of "$dest")" != "$got" ]; then
    # 宿主副本 ≠ 仓内真源 ⇒ 要么是台账里那份（正常更新），要么是**第三版本**。
    prev="$(ledger_md5 "$dname")"
    if [ -z "$prev" ] || [ "$prev" != "$(md5_of "$dest")" ]; then
      echo "::error::the host copy of $dname is an **unaccounted third version**" >&2
      echo "       host md5=$(md5_of "$dest")  repo md5=$got  ledger=$prev" >&2
      echo "       it is neither the copy this deployer installed nor the current truth source" >&2
      echo "       ⇒ refusing to deploy over it (reconcile by hand, or re-run with --force)" >&2
      [ "$FORCE" -eq 1 ] || exit 1
      echo "       --force given ⇒ deploying anyway" >&2
    fi
  fi
  if [ -f "$dest" ] && [ "$(md5_of "$dest")" = "$got" ]; then
    echo "  $f: already identical — nothing to do"
  else
    cp "$src" "$dest"
    chmod +x "$dest"
    echo "  $f: installed → $dest"
  fi
  printf '%s  %s\n' "$got" "$dname" >>"$_ledger_new"
done
mv -f "$_ledger_new" "$LEDGER"

# 铺完先自检（起真服 + /healthz）⇒ 自检不过就**不**动正在跑的服务。
# 例外（仅 --skip-selftest 且 md5 门控全过）：待安装的每份文件都与
# 上次自检通过的副本逐字节相同 ⇒ 重验同一份字节没有新信息，跳过。
_skip_selftest=0
if [ "$SKIP_SELFTEST" -eq 1 ]; then
  _skip_selftest=1
  for f in mm_failover.py mm_failover_selftest.py; do
    _dname="$(dest_name "$f")"
    _want_md5="$(md5_of "$SVC/$f")"
    if [ "$(selftested_md5 "$_dname")" != "$_want_md5" ]; then _skip_selftest=0; break; fi
    if [ ! -f "$DEST_DIR/$_dname" ] || [ "$(md5_of "$DEST_DIR/$_dname")" != "$_want_md5" ]; then _skip_selftest=0; break; fi
  done
fi
if [ "$_skip_selftest" -eq 1 ]; then
  echo "-- self-test skipped: installed copies are byte-identical to the last self-tested copies (--skip-selftest, md5-gated)"
else
  echo "-- self-test (real start + /healthz)"
  if ! python3 "$DEST_DIR/mm-failover-selftest.py"; then
    echo "::error::self-test failed — the running service was NOT touched" >&2
    exit 1
  fi
  echo "-- self-test passed"
  # 这份字节刚跑通过自检 ⇒ 记下来，供下次 --skip-selftest 门控。
  _st_new="$SELFTESTED.tmp.$$"
  : >"$_st_new"
  for f in mm_failover.py mm_failover_selftest.py; do
    printf '%s  %s\n' "$(md5_of "$SVC/$f")" "$(dest_name "$f")" >>"$_st_new"
  done
  mv -f "$_st_new" "$SELFTESTED"
fi
echo "done. restart the launchd service by hand if the running copy is still the old one:"
echo "   launchctl kickstart -k gui/$(id -u)/com.dongshenglu.mm-failover"
