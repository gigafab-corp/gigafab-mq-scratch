#!/usr/bin/env python3
"""mm-failover: MiniMax dual-key + Baosi automatic failover proxy (for codex).

Listens on 127.0.0.1:4180 by default (override with MM_FAILOVER_LISTEN_HOST/PORT),
forwards to upstreams in order.
Fails over on retryable HTTP status (401/402/403/429/5xx) and on transport
errors (TLS EOF / reset / IncompleteRead / timeout).  No protocol translation,
no model rewriting beyond the per-leg fallback model, no stream buffering.

2026-10-28 真源回正（工单 #2085）—— 四条病根的根治：
  ① **分级超时**：连接/首字节（CONNECT_TIMEOUT，默认 20s）与流式生成
     （STREAM_TIMEOUT，默认 900s）**分开**。旧版只有一个 UPSTREAM_TIMEOUT=900，
     而它是「每 socket 操作」计时 ⇒ 一条不可达的上游腿能烧满 900s ⇒
     工匠预算（3000s）被一条死腿吃光 ⇒ 级联永远轮不到健康腿 ⇒ 零产出。
  ② **健康度排序 + 熔断**：连续失败达阈值的腿进入**分钟级**冷却（旧版网络
     抖动只冷 5s ⇒ 刚挂的腿 5 秒后又被选中，抖动被放大）；排序把不健康腿排后
     ⇒ **健康腿永远先试**（旧版「原生腿优先」会把死原生腿排在活兜底腿前面）。
  ③ **重试换腿不换同腿**：传输层错误直接换下一条腿（同腿重试只允许 1 次）。
  ④ **节点级腿配置**：同一份真源在不同机器上可差异化 —— 环境变量可**启停 /
     排序 / 改 base_url / 改 key 源 / 改兜底模型**（macmini 留 minimax 原生腿，
     aimax 关掉它；或让 aimax 指向 macmini 的健康网关）。
  ⑤ **共享面护栏**（非回环绑定即启用）：只绑**指定地址**（拒绝 0.0.0.0）、
     强制 Bearer 令牌、单一端点（其余路径 404）、工具面隔离（剥掉 tools）、
     并发槽位上限（超限 503，不把 429 甩给上游）。

2026-10-28 v1.2（董事长令：三机统一 MiniMax 双号 + baosi-grok，不设本地腿）：
  ⑥ **全腿暂败保持重试**：一轮全腿失败后，若有腿的冷却是抖动/熔断档
     （会在预算量级内到期），保持请求按 HOLD_POLL 粒度重试，总预算
     HOLD_BUDGET（默认 90s），而不是立刻抛 502 ⇒ 客户端（codex）的指数
     退避死锁无从触发（2026-10-28 19:31 事故：双腿 2056 + baosi 瞬断
     ⇒ 502 ⇒ codex 挂死 6m03s）。额度/腿级长冷却（600s）等不起 ⇒ 不保持，
     立即按原语义收尾（回传未识别错误或 502）。
  ⑦ **双 MiniMax 腿时间片轮换**：两条**直连** MiniMax 腿都健康时，按
     MM_ROTATE_SECONDS（默认 3600s）时间片轮换优先腿，两号窗口均匀
     消耗（错峰），而不是主腿先烧干、次腿再烧干。经 base_url 改道的腿
     （如 aimax 的 macmini-mm）拓扑角色不同，不参与轮换。
"""
import hmac
import http.client
import ipaddress
import json, os, sys, threading, time
import urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ── 监听面 ────────────────────────────────────────────────────────────────
# 默认只绑回环（codex 本机自用）。要用同一个网关给**别的机器**当云端通道时，
# 用环境变量再起一个实例：
#   MM_FAILOVER_LISTEN_HOST=100.76.189.39 MM_FAILOVER_LISTEN_PORT=4180
#   GIGAFAB_MM_TOKEN=<令牌>   # 共享面**强制**要令牌（令牌只在 env 文件，0600）
# 绑**指定地址**而不是 0.0.0.0：钥匙在网关里，只让可信平面（Tailscale）看得见。
LISTEN_HOST = os.environ.get("MM_FAILOVER_LISTEN_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("MM_FAILOVER_LISTEN_PORT", "4180"))

# 共享面（被别的机器回连）判定：
#   MM_FAILOVER_SHARED_MODE=1/0 显式覆盖；auto（默认）= **绑非回环地址即共享**。
SHARED_MODE_ENV = "MM_FAILOVER_SHARED_MODE"

# 共享面**只**暴露的端点（其余路径 404 ⇒ 车间操作面不在暴露面上）。
SHARED_ALLOWED_PATHS = ("/v1/chat/completions", "/healthz")

# 共享面剥掉的工具面字段（纯文本补全代理 ⇒ 不带 tools/function 能力）。
TOOL_FIELDS = ("tools", "functions", "tool_choice", "parallel_tool_calls")

# 兜底腿的模型改写表（**实测表见 provenance.md 的 measured-models 段**）：
#   2026-10-28 董事长令：彻底清理 kilo 腿，全厂三机统一收敛为标准三腿：
#   minimax-primary / minimax-secondary / baosi-grok。
#   baosi : 目录里不存在 gpt-6-sol / gpt-6-luna；/v1/responses 只有 grok-* 族真通
#           ⇒ 末级兜底取 grok-4.7（实测 chat+responses 双 200）。
BAOSI_FALLBACK_MODEL = "grok-4.7"

# MM_FAILOVER_BAOSI_REASONING: control whether to strip reasoning_effort & summary
MM_FAILOVER_BAOSI_REASONING = os.environ.get("MM_FAILOVER_BAOSI_REASONING", "keep")


def _reasoning_mode():
    """BAOSI 推理开关：每次请求现读环境（自检可逐场景切换）。
    keep（默认）= 不动；none = baosi-grok 腿一律降级；auto = 仅当本腿把
    模型改写成 grok-4.7 时才降级。非法值按 keep 处理。"""
    v = (os.environ.get("MM_FAILOVER_BAOSI_REASONING")
         or MM_FAILOVER_BAOSI_REASONING or "keep").strip().lower()
    return v if v in ("keep", "none", "auto") else "keep"


def _apply_reasoning(body, label, rewritten_to_grok):
    """按开关改写请求体。**只发生在 baosi-grok 腿上**；MiniMax 腿永不进
    这里（逐字转发）。none ⇒ reasoning.effort 置 none 并去掉 summary；
    auto ⇒ 仅当本腿把模型改写成 grok-4.7 时才降级。返回改写后的 body。"""
    if label != "baosi-grok":
        return body
    mode = _reasoning_mode()
    if mode == "keep":
        return body
    if mode == "auto" and not rewritten_to_grok:
        return body
    if not body:
        return body
    try:
        d = json.loads(body)
    except Exception:
        return body
    if not isinstance(d, dict):
        return body
    # OpenAI 形态 reasoning:{effort,summary} 与顶层 reasoning_effort 都认
    changed = False
    if isinstance(d.get("reasoning"), dict):
        d["reasoning"]["effort"] = "none"
        d["reasoning"].pop("summary", None)
        changed = True
    elif d.get("reasoning") is None and "reasoning" in d:
        d["reasoning"] = {"effort": "none"}
        changed = True
    if "reasoning_effort" in d:
        d["reasoning_effort"] = "none"
        changed = True
    if not changed:
        # 体里本来就没有推理字段：补一个 effort=none（降级本身就是这个动作）
        d["reasoning"] = {"effort": "none"}
        changed = True
    log(f"{label}: reasoning 降级 ({mode}) ⇒ reasoning.effort=none, summary 已去掉")
    return json.dumps(d).encode()


def _model_of(body):
    """从请求体取 model 名; 取不到(None) ⇒ 无模型约束(GET /v1/models 等)。"""
    try:
        d = json.loads(body)
    except Exception:
        return None
    m = d.get("model")
    return m if isinstance(m, str) else None


def _is_minimax_model(model):
    """minimax 原生模型名族(实测: MiniMax-M3.1-Flash-Preview 走通; 其它族返 400 unknown model)。"""
    return bool(model) and model.lower().startswith("minimax")


def _is_grok_model(model):
    """baosi 在 /v1/responses 上原生的只有 grok-* 族(实测 11 个 200)。"""
    return bool(model) and model.lower().startswith("grok")


# baosi 的 Claude 缩写别名（c-o-5-5 一类）：**只认实测复核过的**。
# 目录只算线索（gpt-6-sol 在目录里却不存在的先例）⇒ 未经 chat/completions
# 实测 ping 200 的别名一律不入此集；复核证据记 provenance.md 的强模型道
# 实测附表与本 PR 说明。2026-10-31 施工批复测：目录 6 别名全部 ping 200 且响应
# model 字段逐一映射回全名、usage 带 Anthropic 指纹 ⇒ 六个别名全数入集：
# c-f-5→claude-fable-5、c-f-5-1→claude-fable-5-1、c-o-4-8→claude-opus-4-8、
# c-o-5→claude-opus-5、c-o-5-5→claude-opus-5-5、c-s-5-5→claude-sonnet-5-5。
CLAUDE_ALIASES = frozenset({
    "c-f-5", "c-f-5-1", "c-o-4-8", "c-o-5", "c-o-5-5", "c-s-5-5",
})


def _is_claude_model(model):
    """baosi Claude 原生模型名族（强模型道的承重判定）。

    命中 = claude-* 全名族（实测 claude-opus-5-5 走 chat/completions 200、
    usage 带 Anthropic 指纹 usage_source=anthropic / billing_usage.source=
    claude_messages ⇒ 后端确为 Anthropic 通道）+ CLAUDE_ALIASES 实测别名。
    baosi 对 Claude 族的 /v1/responses 通道返 500 not implemented ⇒
    本腿只走 chat/completions 形态（上游 URL 拼接与其它腿同形，无翻译）。
    """
    if not model:
        return False
    m = model.lower()
    return m.startswith("claude-") or m in CLAUDE_ALIASES


# (label, base_url, env_var, 原生判定 or None=该腿只做替代, 兜底模型 or None=不可替代)
#   原生判定为 None ⇒ **替代腿**: 无论请求什么模型, 都改写到该腿的兜底模型。
#   原生判定命中 ⇒ **原生腿**: 原样转发, 不改写。
#   未命中且无兜底模型 ⇒ **不适用本腿**: 直接跳过, 不浪费一次必败的上游请求。
UPSTREAMS = [
    ("minimax-primary",   "https://api.minimaxi.com",      "MINIMAX_API_KEY_PRIMARY",   _is_minimax_model, None),
    ("minimax-secondary", "https://api.minimaxi.com",      "MINIMAX_API_KEY_SECONDARY", _is_minimax_model, None),
    ("baosi-grok",        "https://baosiapi.com",          "BAOSIAPI_API_KEY",          _is_grok_model,    BAOSI_FALLBACK_MODEL),
    ("baosi-claude",      "https://baosiapi.com",          "BAOSIAPI_API_KEY",          _is_claude_model,  None),
]

# 裁决类模型（强模型道）：点名这些模型的请求**只许 Claude 原生腿接**——
# 替代腿与非 Claude 原生腿一律在 `_run_pass` 归类段跳过（见该处注释）。
# 强腿不在/冷却 ⇒ HOLD 预算后 502，物理上不存在被弱模型代判的路径；
# 这是防「以强模型之名行 Grok 之实」的核心规则（D20 病灶的正面根治）。
# 集合与强腿同批登记：新增裁决类模型名须同批改此集 + 自检覆盖。
VERDICT_MODELS = {"claude-opus-5-5"}

# 冷却 TTL 三档:
#  BAD_TTL_HTTP — 上游主动回 429/5xx, 认为上游真有问题, 长冷却。
#  BAD_TTL_NET  — TLS EOF / 连接重置 / IncompleteRead / 超时等传输层抖动:
#                 **分钟级**（旧版 5s ⇒ 刚挂的腿 5 秒后又被选中，抖动被放大）。
#  BAD_TTL_QUOTA— 上游回"额度/用量上限"(MiniMax code 2056 / 402 usage_limit_exceeded),
#                 这不是抖动而是**钱包见底**, 短冷却只会白跑探测 ⇒ 冷到 10 分钟。
BAD_TTL_HTTP = 60
BAD_TTL_NET = 60
BAD_TTL_QUOTA = 18000   # 额度/用量上限⇒长冷却(5h), 避免每次探测⇒827次盲打止损
BAD_TTL_LEG = 600       # 腿级永久性错误(模型/路由/未实现) ⇒ 冷久点, 别每 60s 白跑
                      # ⚠️ 已与 BAD_TTL_QUOTA 解耦：原同值 600 曾导致腿级错误被贴成“额度上限”
BAD_TTL_CIRCUIT = 120  # 熔断：连续失败达阈值 ⇒ 分钟级冷却，别再当首选腿



# Fuel gauge (5h sliding window EMS) — #2142 v1.3
# 纯内存滑动账本（零新增常驻）：每条腿近 5h（FUEL_WINDOW_SECONDS=18000s）
# 的请求字节事件；2056 触发时的窗口累计字节反标定该账号 5h 真实容量上限
# C_max；满血恢复时刻 t_reset = t_2056 + 5h。无 2056 历史 ⇒ 未标定，
# 不编 c_max（剩余报 100.0%，不谎报油量）。
FUEL_WINDOW_SECONDS = 18000
_fuel_events = {}    # label -> [(ts, bytes), ...]（仅窗口内事件）
_fuel_cmax = {}      # label -> C_max（字节），由 2056 触发时反标定
_fuel_last_2056 = {}  # label -> 最近一次触发 2056 的时间戳 t_2056

def _fuel_prune_locked(label, now):
    """内部（已持锁）：丢掉窗口外的事件，返回窗口内事件列表。"""
    evs = _fuel_events.get(label) or []
    if not evs:
        return []
    cutoff = now - FUEL_WINDOW_SECONDS
    kept = [(t, b) for (t, b) in evs if t > cutoff]
    if len(kept) != len(evs):
        _fuel_events[label] = kept
    return kept

def _fuel_update(label, byte_delta):
    """内部：把 byte_delta 计入当前滑动窗口（跨窗口的旧事件自然滑出）。"""
    with _lock:
        now = time.time()
        evs = _fuel_prune_locked(label, now)
        evs.append((now, max(0, int(byte_delta))))
        _fuel_events[label] = evs

def _fuel_bytes_in_window(label):
    """内部：当前滑动窗口内的累计字节（供 2056 标定用）。"""
    with _lock:
        return sum(b for _, b in _fuel_prune_locked(label, time.time()))

def _fuel_get_state(label):
    """内部：返回 (remaining_pct, next_reset_in_sec, dispatch_advice)。
    remaining_pct 是**剩余**占比（不是已用占比）；未标定（无 2056 历史）
    时报 (100.0, 0, "ALLOW_ALL")，不编一个 c_max 出来。"""
    with _lock:
        now = time.time()
        used = sum(b for _, b in _fuel_prune_locked(label, now))
        t2056 = _fuel_last_2056.get(label)
        cmax = _fuel_cmax.get(label)
        if t2056 is None or not cmax:
            return 100.0, 0, "ALLOW_ALL"
        remaining_pct = round(max(0.0, min((1 - used / cmax) * 100, 100.0)), 2)
        next_reset = max(0, int(t2056 + FUEL_WINDOW_SECONDS - now))
        advice = "LOW_COMPLEXITY_ONLY" if remaining_pct < 15 else "ALLOW_ALL"
        return remaining_pct, next_reset, advice

def _fuel_record_2056(label, byte_count):
    """内部：记录 2056 触发 ⇒ 存触发时的窗口累计字节作 C_max 标定，
    并记 t_2056（满血恢复时刻 = t_2056 + 5h）。byte_count 为 None 时
    现算窗口累计。"""
    with _lock:
        now = time.time()
        _fuel_last_2056[label] = now
        if byte_count is None:
            byte_count = sum(b for _, b in _fuel_prune_locked(label, now))
        if byte_count and byte_count > 0:
            _fuel_cmax[label] = max(_fuel_cmax.get(label, 0), int(byte_count))

# 连续失败多少次进熔断（分钟级冷却）。
CIRCUIT_FAIL_THRESHOLD = 3

# 错误分类器（用上游的真实报文字符串, 不用状态码硬猜）——
#   实测依据: minimax 对「缺 model」与「模型不存在」返回**同一个 code invalid_prompt**,
#   只能靠 message 区分; kilo 对不存在的模型返 402(余额墙), baosi 对无路由模型返
#   400 model_not_found / 503 No available channel, 对 MiniMax/claude 的 responses
#   通道返 500 "not implemented"。
#   请求级(体坏了) ⇒ 任何腿都会同样拒 ⇒ 原样回传并断链(保持客户端看到的真因)。
#   腿级(模型/路由/未实现) ⇒ 只这一腿废 ⇒ 必须 failover 到下一腿。
REQ_SIGNATURES = (
    "missing required parameter", "failed to parse or validate request parameters",
    "could not parse request body", "model name not specified",
    "must be a string or an array", "failed to deserialize", "invalid json",
)
LEG_SIGNATURES = (
    "unknown model", "unknown provider", "model_not_found", "model not found",
    "no available channel", "not implemented", "unsupported model",
    "model not exist", "no channel",
)


def _classify(raw):
    """把上游错误分成 'req'(请求级) / 'leg'(腿级) / None(未识别)。"""
    try:
        t = raw.decode("utf-8", "replace").lower()
    except Exception:
        return None
    for s in REQ_SIGNATURES:
        if s in t:
            return "req"
    for s in LEG_SIGNATURES:
        if s in t:
            return "leg"
    return None


class _UpstreamTimeout(Exception):
    """首字节超时（连接已建立、响应头已到，但正文一个字都没来）。"""


NET_TRIES = 1            # 传输层错误**换腿**重试；同腿重试已废除（只烧预算）
NET_RETRY_BACKOFF = 0.5  # 秒
HOLD_BUDGET = float(os.environ.get("MM_FAILOVER_HOLD_BUDGET", "90"))   # 全腿暂败时保持请求的总预算(秒); 0=禁用保持
HOLD_POLL = float(os.environ.get("MM_FAILOVER_HOLD_POLL", "10"))       # 保持期间的重试粒度(秒)
MM_ROTATE_SECONDS = int(os.environ.get("MM_FAILOVER_MM_ROTATE_SECONDS", "3600"))  # 双 MiniMax 直连腿时间片轮换(秒); 0=禁用
MM_PAIR = ("minimax-primary", "minimax-secondary")
MM_API_BASE = "https://api.minimaxi.com"
UPSTREAM_TIMEOUT = int(os.environ.get("MM_FAILOVER_STREAM_TIMEOUT", "900"))  # 秒, 流式生成长超时
CONNECT_TIMEOUT = int(os.environ.get("MM_FAILOVER_CONNECT_TIMEOUT", "20"))  # 秒, 连接+响应头+首字节（失败即换腿）
RETRYABLE = {401, 402, 403, 408, 425, 429, 500, 502, 503, 504}
NET_ERRORS = (urllib.error.URLError, OSError, http.client.HTTPException)
HOP_BY_HOP = {"connection", "keep-alive", "proxy-authenticate",
              "proxy-authorization", "te", "trailers",
              "transfer-encoding", "upgrade", "host", "content-length"}

# 共享面并发槽位（防 Aimax 多槽瞬间并发打爆上游账号级 429）。
MAX_CONCURRENT = 16


def _max_concurrent():
    """并发槽位上限（可按节点用环境变量调；读不到 ⇒ 用默认）。"""
    raw = os.environ.get("MM_FAILOVER_MAX_CONCURRENT")
    if raw:
        try:
            v = int(raw)
            if v > 0:
                return v
        except ValueError:
            pass
    return MAX_CONCURRENT

_bad, _fails = {}, {}
_attempts = []
_lock = threading.Lock()
_inflight = 0
_stats = {"requests": 0, "failovers": 0}


LEG_ALIASES = {
    "minimax-key2": "minimax-primary",
    "minimax-key3": "minimax-secondary",
}


def _tag(label):
    return label.upper().replace("-", "_")


def _leg_env(label, suffix):
    tag = _tag(label)
    primary = f"MM_FAILOVER_LEG_{tag}_{suffix}"
    if primary in os.environ:
        return primary
    for old_name, canonical in LEG_ALIASES.items():
        if label == canonical:
            old_tag = _tag(old_name)
            old_env = f"MM_FAILOVER_LEG_{old_tag}_{suffix}"
            if old_env in os.environ:
                return old_env
    return primary


def _legs():
    """解析**本次请求**的有效腿表（节点级配置全部在这里生效）。

    节点级可配置项（环境变量，同一份真源 ⇒ 不同机可差异化）：
      MM_FAILOVER_DISABLED_LEGS=minimax-primary,minimax-secondary   关掉某些腿
      MM_FAILOVER_LEG_ORDER=minimax-primary,baosi-grok              改排序
      MM_FAILOVER_LEG_<TAG>_ENABLED=0                         单腿开关
      MM_FAILOVER_LEG_<TAG>_BASE_URL=http://host:port         改上游地址
      MM_FAILOVER_LEG_<TAG>_KEY_ENV=OTHER_ENV                 改密钥来源
      MM_FAILOVER_LEG_<TAG>_MODEL=vendor/model                改兜底模型
    """
    disabled = {x.strip().lower()
                for x in (os.environ.get("MM_FAILOVER_DISABLED_LEGS") or "").split(",")
                if x.strip()}
    for old_name, canonical in LEG_ALIASES.items():
        if old_name in disabled:
            disabled.add(canonical)
    order_env = [x.strip() for x in (os.environ.get("MM_FAILOVER_LEG_ORDER") or "").split(",")
                 if x.strip()]
    order_env = [LEG_ALIASES.get(x.lower(), x) for x in order_env]
    rank = {lab: i for i, lab in enumerate(order_env)}
    rows = []
    for idx, (label, base, env, native, target) in enumerate(UPSTREAMS):
        flag = os.environ.get(_leg_env(label, "ENABLED"))
        if flag is not None and flag.strip().lower() in ("0", "false", "no", "off"):
            enabled = False
        elif label.lower() in disabled:
            enabled = False
        else:
            enabled = True
        base2 = (os.environ.get(_leg_env(label, "BASE_URL")) or base).rstrip("/")
        key_env = os.environ.get(_leg_env(label, "KEY_ENV")) or env
        model = os.environ.get(_leg_env(label, "MODEL")) or target
        rows.append({"label": label, "base": base2, "key_env": key_env,
                     "native": native, "target": model, "enabled": enabled,
                     "rank": rank.get(label, len(rank) + idx), "idx": idx})
    rows.sort(key=lambda r: (r["rank"], r["idx"]))
    return rows


def _is_loopback(host):
    if not host:
        return False
    if host.strip().lower() == "localhost":
        return True
    try:
        return ipaddress.ip_address(host.strip()).is_loopback
    except ValueError:
        return False


def _shared_mode():
    v = (os.environ.get(SHARED_MODE_ENV) or "auto").strip().lower()
    if v in ("1", "true", "yes", "on"):
        return True
    if v in ("0", "false", "no", "off"):
        return False
    return not _is_loopback(LISTEN_HOST)


def _token():
    """共享令牌（只在 env 里，**不入仓**）。"""
    return (os.environ.get("GIGAFAB_MM_TOKEN")
            or os.environ.get("MM_FAILOVER_TOKEN") or "")


def _allowed_paths():
    """共享面只暴露白名单端点；本地面（回环）默认全放行。"""
    raw = os.environ.get("MM_FAILOVER_ALLOWED_PATHS")
    if raw is None:
        return set(SHARED_ALLOWED_PATHS) if _shared_mode() else None
    return {p.strip() for p in raw.split(",") if p.strip()}


def _strip_tools_enabled():
    v = (os.environ.get("MM_FAILOVER_STRIP_TOOLS") or "").strip().lower()
    if v in ("1", "true", "yes", "on"):
        return True
    if v in ("0", "false", "no", "off"):
        return False
    return _shared_mode()


def _strip_tools(body):
    """共享面：剥掉工具面 ⇒ 该端点只做纯文本补全代理。"""
    if not body:
        return body
    try:
        d = json.loads(body)
    except Exception:
        return body
    if not isinstance(d, dict):
        return body
    dropped = [k for k in TOOL_FIELDS if k in d]
    if not dropped:
        return body
    for k in dropped:
        d.pop(k, None)
    log(f"共享面工具隔离: 剥掉 {','.join(dropped)}")
    return json.dumps(d).encode()


def _record_attempt(label, outcome):
    with _lock:
        _attempts.append({"leg": label, "outcome": outcome, "ts": time.time()})
        del _attempts[:-50]


def _fails_of(label):
    with _lock:
        return _fails.get(label, 0)


def _health_rank(label):
    """排序用的健康位：0 = 健康，1 = 不健康（冷却中 / 刚失败）⇒ 健康腿永远在前。"""
    return 0 if _healthy(label) else 1


def _healthy(label):
    with _lock:
        st = _bad.get(label)
        if st is None:
            return True
        exp, ttl = st
        if (time.time() - exp) > ttl:
            del _bad[label]            # 冷却到期即清除, /healthz 不留幽灵条目
            return True
        return False


def _mark_bad(label, code, net=False, ttl=None):
    ttl = ttl if ttl is not None else (BAD_TTL_NET if net else BAD_TTL_HTTP)
    with _lock:
        _bad[label] = (time.time(), ttl)
        _fails[label] = _fails.get(label, 0) + 1
        n = _fails[label]
    _stats["failovers"] += 1
    tag = "传输层" if net else "HTTP"
    extra = ""
    if n >= CIRCUIT_FAIL_THRESHOLD and ttl < BAD_TTL_CIRCUIT:
        # 连续失败达阈值 ⇒ 进**分钟级**熔断冷却（别再拿它当首选腿）
        with _lock:
            _bad[label] = (time.time(), BAD_TTL_CIRCUIT)
        ttl = BAD_TTL_CIRCUIT
        extra = f" ⇒ 熔断(连续失败 {n} 次)"
    log(f"{label} -> {tag} {code}, 降级 (冷却 {ttl}s){extra}")


def _mark_good(label):
    with _lock:
        _fails.pop(label, None)
        _bad.pop(label, None)


def _hold_worthwhile(labels):
    """全腿暂败后还值不值得保持请求等恢复。

    判据：任一腿**没被标坏**（未识别错误等 ⇒ 再试一轮不亏），或任一腿的
    冷却 TTL 是抖动/熔断档（< BAD_TTL_QUOTA）⇒ 值得等；全腿都是额度/腿级
    长冷却（600s）⇒ 等 90s 也不会恢复，立即收尾。
    """
    for label in labels:
        with _lock:
            st = _bad.get(label)
        if st is None:
            return True
        _exp, ttl = st
        if ttl < BAD_TTL_LEG:
            return True
    return False


def _mm_pref_label(keyed):
    """双 MiniMax **直连**腿都在本请求里且都健康时，按时间片给出本片优先腿；否则 None。

    只认 base_url 仍是官方 API 的腿：经环境变量改道去 macmini 网关的腿
    （aimax 的 macmini-mm）拓扑角色不同，不参与轮换。
    """
    if MM_ROTATE_SECONDS <= 0:
        return None
    pair = [c[0] for c in keyed
            if c[0]["label"] in MM_PAIR and c[0]["base"] == MM_API_BASE and c[2]]
    if len(pair) != 2:
        return None
    if not all(_healthy(leg["label"]) for leg in pair):
        return None
    return MM_PAIR[int(time.time() // MM_ROTATE_SECONDS) % 2]


def _mm_rank(leg, pref):
    """轮换排序项：本片优先腿 0，另一条 MiniMax 腿 1，其余腿 0（不扰动）。"""
    if pref is None or leg["label"] not in MM_PAIR:
        return 0
    return 0 if leg["label"] == pref else 1


def _is_quota(raw):
    """上游回的是"钱包见底"而不是"服务抖动" ⇒ 长冷却, 别白跑探测。"""
    try:
        t = raw.decode("utf-8", "replace")
    except Exception:
        return False
    return ("用量上限" in t or "Token Plan" in t or "usage_limit_exceeded" in t
            or "insufficient balance" in t or "quota" in t.lower())


def log(msg):
    print(f"[mm-failover {time.strftime('%H:%M:%S')}] {msg}", flush=True)


def _relax_timeout(resp, timeout):
    """把已建立连接的 socket 超时放宽到流式阶段的长超时。"""
    cands = []
    try:
        cands.append(resp.fp.raw._sock)
    except Exception:
        pass
    try:
        cands.append(resp.fp.raw)
    except Exception:
        pass
    for sock in cands:
        if sock is None:
            continue
        if hasattr(sock, "settimeout"):
            try:
                sock.settimeout(timeout)
                return True
            except Exception:
                pass
    return False


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "mm-failover/1.2"

    def do_POST(self): self._proxy("POST")
    def do_GET(self):  self._proxy("GET")

    def _proxy(self, method):
        global _inflight
        # 请求体**先**读完（哪怕随后要拒）：否则在 keep-alive 连接上留下残余字节 ⇒
        # 下一轮请求解析读到垃圾 ⇒ 连接状态不可预期。
        body = self._read_body()
        # ① 端点白名单：共享面只暴露指定端点，其余 404（车间操作面不在暴露面上）
        allowed = _allowed_paths()
        if allowed is not None and self.path.split("?")[0] not in allowed:
            self._json(404, {"error": {"message": "path not allowed on this endpoint",
                                       "type": "path_not_allowed"}})
            return
        # ② 共享令牌鉴权：仅在共享模式下启用（缺令牌 / 错令牌 ⇒ 401 熔断）
        if _shared_mode():
            tok = _token()
            if tok:
                hdr = self.headers.get("Authorization") or ""
                want = "Bearer " + tok
                if not hmac.compare_digest(hdr, want):
                    self._json(401, {"error": {"message": "unauthorized",
                                               "type": "unauthorized"}})
                    return
        # ③ 健康探测不占并发槽位（否则 /healthz 自己把 inflight 算成 1 ⇒ 看着像泄漏）
        if self.path.split("?")[0] == "/healthz":
            # Fuel gauge: 使用 minimax-primary 腿的状态
            legs = _legs()
            primary_label = None
            for leg in legs:
                if leg["label"] == "minimax-primary" and leg["enabled"]:
                    primary_label = leg["label"]
                    break
            if primary_label is None and legs:
                primary_label = legs[0]["label"]
            if primary_label is None:
                remaining_pct, next_reset, advice = 100, 0, "ALLOW_ALL"
            else:
                remaining_pct, next_reset, advice = _fuel_get_state(primary_label)
                remaining_pct = max(0, min(remaining_pct, 100))
            fuel_block = {
                "minimax_5h_remaining_pct": remaining_pct,
                "next_reset_in_sec": next_reset,
                "dispatch_advice": advice
            }
            return self._json(200, {"ok": True,
                "fuel_gauge": fuel_block,
                **self._snapshot()})
        # ④ 并发槽位：超限 ⇒ 429/503 自己扛，**不把 429 甩给上游**
        with _lock:
            if _inflight >= _max_concurrent():
                _stats["requests"] += 1
                over = True
            else:
                _inflight += 1
                over = False
        if over:
            self.send_response(503)
            self.send_header("Content-Type", "application/json")
            self.send_header("Retry-After", "1")
            body = json.dumps({"error": {"message": "too many concurrent requests",
                                          "type": "concurrency_limited"}}).encode()
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        try:
            self._proxy_locked(method, body)
        finally:
            with _lock:
                _inflight -= 1

    def _proxy_locked(self, method, body):
        with _lock:
            _stats["requests"] += 1
        if _strip_tools_enabled():
            body = _strip_tools(body)
        attempts = []
        deadline = time.time() + HOLD_BUDGET if HOLD_BUDGET > 0 else 0.0
        round_no = 0
        while True:
            round_no += 1
            if self._run_pass(method, body, attempts):
                return
            if getattr(self, "_resp_started", False):
                return                  # 已写过响应字节 ⇒ 不能再重试/改写
            labels = getattr(self, "_last_keyed", [])
            if not labels or not _hold_worthwhile(labels):
                break
            remain = deadline - time.time()
            if remain <= 0:
                break
            nap = min(HOLD_POLL, remain)
            log(f"全腿暂败, 保持请求等恢复 (第{round_no}轮未成, {nap:.0f}s 后重试, 保持预算剩 {remain:.0f}s)")
            time.sleep(nap)
        # 全部轮次都没接住: 若曾收到"未识别"的上游错误, 原样回传它(比合成的 502 真),
        # 免得客户端只看到一个"all upstreams exhausted"而丢掉真因。
        fatal = getattr(self, "_fatal", None)
        if fatal:
            code, raw = fatal
            log(f"全腿用尽, 回传首个上游错误 HTTP {code} ({len(raw)}B)")
            self._raw(code, raw)
            self._served("-", None, 0)
            return
        log("all upstreams exhausted: " + " | ".join(attempts))
        self._json(502, {"error": {"message": "all upstreams exhausted",
                                    "type": "failover_exhausted",
                                    "detail": attempts}})
        self._served("-", None, 0)

    def _run_pass(self, method, body, attempts):
        """跑一轮腿级联: 成功/已处理(含写出错误响应) ⇒ True; 全腿暂败且一字未写 ⇒ False。"""
        # 每条腿按"原生模型集"判定能不能接这个请求:
        #   原生腿 ⇒ 原样转发, 不改写;  替代腿 ⇒ 改写到该腿兜底模型;
        #   两者都不是 ⇒ 不适用本腿, 直接跳过(不浪费一次必败的上游请求)。
        req_model = _model_of(body)
        self._req_model = req_model
        keyed = []
        for leg in _legs():
            label = leg["label"]
            if not leg["enabled"]:
                attempts.append(f"{label}: 节点级禁用, 跳过")
                continue
            if not os.environ.get(leg["key_env"]):
                attempts.append(f"{label}: no {leg['key_env']}")
                continue
            native, target = leg["native"], leg["target"]
            if req_model in VERDICT_MODELS and not (
                    native is _is_claude_model and native(req_model)):
                # 裁决类请求禁用替代：只许 Claude 原生腿接。替代腿（baosi-grok）
                # 与非 Claude 原生腿一律跳过 ⇒ 强腿不在/冷却时 keyed 为空或独苗，
                # 收尾只能是 502「不判」，弱模型代判在归类段即被物理排除。
                attempts.append(f"{label}: 裁决类模型 {req_model} 禁用替代, 跳过")
                continue
            if native is not None and (req_model is None or native(req_model)):
                keyed.append((leg, None, True))          # 原生腿
            elif target is not None:
                keyed.append((leg, target, False))      # 替代腿
            else:
                attempts.append(f"{label}: 模型 {req_model or '?'} 不适用本腿, 跳过")
        # 排序：**健康度优先**，同健康度下原生腿在前（同组内保持表序）⇒
        #   刚失败/正在冷却的腿永远排在健康腿后面（健康腿先试），
        #   而「原生腿优先」只在**都健康**时才起作用（否则会压死健康兜底腿）。
        self._last_keyed = [c[0]["label"] for c in keyed]
        pref = _mm_pref_label(keyed)
        keyed.sort(key=lambda c: (_health_rank(c[0]["label"]), _fails_of(c[0]["label"]), 0 if c[2] else 1, _mm_rank(c[0], pref), c[0]["idx"]))
        if not keyed:
            log("all upstreams exhausted: 没有任何可用上游腿")
            self._json(502, {
                "error": {"message": "all upstreams exhausted",
                          "type": "failover_exhausted",
                          "detail": attempts}})
            self._served("-", None, 0)
            return True
        order = [c[0]["label"] for c in keyed]
        with _lock:
            _stats["last_order"] = order
        # 全部处于冷却期时不再直接回 502, 而是强制探测 —— 消灭 "cooling" 风暴。
        force = not any(_healthy(c[0]["label"]) for c in keyed)
        for leg, target, _native in keyed:
            label = leg["label"]
            if not _healthy(label):
                if not force:
                    attempts.append(f"{label}: cooling")
                    _record_attempt(label, "skipped-cooling")
                    continue
                attempts.append(f"{label}: 全冷却, 强制探测")
            rewrite = (lambda b, t=target, lb=label: _rewrite_model(b, t, lb)) if target else None
            try:
                note = self._attempt(leg, method, body, rewrite)
                if note is None:
                    return True                 # 已写响应
                attempts.append(f"{label}: {note}")
            except Exception as exc:
                if not getattr(self, "_resp_started", False) and len(keyed) == 1 and not getattr(self, "_retried_sole", False):
                    self._retried_sole = True
                    time.sleep(NET_RETRY_BACKOFF)
                    log(f"{label} 独苗腿传输层抖动 ({exc}), 原地重试 1 次")
                    try:
                        note = self._attempt(leg, method, body, rewrite)
                        if note is None:
                            return True
                        attempts.append(f"{label}: {note}")
                    except Exception as exc2:
                        exc = exc2
                _mark_bad(label, str(exc), net=True)
                _record_attempt(label, "exception")
                attempts.append(f"{label}: {exc}")
                if getattr(self, "_resp_started", False):
                    # 响应头已发出, 再写 502 只会污染字节流; 直接断开让客户端重试。
                    log(f"{label} 响应已开始, 中止 failover")
                    self.close_connection = True
                    return True
        return False

    def _attempt(self, leg, method, body, rewrite=None):
        """成功写完响应返回 None; 上游返回可重试状态返回原因串。"""
        label = leg["label"]
        url = leg["base"] + self.path
        key = os.environ.get(leg["key_env"], "")
        _orig_model = _model_of(body)
        if rewrite and body:
            body = rewrite(body)
        _sent_model = _model_of(body)
        _rewritten = 1 if (rewrite and _sent_model != _orig_model) else 0
        # #2142 v1.3：腿选定后、向上游发请求前 —— 推理降级（仅 baosi-grok 腿）
        # 与油量记账（每条腿的请求字节进滑动窗口）。
        _rewrote_to_grok = bool(rewrite and _sent_model == BAOSI_FALLBACK_MODEL
                                and _orig_model != BAOSI_FALLBACK_MODEL)
        body = _apply_reasoning(body, label, _rewrote_to_grok)
        _fuel_update(label, len(body) if body else 0)
        for i in range(NET_TRIES):
            req = urllib.request.Request(url, data=body, method=method)
            req.add_header("Authorization", "Bearer " + key)
            for k, v in self.headers.items():
                if k.lower() not in HOP_BY_HOP and k.lower() != "authorization":
                    req.add_header(k, v)
            if body is not None:
                req.add_header("Content-Type", self.headers.get("Content-Type",
                                                              "application/json"))
            try:
                # **分级超时**：连接 + 响应头 + 首字节都在 CONNECT_TIMEOUT 之内
                # （旧版这里是 900s ⇒ 一条死腿就能烧满一个工匠预算）。
                resp = urllib.request.urlopen(req, timeout=CONNECT_TIMEOUT)
            except urllib.error.HTTPError as e:
                raw = e.read()
                if e.code == 404:
                    # 模型族不匹配：该腿不支持请求的模型(如 minimax 腿请求 grok-model)
                    # ⇒ 直接跳过, 不计入 fails, 不触发 failover, 不记录冷却
                    _record_attempt(label, "http-404")
                    attempts.append(f"{label}: 404模型族不匹配, 跳过")
                    return f"HTTP 404 (模型族不匹配, 跳过)"
                if e.code in RETRYABLE:
                    # 标签必须由**性质**决定, 不能拿 TTL 数值当判据
                    # (BAD_TTL_QUOTA 与 BAD_TTL_LEG 现已解耦)。⇐
                    if _is_quota(raw):
                        ttl, why = BAD_TTL_QUOTA, "额度上限"
                        _fuel_record_2056(label, _fuel_bytes_in_window(label))
                    elif _classify(raw) == "leg":
                        ttl, why = BAD_TTL_LEG, "腿级"
                    else:
                        ttl, why = None, ""
                    _mark_bad(label, e.code, ttl=ttl)
                    _record_attempt(label, f"http-{e.code}")
                    return f"HTTP {e.code}" + (f" ({why})" if why else "")
                # 非可重试状态: 按错误性质分流:
                kind = _classify(raw)
                if kind == "req":
                    log(f"{label} -> HTTP {e.code} (请求级错误, 原样回传并断链)")
                    _record_attempt(label, f"http-{e.code}-req")
                    self._raw(e.code, raw)
                    self._served(label, _sent_model, _rewritten)
                    return None
                if kind is None:
                    # 未识别: 留档 —— 全腿用尽时原样回传它, 比合成的 502 真。
                    self._fatal = (e.code, raw)
                ttl = BAD_TTL_LEG if kind == "leg" else None
                _mark_bad(label, e.code, ttl=ttl)
                _record_attempt(label, f"http-{e.code}")
                return f"HTTP {e.code}" + (" (腿级)" if kind == "leg" else " (未识别, 继续下一腿)")
            except NET_ERRORS as exc:
                if i + 1 < NET_TRIES:
                    log(f"{label} 传输层错误, 同上游重试: {exc}")
                    time.sleep(NET_RETRY_BACKOFF)
                    continue
                # 传输层错误 ⇒ **换腿**（不换同腿：同腿重试只烧预算不改结果）
                log(f"{label} 传输层错误, 换下一条腿: {exc}")
                _mark_bad(label, str(exc), net=True)
                _record_attempt(label, "net-error")
                return f"传输层错误 {exc}"
            try:
                self._stream(label, resp)
            except _UpstreamTimeout as exc:
                # 首字节超时 ⇒ 响应头还没写给客户端 ⇒ 仍可换腿
                log(f"{label} 首字节超时({CONNECT_TIMEOUT}s), 换下一条腿")
                _mark_bad(label, str(exc), net=True)
                _record_attempt(label, "first-byte-timeout")
                return f"首字节超时 {exc}"
            _mark_good(label)
            _record_attempt(label, "ok")
            self._served(label, _sent_model, _rewritten)
            return None
        return "传输层错误重试用尽"

    def _stream(self, label, resp):
        log(f"{label} -> 200, 建立流 ({resp.headers.get('content-type','?')})")
        # 首字节仍在 CONNECT_TIMEOUT 之内（此时 socket 超时还是连接级的）；
        # 拿到首字节后才把超时放宽到流式长超时 ⇒ 长生成不会被误杀
        # （SSE 持续吐数据 ⇒ 每次 read 的窗口都被数据重置）。
        try:
            first = self._read_chunk(resp)
        except NET_ERRORS as exc:
            # 首字节超时 ⇒ 还没写过响应头 ⇒ 仍可换腿
            raise _UpstreamTimeout(str(exc))
        self._resp_started = True
        self.send_response(200)
        for k, v in resp.headers.items():
            if k.lower() not in HOP_BY_HOP:
                self.send_header(k, v)
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        total, upstream_fail = 0, None
        try:
            if first:
                total += len(first)
                self.wfile.write(b"%X\r\n" % len(first) + first + b"\r\n")
                self.wfile.flush()
            _relax_timeout(resp, UPSTREAM_TIMEOUT)
            while True:
                try:
                    chunk = self._read_chunk(resp)
                except NET_ERRORS as exc:
                    upstream_fail = exc      # 上游断流 ≠ 客户端断开, 分开处理
                    break
                if not chunk:
                    break
                total += len(chunk)
                self.wfile.write(b"%X\r\n" % len(chunk) + chunk + b"\r\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            log(f"{label} client disconnected after {total}B")
            return
        if upstream_fail is not None:
            # 不发终止块: 让客户端看到流异常从而重试, 同时把该上游短冷却。
            log(f"{label} 上游流中断 after {total}B: {upstream_fail}")
            self.close_connection = True
            raise upstream_fail
        try:
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            log(f"{label} client disconnected after {total}B")
            return
        log(f"{label} stream done, {total}B")

    def _read_chunk(self, resp):
        """读一块上游数据（read1 ⇒ 有数据就返回，不等满 16KB）。"""
        reader = getattr(resp, "read1", None)
        if reader is None:
            reader = resp.read
        return reader(16384)

    def _served(self, label, served_model, rewritten):
        """请求收尾对账行（attest 材料）：一调一行，说清最终由谁、用什么模型执行。

        只有「某条腿的响应真正交付到客户端」才记该腿名（`_attempt` 的 200 流
        与请求级错误原样回传两处）；全腿用尽的收尾记 leg=- served=-，表示
        无腿完成本调 —— 裁决类请求的「不判」在账面上就是这个形态。
        Beta 侧 attest 对账按 `leg=baosi-claude` + `rewritten=0` 在网关日志
        里取本调的正面证据；缺行记「未证」（设计 §3.2 第三项）。
        """
        req = getattr(self, "_req_model", None) or "-"
        log(f"SERVED req={req} leg={label} served={served_model or '-'} rewritten={rewritten}")

    def _raw(self, code, raw):
        ctype = "application/json"
        self._resp_started = True
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)
        return True

    def _json(self, code, obj):
        self._raw(code, json.dumps(obj).encode())

    def _read_body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else None

    def _snapshot(self):
        with _lock:
            now = time.time()
            cooling = {}
            for k, (t, ttl) in _bad.items():
                left = ttl - (now - t)
                if left > 0:                       # 过期条目不留幽灵
                    cooling[k] = int(left)
            legs = []
            for leg in _legs():
                st = _bad.get(leg["label"])
                left = 0
                if st:
                    left = max(0, int(st[1] - (now - st[0])))
                legs.append({"label": leg["label"], "enabled": leg["enabled"],
                             "base": leg["base"], "model": leg["target"],
                             "fails": _fails.get(leg["label"], 0),
                             "cooling_left": left})
            order = _stats.get("last_order", [])
            attempts = list(_attempts)
            inflight = _inflight
            return {"requests": _stats["requests"],
                    "failovers": _stats["failovers"],
                    "inflight": inflight,
                    "max_concurrent": _max_concurrent(),
                    "shared_mode": _shared_mode(),
                    "cooling": cooling,
                    "legs": legs,
                    "order": order,
                    "attempts": attempts}

    def log_message(self, *a):
        pass


def _rewrite_model(body, target, label):
    """替代腿: 本腿没有原生通道 ⇒ 把请求的模型改写成该腿的兜底模型。"""
    try:
        d = json.loads(body)
    except Exception:
        return body
    orig = d.get("model", "")
    if not orig or orig == target:
        return body
    d["model"] = target
    log(f"{label}: 模型 {orig} 本腿无原生通道 ⇒ 改用 {target}")
    return json.dumps(d).encode()


def _check_bind(host):
    """返回拒绝理由（None = 允许）。共享面**绝不**允许通配地址。"""
    h = (host or "").strip()
    if h in ("", "0.0.0.0", "*", "::", "[::]"):
        return (f"拒绝绑定通配地址 {h!r}: 网关持有上游密钥, 只允许绑**指定地址**"
                f"（如 Tailscale IP 100.76.189.39），0.0.0.0 会把网关裸奔到公网")
    return None


def main():
    bad = _check_bind(LISTEN_HOST)
    if bad:
        print("::error:: " + bad, file=sys.stderr)
        sys.exit(2)
    if _shared_mode() and not _token():
        print("::error:: 共享面（非回环绑定）必须设置 GIGAFAB_MM_TOKEN —— "
              "无令牌的网关不启动（fail-closed）", file=sys.stderr)
        sys.exit(2)
    missing = []
    for leg in _legs():
        if leg["enabled"] and not os.environ.get(leg["key_env"]):
            missing.append(leg["key_env"])
    if missing:
        log("WARNING missing env: " + ", ".join(sorted(set(missing))))
    log("upstreams: " + ", ".join(
        f"{leg['label']}({'原生判定' if leg['native'] else '替代→' + (leg['target'] or '-')}"
        f"{'→' + leg['target'] if (leg['native'] and leg['target']) else ''}"
        f"{'' if leg['enabled'] else ' [节点级禁用]'})"
        for leg in _legs()))
    log(f"listening on {LISTEN_HOST}:{LISTEN_PORT} "
        f"(shared={_shared_mode()}, token={'yes' if _token() else 'no'}, "
        f"connect_timeout={CONNECT_TIMEOUT}s, stream_timeout={UPSTREAM_TIMEOUT}s, "
        f"max_concurrent={_max_concurrent()})")
    srv = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    srv.daemon_threads = True
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        log("bye")


if __name__ == "__main__":
    main()
# B2 shadow F1 gateway change
