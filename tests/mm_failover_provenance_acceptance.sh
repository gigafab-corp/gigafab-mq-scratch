#!/usr/bin/env bash
# tests/mm_failover_provenance_acceptance.sh
# mm-failover 网关的仓内镜像必须**自证**：指纹对得上、自检跑得过（且**带牙**）、
# 无凭证、兜底模型是**实测可用**的那一个、部署器挡得住"第三版本"。
#
# 为什么要有这条门禁（2026-10-22 · 实测）：
#   网关修完（四腿化 ＋ 自检工具）原先**只活在本机** ~/.local/bin/ ⇒ 主机重建就丢，
#   而这套网关是 codex 车道的 502 止血线。进仓之后，仓内是**真值源**，
#   但「仓内是快照」这句话本身需要**机器证据**，否则它只是一句注释。
#
# 2026-10-28 扩充（工单 #2085 · 四张工单零产出的根因回仓）：
#   现场有**三份**各不相同的 mm_failover.py（仓内 / macmini 部署副本 / aimax 部署副本），
#   仓内那份的兜底模型**已从 Kilo 目录下架** ⇒ 跑一次部署脚本就把宿主打回死信；
#   同时旧版只有一个 UPSTREAM_TIMEOUT=900（**每 socket 操作**计时）⇒ 一条死腿
#   就能烧光工匠预算 ⇒ 零产出。⇒ 本卡现在同时盯：
#     ① **指纹棘轮**（provenance.md ↔ 源文件）
#     ② **自检可跑且带牙**（真起服 + 本地假上游 + 定点变异自证）
#     ③ **无凭证**
#     ④ **部署器有牙**（指纹对不上 ⇒ 拒绝；宿主是**第三版本** ⇒ 拒绝）
#     ⑤ **兜底模型 == 实测表里标为 available 的那一个**（表带日期与实测命令）
#     ⑥ **节点级腿配置**（关掉某腿 ⇒ 该腿不进请求路径，请求仍成功）
# SUITE 258 → 258（**新增卡数 = 0**）：断言并入本卡，不新增验收脚本。
set -uo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT" || exit 1

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  \xe2\x9c\x93 %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \xe2\x9c\x98 %s\n' "$1" >&2; }

SVC="$ROOT/services/mm-failover"

MUT=$(mktemp -d "${TMPDIR:-/tmp}/mmfp.XXXXXX")
trap 'rm -rf "$MUT"' EXIT
PROV="$SVC/provenance.md"

md5_of() {
  if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | cut -d' ' -f1; else md5 -q "$1"; fi
}

# 自检不许在仓内留字节码缓存（污染工作树 ⇒ 染红别的卡的"源树未变"断言）
export PYTHONDONTWRITEBYTECODE=1

# ── C2 并行 harness（2026-11-10 门禁提速）：三组后台并行，结果文件 + 按序重放 ──
# 后台子 shell 改不了父 shell 的 PASS/FAIL 计数 ⇒ 每组把判决写进自己的结果文件，
# 父 shell 在分阶段等待点按固定顺序（G1 → G2 → G3）重放。记录格式（每组一个文件）：
#   === RECORD ===
#   OK|FAIL
#   <verbatim message，单行>
#   <0 或多行 detail 行，每行以 "      | " 开头>
#   === END ===
# 记录数固定：G1=1，G2=11，G3=9。缺文件、记录数不对、缺哨兵 ⇒ harness defect 判红，
# 绝不把残缺记录当 verdict（fail-closed）。组内禁止直接调 ok()/bad()。
# SKIP 类：§④ 有 4 条 verdict 只在部署器调用成功时才触发（C1 的 dep_*.out 断言），
# 调用失败时旧卡直接跳过它们（tally 少 4 条）；新卡为保住"每组固定记录数"的
# fail-closed 不变量，在 else 分支为每条未触发的 verdict 补一条 SKIP 记录——
# 重放时跳过（不计数、不打印），于是 G2 在任何路径下都是恰好 11 条记录，
# 旧卡的 verdict 集合与新卡重放出的集合一字不差。SKIP 绝不掩盖失败：
# 每条 SKIP 都配一条同块的 FAIL verdict（部署器调用失败本身）。
rec_ok() { # $1=文案 —— 只在组函数内调用
  { printf '%s\n' "=== RECORD ===" "OK" "$1" "=== END ==="; } >> "$_GROUP_RESULT"
}
rec_skip() { # $1=文案（未触发的 verdict 原文，仅作记录自描述）—— 只在组函数内调用
  { printf '%s\n' "=== RECORD ===" "SKIP" "$1" "=== END ==="; } >> "$_GROUP_RESULT"
}
rec_bad() { # $1=文案 [$2=detail 块，已带 "      | " 前缀、可含换行] —— 只在组函数内调用
  { printf '%s\n' "=== RECORD ===" "FAIL" "$1"; if [ $# -ge 2 ] && [ -n "$2" ]; then printf '%s\n' "$2"; fi; printf '%s\n' "=== END ==="; } >> "$_GROUP_RESULT"
}

replay_group_result() { # $1=组名（g1/g2/g3） $2=结果文件 $3=期望记录数 —— 父 shell 用，组内不用
  _rg_name="$1"; _rg_file="$2"; _rg_want="$3"
  _rg_log="$MUT/group_$_rg_name.log"
  if [ ! -f "$_rg_file" ]; then
    bad "$_rg_name is a HARNESS DEFECT: no result file (the background group died before judging)"
    [ -f "$_rg_log" ] && tail -50 "$_rg_log" >&2
    return
  fi
  # 快照后再解析：看门狗杀掉组后可能有孤儿进程仍在写原文件
  _rg_snap="$_rg_file.snap"
  if ! cp "$_rg_file" "$_rg_snap" 2>/dev/null; then
    bad "$_rg_name is a HARNESS DEFECT: cannot snapshot the result file"
    return
  fi
  _rg_verdicts=(); _rg_msgs=(); _rg_details=()
  _rg_state=0; _rg_ok=1
  _rg_v=""; _rg_m=""; _rg_d=""
  while IFS= read -r _rg_line || [ -n "$_rg_line" ]; do
    case "$_rg_state" in
      0)
        if [ "$_rg_line" = "=== RECORD ===" ]; then _rg_state=1; _rg_v=""; _rg_m=""; _rg_d=""; else _rg_ok=0; break; fi
        ;;
      1)
        case "$_rg_line" in
          OK|FAIL|SKIP) _rg_v="$_rg_line"; _rg_state=2 ;;
          *) _rg_ok=0; break ;;
        esac
        ;;
      2)
        _rg_m="$_rg_line"; _rg_state=3
        ;;
      3)
        case "$_rg_line" in
          "=== END ===")
            _rg_verdicts+=("$_rg_v"); _rg_msgs+=("$_rg_m"); _rg_details+=("$_rg_d"); _rg_state=0
            ;;
          "      | "*)
            if [ -z "$_rg_d" ]; then _rg_d="$_rg_line"; else _rg_d="$_rg_d
$_rg_line"; fi
            ;;
          *) _rg_ok=0; break ;;
        esac
        ;;
    esac
  done < "$_rg_snap"
  if [ "$_rg_ok" -eq 1 ] && [ "$_rg_state" -ne 0 ]; then _rg_ok=0; fi
  if [ "$_rg_ok" -eq 1 ] && [ "${#_rg_verdicts[@]}" -ne "$_rg_want" ]; then _rg_ok=0; fi
  if [ "$_rg_ok" -eq 0 ]; then
    bad "$_rg_name is a HARNESS DEFECT: the result file is truncated or malformed (expected $_rg_want records)"
    [ -f "$_rg_log" ] && tail -50 "$_rg_log" >&2
    return
  fi
  _rg_i=0
  while [ "$_rg_i" -lt "${#_rg_verdicts[@]}" ]; do
    if [ "${_rg_verdicts[$_rg_i]}" = "OK" ]; then
      ok "${_rg_msgs[$_rg_i]}"
    elif [ "${_rg_verdicts[$_rg_i]}" = "SKIP" ]; then
      : # 未触发的 verdict：旧卡也不计数，重放时同样跳过（不调 ok/bad）
    else
      bad "${_rg_msgs[$_rg_i]}"
      [ -n "${_rg_details[$_rg_i]}" ] && printf '%s\n' "${_rg_details[$_rg_i]}" >&2
    fi
    _rg_i=$((_rg_i + 1))
  done
}

wait_group() { # $1=组名 $2=PID $3=结果文件 $4=期望记录数 —— 分阶段等待 + 600 秒看门狗
  _wg_name="$1"; _wg_pid="$2"; _wg_file="$3"; _wg_want="$4"
  _wg_waited=0
  while kill -0 "$_wg_pid" 2>/dev/null; do
    if [ "$_wg_waited" -ge 600 ]; then
      kill "$_wg_pid" 2>/dev/null || true
      sleep 10
      if kill -0 "$_wg_pid" 2>/dev/null; then kill -9 "$_wg_pid" 2>/dev/null || true; fi
      wait "$_wg_pid" 2>/dev/null || true
      bad "$_wg_name timed out after 600s — HARNESS DEFECT (the background group was killed; its verdicts are not trusted)"
      return
    fi
    sleep 5
    _wg_waited=$((_wg_waited + 5))
  done
  wait "$_wg_pid" 2>/dev/null || true
  replay_group_result "$_wg_name" "$_wg_file" "$_wg_want"
}

# ── 三组定义（C2：定义在主流程之前 —— bash 要求先定义后调用）─────────────
# 组内不重缩进被搬移的块；verdict 文案一字不动；tally 行不动。
group_g1() { # §② 源自检 —— 1 条 verdict
  _GROUP_RESULT="$MUT/group_g1.result"
  : > "$_GROUP_RESULT"
  exec > "$MUT/group_g1.log" 2>&1
  if [ -f "$SVC/mm_failover_selftest.py" ]; then
    if python3 "$SVC/mm_failover_selftest.py" > "$MUT/g1_selftest.out" 2>&1; then
      rec_ok "the in-repo self-test passes (it really starts the server, reads /healthz, and drives local fake upstreams)"
    else
      rec_bad "the in-repo self-test FAILED — the snapshot is broken:" "$(sed 's/^/      | /' "$MUT/g1_selftest.out" | head -30)"
    fi
    rm -f "$MUT/g1_selftest.out"
  else
    rec_bad "the in-repo self-test tool is missing"
  fi
}

group_g2() { # §④ 部署器链 —— 组内必须保持串行，11 条 verdict
  _GROUP_RESULT="$MUT/group_g2.result"
  : > "$_GROUP_RESULT"
  exec > "$MUT/group_g2.log" 2>&1
  if [ -x "$ROOT/scripts/deploy_mm_failover.sh" ]; then
    rec_ok "the deployer exists and is executable"
    _dep_dst="$MUT/deploy"
    mkdir -p "$_dep_dst"
    # 造一个指纹**不匹配**的仓内副本 ⇒ 部署器必须拒绝（rc != 0）
    cp -a "$SVC" "$MUT/svc_bad"
    printf '\n# tampered before deploy\n' >> "$MUT/svc_bad/mm_failover.py"
    if MM_FAILOVER_SRC="$MUT/svc_bad" MM_FAILOVER_DIR="$_dep_dst" \
         bash "$ROOT/scripts/deploy_mm_failover.sh" >> "$MUT/group_g2.log" 2>&1; then
      rec_bad "the deployer accepted a snapshot whose fingerprint does not match provenance.md — it would overwrite the host copy with an unaccounted file"
    else
      rec_ok "the deployer refuses a snapshot whose fingerprint does not match provenance.md (it has teeth)"
    fi
    # 正常路径：装到临时目录 ⇒ 两个文件到位 ⇒ 再跑一次应当是「already identical」
    # （C1：这次是真实安装 ⇒ 必须跑自检；输出里断言自检跑过。）
    if MM_FAILOVER_DIR="$_dep_dst" bash "$ROOT/scripts/deploy_mm_failover.sh" >"$MUT/dep_first.out" 2>&1; then
      if [ -f "$_dep_dst/mm-failover.py" ] && [ -f "$_dep_dst/mm-failover-selftest.py" ]; then
        rec_ok "the deployer installs both files into the target directory"
      else
        rec_bad "the deployer reported success but the files are not there"
      fi
      if grep -q "self-test passed" "$MUT/dep_first.out"; then
        rec_ok "the first (real) install ran the self-test"
      else
        rec_bad "the first (real) install did not run the self-test — the deploy-after-install check is gone"
      fi
    else
      rec_bad "the deployer failed on a well-formed snapshot"
      rec_skip "the first (real) install ran the self-test"
    fi
    # ── ④-b **第三版本闸门**（#2085 的真病：仓内 / macmini / aimax 三份各不相同）──
    # 宿主副本被**带外改过**（既不是台账里那份，也不是当前真源）⇒ 必须拒绝铺。
    cp "$_dep_dst/mm-failover.py" "$MUT/accounted.py"     # 记账：台账里那一份
    printf '\n# a third version edited on the host\n' >> "$_dep_dst/mm-failover.py"
    if MM_FAILOVER_DIR="$_dep_dst" bash "$ROOT/scripts/deploy_mm_failover.sh" >> "$MUT/group_g2.log" 2>&1; then
      rec_bad "the deployer overwrote an **unaccounted third version** on the host — this is exactly how three divergent copies of the gateway came to be"
    else
      rec_ok "the deployer refuses to overwrite an unaccounted third version on the host (the three-versions rot is caught)"
    fi
    # 人工对账（把台账里那份放回去）⇒ 再铺一次必须通（闸门不能过紧）
    # （C1：这份与几秒前刚自检通过的是同一份字节 ⇒ 传 --skip-selftest，
    # 部署器必须跳过重验；跳过本身也要断言，否则省掉的自检是静默的。）
    cp "$MUT/accounted.py" "$_dep_dst/mm-failover.py"
    if MM_FAILOVER_DIR="$_dep_dst" bash "$ROOT/scripts/deploy_mm_failover.sh" --skip-selftest >"$MUT/dep_reinstall.out" 2>&1; then
      rec_ok "the deployer re-installs the accounted copy (the refusal above was about the third version, not about updating)"
      if grep -q "self-test skipped" "$MUT/dep_reinstall.out" && ! grep -q "self-test passed" "$MUT/dep_reinstall.out"; then
        rec_ok "the re-install of the unchanged copy skipped the redundant self-test (md5-gated --skip-selftest)"
      else
        rec_bad "the re-install of the unchanged copy did not skip the redundant self-test — C1 saved nothing, or the skip was silent"
      fi
    else
      rec_bad "the deployer refused to re-install its own accounted copy — the third-version gate is too tight"
      rec_skip "the re-install of the unchanged copy skipped the redundant self-test (md5-gated --skip-selftest)"
    fi
    # 正常更新路径仍然通：仓内真源前进一版（指纹同步更新）⇒ 允许覆盖台账里那份
    cp -a "$SVC" "$MUT/svc_next"
    printf '\n# next truth source revision\n' >> "$MUT/svc_next/mm_failover.py"
    _nextmd5="$(md5_of "$MUT/svc_next/mm_failover.py")"
    awk -v m="$_nextmd5" '$1=="mm_failover.py" {$2=m} {print}' \
      "$MUT/svc_next/provenance.md" > "$MUT/svc_next/provenance.md.new"
    mv -f "$MUT/svc_next/provenance.md.new" "$MUT/svc_next/provenance.md"
    # （C1 负对照：这次是**新**版本，故意也传 --skip-selftest —— md5 与
    # 上次自检通过的不同 ⇒ 门控必须顶住，部署器仍要跑自检。）
    if MM_FAILOVER_SRC="$MUT/svc_next" MM_FAILOVER_DIR="$_dep_dst" \
         bash "$ROOT/scripts/deploy_mm_failover.sh" --skip-selftest >"$MUT/dep_next.out" 2>&1; then
      rec_ok "the deployer accepts a legitimate truth-source advance (fingerprint updated in lockstep)"
      if grep -q "self-test passed" "$MUT/dep_next.out"; then
        rec_ok "the new-version install ran the self-test even with --skip-selftest (the md5 gate held)"
      else
        rec_bad "the new-version install skipped the self-test with --skip-selftest — the md5 gate failed open"
      fi
    else
      rec_bad "the deployer refuses a legitimate truth-source advance (fingerprint + provenance updated in lockstep)"
      rec_skip "the new-version install ran the self-test even with --skip-selftest (the md5 gate held)"
    fi
    # （C1：再铺一次同一份新版 ⇒ 与刚自检通过的是同一份字节 ⇒ 跳过重验。）
    if MM_FAILOVER_SRC="$MUT/svc_next" MM_FAILOVER_DIR="$_dep_dst" \
         bash "$ROOT/scripts/deploy_mm_failover.sh" --skip-selftest >"$MUT/dep_next_again.out" 2>&1; then
      rec_ok "the deployer accepts a legitimate truth-source advance (fingerprint updated in lockstep)"
      if grep -q "self-test skipped" "$MUT/dep_next_again.out" && ! grep -q "self-test passed" "$MUT/dep_next_again.out"; then
        rec_ok "the second install of the same new version skipped the redundant self-test (md5-gated --skip-selftest)"
      else
        rec_bad "the second install of the same new version did not skip the redundant self-test — C1 saved nothing, or the skip was silent"
      fi
    else
      rec_bad "the deployer refuses a legitimate truth-source advance (fingerprint + provenance updated in lockstep)"
      rec_skip "the second install of the same new version skipped the redundant self-test (md5-gated --skip-selftest)"
    fi
  else
    rec_bad "scripts/deploy_mm_failover.sh is missing or not executable — the host copy cannot be restored after a rebuild"
    # 部署器不存在 ⇒ 其余 10 条 §④ verdict 全未触发，补 SKIP 使 G2 恒为 11 条记录
    # （与旧卡等价：旧卡此时 §④ 只出 1 条 verdict；重放时 SKIP 不计数）。
    _g2_skip_msgs=(
      "the deployer refuses a snapshot whose fingerprint does not match provenance.md (it has teeth)"
      "the deployer installs both files into the target directory"
      "the first (real) install ran the self-test"
      "the deployer refuses to overwrite an unaccounted third version on the host (the three-versions rot is caught)"
      "the deployer re-installs the accounted copy (the refusal above was about the third version, not about updating)"
      "the re-install of the unchanged copy skipped the redundant self-test (md5-gated --skip-selftest)"
      "the deployer accepts a legitimate truth-source advance (fingerprint updated in lockstep)"
      "the new-version install ran the self-test even with --skip-selftest (the md5 gate held)"
      "the deployer accepts a legitimate truth-source advance (fingerprint updated in lockstep)"
      "the second install of the same new version skipped the redundant self-test (md5-gated --skip-selftest)"
    )
    for _g2_m in "${_g2_skip_msgs[@]}"; do rec_skip "$_g2_m"; done
  fi
}

group_g3() { # M4–M12 变异自证 —— 组内结构原样不动，9 条 verdict
  _GROUP_RESULT="$MUT/group_g3.result"
  : > "$_GROUP_RESULT"
  exec > "$MUT/group_g3.log" 2>&1
  # M4..M12: 定点变异网关真源 ⇒ 对应的那条自检断言**必须点名转红**。
  #   变异体必须：① 真的落盘（替换串找不到 ⇒ 判 harness defect，不算杀掉）
  #   ② 还能编译（变异体自己语法错 ⇒ 那是空靶，不算杀掉）
  #   ③ 让**指定**的那条断言转红（不是随便哪条红）
  #
  # 并行（2026-11-10 门禁提速）：九只变异体各跑一遍完整自检，每遍 ~28s 且
  # 几乎全是等待（HOLD 预算 10s + 恢复 3.5s + 死腿连接超时 2s），串行就是
  # ~6 分钟。九只变异体彼此独立——各在自己的 $MUT/mutN 目录、只绑临时端口、
  # 不写盘——可以并行跑。后台子 shell 改不了父 shell 的 PASS/FAIL 计数，
  # 所以每只变异体把判决写进自己的结果文件（首行判决类、次行断言名、其余
  # 行是 WRONG 时的 FAIL 行），组内按序号重放成组记录文件；父 shell 再按
  # 固定顺序重放三组的记录文件——判决文案与串行版一字不差，tally 不变；
  # 结果文件缺失 ⇒ 按 harness defect 判红（fail-closed：后台任务死了也
  # 不许冒充“杀掉了”）。
  mutate_and_expect_bg() { # $1=序号 $2=期望转红的断言名 $3=旧串 $4=新串
    _id="$1"; _want_check="$2"; _old="$3"; _new="$4"
    _dir="$MUT/mut$_id"
    _res="$MUT/mut_result_$_id"
    _outlog="$MUT/mut_out_$_id.log"
    cp -a "$SVC" "$_dir"
    if ! python3 - "$_dir/mm_failover.py" "$_old" "$_new" <<'PYEOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path, encoding="utf-8").read()
if old not in s:
    sys.stderr.write("mutation did not land: %r\n" % old)
    sys.exit(3)
open(path, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYEOF
    then
      { printf '%s\n' "DEFECT landed" "$_want_check"; } > "$_res"
      return 0
    fi
    if ! python3 -m py_compile "$_dir/mm_failover.py" >/dev/null 2>&1; then
      { printf '%s\n' "DEFECT compile" "$_want_check"; } > "$_res"
      return 0
    fi
    (cd "$_dir" && timeout 180 python3 mm_failover_selftest.py > "$_outlog" 2>&1)
    _rc=$?
    if [ "$_rc" -eq 0 ]; then
      { printf '%s\n' "UNOBSERVED" "$_want_check"; } > "$_res"
      return 0
    fi
    if grep -q "Traceback" "$_outlog"; then
      { printf '%s\n' "DEFECT traceback" "$_want_check"; } > "$_res"
      return 0
    fi
    if grep -qF "**FAIL** $_want_check" "$_outlog"; then
      { printf '%s\n' "KILLED" "$_want_check"; } > "$_res"
    else
      {
        printf '%s\n' "WRONG" "$_want_check"
        grep -E "^\*\*FAIL\*\*" "$_outlog" | head -5
      } > "$_res"
    fi
    return 0
  }

  replay_mutant_verdict() { # $1=序号 —— 按结果文件写记录（组内写记录，不直接计数）
    _id="$1"
    _res="$MUT/mut_result_$_id"
    if [ ! -f "$_res" ]; then
      rec_bad "M$_id mutant is a HARNESS DEFECT: the mutant run produced no verdict (the background job died before judging)"
      return
    fi
    _verdict="$(sed -n '1p' "$_res")"
    _want_check="$(sed -n '2p' "$_res")"
    case "$_verdict" in
      KILLED)
        rec_ok "M$_id mutant killed: the '$_want_check' judgement goes red exactly where the capability was removed"
        ;;
      UNOBSERVED)
        rec_bad "M$_id mutant UNOBSERVED — the '$_want_check' judgement stayed green with the capability removed"
        ;;
      "DEFECT landed")
        rec_bad "M$_id mutant is a HARNESS DEFECT: the replacement string never landed (an empty-target mutant must not count as killed)"
        ;;
      "DEFECT compile")
        rec_bad "M$_id mutant is a HARNESS DEFECT: the mutant does not compile (a broken mutant would 'kill' the judgement for the wrong reason)"
        ;;
      "DEFECT traceback")
        rec_bad "M$_id mutant is a HARNESS DEFECT: the mutant crashed instead of being judged"
        ;;
      WRONG)
        rec_bad "M$_id mutant killed by the WRONG judgement — expected '$_want_check' to go red, got:" "$(tail -n +3 "$_res" | sed 's/^/      | /')"
        ;;
      *)
        rec_bad "M$_id mutant is a HARNESS DEFECT: unreadable verdict '$_verdict' in the mutant result file"
        ;;
    esac
  }

  mutate_and_expect_bg 4  "graded-timeout" \
    'timeout=CONNECT_TIMEOUT' 'timeout=UPSTREAM_TIMEOUT' &
  mutate_and_expect_bg 5  "token-auth" \
    'if not hmac.compare_digest(hdr, want):' 'if False:' &
  mutate_and_expect_bg 6  "path-allowlist" \
    'if allowed is not None and self.path.split("?")[0] not in allowed:' 'if False:' &
  mutate_and_expect_bg 7  "concurrency-limit" \
    'if _inflight >= _max_concurrent():' 'if False:' &
  mutate_and_expect_bg 8  "tools-strip" \
    '    if not dropped:' '    if True:' &
  mutate_and_expect_bg 9  "bind-refusal" \
    'if h in ("", "0.0.0.0", "*", "::", "[::]"):' 'if False:' &
  mutate_and_expect_bg 10 "leg-disable" \
    'elif label.lower() in disabled:' 'elif False:' &
  # M11: 把健康度排序**改回旧版**（原生腿优先）⇒ 死原生腿重新压到活兜底腿前面
  mutate_and_expect_bg 11 "health-order" \
    'keyed.sort(key=lambda c: (_health_rank(c[0]["label"]), _fails_of(c[0]["label"]), 0 if c[2] else 1, _mm_rank(c[0], pref), c[0]["idx"]))' \
    'keyed.sort(key=lambda c: (0 if c[2] else 1,))' &
  mutate_and_expect_bg 12 "cooldown-minutes" \
    'BAD_TTL_NET = 60' 'BAD_TTL_NET = 5' &
  wait
  for _m in 4 5 6 7 8 9 10 11 12; do replay_mutant_verdict "$_m"; done
}

# ── 主流程（C2：§① → 启动三组 → 分阶段等 + 重放 → §③/§⑤/M1–M3 穿插 → tally）──
echo "=== mm-failover provenance (self-accounting snapshot) ==="

# ── ① 指纹棘轮 ────────────────────────────────────────────────────────────
if [ ! -f "$PROV" ]; then
  bad "provenance.md is missing — the snapshot is unaccounted for"
else
  ok "provenance.md exists"
  _fp_block="$(awk '/<!-- fingerprints:start -->/,/<!-- fingerprints:end -->/' "$PROV")"
  if [ -z "$_fp_block" ]; then
    bad "provenance.md has no fingerprints:start/end block — the ratchet has nothing to ratchet"
  else
    ok "provenance.md carries a fingerprints block"
    for f in mm_failover.py mm_failover_selftest.py; do
      _want="$(printf '%s\n' "$_fp_block" | awk -v f="$f" '$1==f {print $2}' | head -1)"
      if [ -z "$_want" ]; then
        bad "no fingerprint registered for $f"
        continue
      fi
      if [ ! -f "$SVC/$f" ]; then
        bad "$f is registered in provenance.md but not in the tree"
        continue
      fi
      _got="$(md5_of "$SVC/$f")"
      if [ "$_want" = "$_got" ]; then
        ok "$f fingerprint matches provenance.md (${_got:0:12}) — the snapshot is accounted for"
      else
        bad "$f fingerprint drifted: provenance says ${_want:0:12}, file is ${_got:0:12} — the snapshot was edited without updating provenance.md"
      fi
    done
  fi
fi

# ── C2：三组后台并行（G1 §② ∥ G2 §④ ∥ G3 M4–M12）──
# §① 已在主 shell 跑完（指纹先验、再跑自检）；三组启动后，等待点只是重放的节拍，
# 墙钟 = max(G1, G2, G3) + 静态段。transcript 顺序与串行版一致（§4.4）。
group_g1 & _g1_pid=$!
group_g2 & _g2_pid=$!
group_g3 & _g3_pid=$!

wait_group g1 "$_g1_pid" "$MUT/group_g1.result" 1

# ── ③ 无凭证 ──────────────────────────────────────────────────────────────
_hits=""
for f in mm_failover.py mm_failover_selftest.py; do
  [ -f "$SVC/$f" ] || continue
  _h="$(grep -nE "(sk-[A-Za-z0-9]{16,}|eyJ[A-Za-z0-9_-]{16,}|(api[_-]?key|secret|token)[[:space:]]*=[[:space:]]*['\"][^'\"]{12,})" "$SVC/$f" || true)"
  [ -n "$_h" ] && _hits="$_hits
$f: $_h"
done
if [ -z "$_hits" ]; then
  ok "no credential literal in the in-repo snapshot — keys are read from the environment"
else
  bad "a credential literal is present in the in-repo snapshot (this file is cloneable by anyone):$_hits"
fi

wait_group g2 "$_g2_pid" "$MUT/group_g2.result" 11

# ── ⑤ 兜底模型 == 实测表里标为 available 的那一个 ───────────────────────
# 「真源用哪个兜底模型」必须是**实测**的结果，而不是散落在注释里的断言。
# 表在 provenance.md 的 measured-models 段（带日期 + 实测命令）⇒ 可复核。
if [ ! -f "$PROV" ]; then
  bad "provenance.md is missing — cannot check the measured model table"
else
  _mm_block="$(awk '/<!-- measured-models:start -->/,/<!-- measured-models:end -->/' "$PROV")"
  if [ -z "$_mm_block" ]; then
    bad "provenance.md has no measured-models block — the fallback model has no machine-checkable evidence"
  else
    ok "provenance.md carries a measured-models block"
    _src_fallback="$(grep -E '^BAOSI_FALLBACK_MODEL[[:space:]]*=' "$SVC/mm_failover.py" \
                    | head -1 | sed 's/.*=[[:space:]]*"//; s/".*$//')"
    _table_baosi="$(printf '%s\n' "$_mm_block" | awk -F'|' '
        $2 ~ /baosi/ && $4 ~ /available/ {gsub(/[`[:space:]]/,"",$3); print $3}')"
    if [ -z "$_src_fallback" ]; then
      bad "the truth source does not define BAOSI_FALLBACK_MODEL"
    elif [ -z "$_table_baosi" ]; then
      bad "the measured-models table has no available baosi model to compare against"
    elif [ "$_src_fallback" = "$_table_baosi" ]; then
      ok "the truth source's fallback model is the one marked available in the measured table ($_src_fallback)"
    else
      bad "the truth source's fallback model ($_src_fallback) is NOT the one marked available in the measured table ($_table_baosi) — this is how a delisted model got deployed"
    fi
    # 每一行都必须带日期与实测命令（否则「实测表」只是一张说法表）
    _noev="$(printf '%s\n' "$_mm_block" | awk -F'|' '
        $2 ~ /baosi|minimax/ {
          if ($5 !~ /20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) {print "no-date: " $3; next}
          if ($6 !~ /[^[:space:]]/) {print "no-command: " $3}
        }')"
    if [ -z "$_noev" ]; then
      ok "every measured-model row carries a date and the command that measured it"
    else
      bad "a measured-model row lacks a date or a measuring command:$_noev"
    fi
    # 已下架的模型绝不能是当前的兜底模型
    _delisted="$(printf '%s\n' "$_mm_block" | awk -F'|' '
        $4 ~ /delisted|unavailable|gone/ {gsub(/[`[:space:]]/,"",$3); print $3}')"
    _hit_delisted=""
    for _d in $_delisted; do
      [ "$_d" = "$_src_fallback" ] && _hit_delisted="$_d"
    done
    if [ -z "$_hit_delisted" ]; then
      ok "the fallback model is not one of the delisted/unavailable ones in the measured table"
    else
      bad "the fallback model ($_hit_delisted) is marked delisted/unavailable in the measured table"
    fi
  fi
fi

# ── 变异自证：每条判据逐只必须打红 ────────────────────────────────────────
# 一个只会说「过」的判据是壁纸。⇒ 对每条判据做一次**定点变异**，
# 证明它在该红的时候真的会红。变异用**字面串替换**（不是 sed 正则）⇒
# 替换不落盘就当场判红（空靶变异体不许冒充"有牙"）。
echo
echo "=== mutation self-proof (each judgement must have teeth) ==="

# M1: 改了源文件却没更新 provenance.md ⇒ 指纹判据必须打红
cp -a "$SVC" "$MUT/svc"
printf '\n# tampered\n' >> "$MUT/svc/mm_failover.py"
_bad=0
_want="$(awk -v f=mm_failover.py '$1==f {print $2}' "$MUT/svc/provenance.md" | head -1)"
_got="$(md5_of "$MUT/svc/mm_failover.py")"
[ "$_want" = "$_got" ] || _bad=1
if [ "$_bad" -eq 1 ]; then
  ok "M1 mutant killed: editing the snapshot without updating provenance.md changes its fingerprint (the ratchet bites)"
else
  bad "M1 mutant UNOBSERVED — the fingerprint judgement cannot tell an edited snapshot from an accounted one"
fi

# M2: provenance.md 里塞进一个凭证字面量 ⇒ 无凭证判据必须打红
cp -a "$SVC" "$MUT/svc2"
# 凭证字面量**运行时拼出来**（不写进本文件）—— 否则仓内这个门禁自己就带着一个
# 「长得像密钥」的串 ⇒ 判决面的密钥扫描会当场把**本文件**判红（实测 2026-10-22：
# 门禁的 secret scan 在本行上炸了）⇒ 一个为了抓密钥而写了密钥的门禁，是自指的。
_prefix="sk-"; _suffix="AAAAAAAAAAAAAAAAAAAA"
printf '\nAPI_KEY = "%s%s"\n' "$_prefix" "$_suffix" >> "$MUT/svc2/mm_failover.py"
_bad=0
grep -qE "sk-[A-Za-z0-9]{16,}" "$MUT/svc2/mm_failover.py" && _bad=1
if [ "$_bad" -eq 1 ]; then
  ok "M2 mutant killed: a credential literal in the snapshot is detected (the cloneability rule bites)"
else
  bad "M2 mutant UNOBSERVED — the credential judgement cannot see a key"
fi

# M3: 把自检工具改成语法错的 ⇒ 自检判据必须打红
cp -a "$SVC" "$MUT/svc3"
printf '\ndef broken(:\n' >> "$MUT/svc3/mm_failover_selftest.py"
if ! python3 "$MUT/svc3/mm_failover_selftest.py" >/dev/null 2>&1; then
  ok "M3 mutant killed: a syntactically broken self-test is caught by the self-test judgement (it bites)"
else
  bad "M3 mutant UNOBSERVED — the self-test judgement cannot tell a broken tool from a working one"
fi

wait_group g3 "$_g3_pid" "$MUT/group_g3.result" 9

echo
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
