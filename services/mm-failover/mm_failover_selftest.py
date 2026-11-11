#!/usr/bin/env python3
"""mm-failover 自检（**带牙**）：改完代码先跑它，再重启服务。

全部用**本地假上游**（127.0.0.1 上的假 HTTP 服务），**不打真网**、不碰任何
真实凭证 ⇒ 任何 CI / 任何机器上都能复现同一组判决。

查二十一件事（每条都有稳定的机器名，供门禁做**变异自证**时点名）：
  1. graded-timeout   —— 一条死腿（连不上/不回话）+ 一条活腿 ⇒ 请求**在 ≤30s 内**
                          落到活腿（分级超时：连接/首字节短，流式长）。
  2. swap-leg         —— 传输层错误**换腿**不换同腿（同腿只被试一次）。
  3. cooldown-minutes —— 网络抖动 ⇒ **分钟级**冷却（旧版 5s ⇒ 刚挂的腿立刻又被选中）。
  4. health-order     —— 刚失败/正在冷却的腿**排后**，健康腿先试。
  5. leg-disable      —— 节点级腿配置：关掉某腿 ⇒ 该腿不进请求路径，请求仍成功。
  6. token-auth       —— 共享面：缺令牌 ⇒ 401；错令牌 ⇒ 401；对令牌 ⇒ 200。
  7. path-allowlist   —— 共享面：**只**暴露 /v1/chat/completions（+ /healthz），其余 404。
  8. tools-strip      —— 共享面：工具面被剥掉（上游收到的 body 里没有 tools）。
  9. concurrency-limit—— 共享面并发槽位：超限 ⇒ 503（不把 429 甩给上游），计数必须回落。
 10. bind-refusal     —— 拒绝绑 0.0.0.0（网关持有密钥，绝不裸奔到公网）。
 11. hold-retry       —— 唯一可用腿先 503、数秒后恢复 ⇒ 请求被**保持**到恢复
                          并 200，而不是立刻吃 502（保持预算/粒度自检内调小）。
 12. hold-skips-quota —— 全腿都是额度/腿级长冷却（600s）⇒ **不保持**，立即收尾。
 13. mm-rotate        —— 双 MiniMax 直连腿时间片轮换：相邻时间片优先腿互换；
                          改道腿（base_url 非官方 API）不参与轮换。
 14. verdict-no-substitute —— 裁决类点名 claude-opus-5-5 + Claude 腿禁用
                          ⇒ 502「不判」且替代腿零执行（先以 Flash 机械流量
                          作对照证替代路本身活着，防「全仓都 502」的假绿）。
 15. verdict-hold-then-502 —— Claude 腿短冷却暂败 ⇒ HOLD 预算耗尽后 502，
                          全程零替代尝试（强腿不可用只回不判，不代判）。
 16. verdict-mechanical-regression —— 机械面回归钉：Flash + 双 MiniMax 腿败
                          ⇒ baosi-grok 替代照旧执行、改写照旧，且 SERVED
                          对账行记 rewritten=1（强模型道不许误伤机械面）。
 17. reasoning-none-grok —— none 档：baosi-grok 腿 reasoning.effort 置 none
                          且去掉 summary（reasoning_effort 顶层字段同改）。
 18. reasoning-none-minimax-untouched —— none 档：MiniMax 腿请求体逐字未改
                         （raw bytes 对照），且请求字节进了油量账本。
 19. reasoning-keep     —— keep 档（默认）：grok 腿 reasoning 原样不动。
 20. reasoning-auto      —— auto 档：改写成 grok-4.7 才降级；原生 grok 不降级。
 21. fuel-gauge-*        —— 油量表：滑动窗口（窗口外事件滑出）、C_max 由 2056
                          触发反标定、t_reset = t_2056 + 5h、剩余 <15% ⇒
                          LOW_COMPLEXITY_ONLY、无 2056 历史不编 c_max、
                          /healthz 三字段齐全且窗口常量 18000s。

用法: python3 <本文件路径>
退出码 0 = 全过。
"""
import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ── 先把测试用的超时/凭证摆好，再 import 被测模块 ────────────────────────
# 连接/首字节超时压到 2s ⇒ 「死腿 + 活腿」这条断言跑得快；被测模块在 import 时读它。
os.environ["MM_FAILOVER_CONNECT_TIMEOUT"] = "2"
os.environ["MM_FAILOVER_HOLD_BUDGET"] = "10"   # 保持总预算压到 10s ⇒ hold 场景跑得快
# 地板：场景 11 的恢复点是 3.5s，预算必须 > 恢复点 + 一轮 poll(1s) + 调度裕度；
# 10s 留约 6s 裕度。场景 15 烧满预算（下界按 60% 规则取 6s）。生产默认 90s 不动。
os.environ["MM_FAILOVER_HOLD_POLL"] = "1"      # 保持轮询粒度 1s
for _k in ("MINIMAX_API_KEY_PRIMARY", "MINIMAX_API_KEY_SECONDARY",
           "BAOSIAPI_API_KEY"):
    os.environ[_k] = "x"          # 假凭证：只让腿「有钥匙」，值无意义

# 共享令牌：自检**自己**管它 —— 宿主环境里可能带着真令牌（§1316 密钥卫生），
# 自检既不能依赖它、也绝不能把它打印出来 ⇒ 先清掉，需要时再摆一个假的。
os.environ.pop("GIGAFAB_MM_TOKEN", None)
os.environ.pop("MM_FAILOVER_TOKEN", None)

# 路径**相对本文件** ⇒ 仓内镜像与宿主副本都能自检（不写死 ~/.local/bin/…）。
# 且**两种命名都要认**：仓内快照叫 `mm_failover.py`，而部署器装到宿主时
# 沿用原名 `mm-failover.py`（launchd plist 指向的就是那个名字）。
_HERE = os.path.dirname(os.path.abspath(__file__))
for _cand in ("mm_failover.py", "mm-failover.py"):
    if os.path.exists(os.path.join(_HERE, _cand)):
        PATH = os.path.join(_HERE, _cand)
        break
else:
    raise SystemExit("cannot find the gateway module next to this file (mm_failover.py / mm-failover.py)")
FAILS = []
CTX = {}


def check(name, cond, detail=""):
    print(f"{'PASS' if cond else '**FAIL**'} {name}" + (f" :: {detail}" if detail else ""))
    if not cond:
        FAILS.append(name)


# 1. import
spec = importlib.util.spec_from_file_location("mmf", PATH)
mmf = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(mmf)
    check("module-import", True)
except Exception as e:
    check("module-import", False, repr(e))
    sys.exit(1)

# 2. UPSTREAMS 结构
ok_shape, detail = True, ""
for u in mmf.UPSTREAMS:
    if not isinstance(u, tuple) or len(u) != 5:
        ok_shape = False
        detail = f"元组长度异常: {u}"
        break
check("upstreams-shape", ok_shape, detail)

# 4. 自洽性: 替代腿(native=None)必须有兜底模型; 原生腿的判定必须可调用
ok_self = True
detail = ""
for l, b, e, native, target in mmf.UPSTREAMS:
    if native is None and not target:
        ok_self, detail = False, f"{l}: 替代腿缺兜底模型"
    if native is not None and not callable(native):
        ok_self, detail = False, f"{l}: 原生判定不可调用"
check("upstreams-selfconsistent", ok_self, detail)


# ── 假上游（不打真网）────────────────────────────────────────────────────
class _Fake:
    """本地假上游：live（200）/ hang（连上但永不回话）/ slow（延迟 N 秒）。"""

    def __init__(self, mode="live", delay=0.0, recover_after=None,
                 fixed_status=None, fixed_body=b""):
        self.mode = mode
        self.delay = delay
        self.recover_until = time.time() + recover_after if recover_after else 0.0
        self.fixed_status = fixed_status
        self.fixed_body = fixed_body
        self.requests = []
        outer = self

        class H(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *a):
                pass

            def do_POST(self):
                self._go()

            def do_GET(self):
                self._go()

            def _go(self):
                n = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(n) if n else b""
                outer.requests.append({"path": self.path, "body": body,
                                       "auth": self.headers.get("Authorization")})
                if outer.mode == "hang":
                    time.sleep(30)
                    return
                if outer.mode == "recover" and time.time() < outer.recover_until:
                    payload = b'{"error":{"message":"backend busy, try later"}}'
                    self.send_response(503)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                    return
                if outer.mode == "fixed":
                    payload = outer.fixed_body
                    self.send_response(outer.fixed_status)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                    return
                if outer.delay:
                    time.sleep(outer.delay)
                model = None
                try:
                    model = (json.loads(body) or {}).get("model")
                except Exception:
                    pass
                payload = json.dumps({"model": model, "ok": True}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.srv.daemon_threads = True
        self.port = self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    @property
    def url(self):
        return f"http://127.0.0.1:{self.port}"

    def stop(self):
        try:
            self.srv.shutdown()
            self.srv.server_close()
        except Exception:
            pass


def _reset_state():
    """清掉腿级健康/冷却状态 ⇒ 每个场景从同一起点开始。"""
    with mmf._lock:
        mmf._bad.clear()
        mmf._fails.clear()
        mmf._attempts.clear()
        for _d in ("_fuel_events", "_fuel_cmax", "_fuel_last_2056"):
            _m = getattr(mmf, _d, None)
            if isinstance(_m, dict):
                _m.clear()


def _env(**kw):
    """设置/清除环境变量（None = 清除）。"""
    for k, v in kw.items():
        if v is None:
            os.environ.pop(k, None)
        else:
            os.environ[k] = str(v)


def _clear_leg_env():
    for leg in mmf.UPSTREAMS:
        tag = mmf._leg_env(leg[0], "BASE_URL")
        os.environ.pop(tag, None)


def _post(path, body=None, token=None, timeout=20):
    """POST 一个 JSON 请求 ⇒ 返回 (status, payload_bytes)。"""
    data = json.dumps(body or {}).encode()
    req = urllib.request.Request(GW_URL + path, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    if token is not None:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def _post_capturing(path, body=None, token=None, timeout=20, expect=None):
    """同 _post，但把网关日志（SERVED 对账行所在）捕获回来供断言。

    log() 写 sys.stdout 且 flush —— 重定向窗口覆盖整个请求生命周期即可
    把处理线程的对账行收齐；假上游不打日志，不会污染捕获面。
    竞态钉（2026-10-31 施工批实测修正）：SERVED 行由处理线程在响应写完
    **之后**才打印，客户端读满响应体先返回 ⇒ 不同步等就会间歇漏捕（部署器
    内重跑自检时实测翻红一次）。传 expect 时在重定向窗内等该行落账
    （≤5s），等不到才原样返回让断言判红 —— 同步点在行不在时序猜测。
    """
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        st, payload = _post(path, body, token=token, timeout=timeout)
        if expect:
            _deadline = time.time() + 5
            while expect not in buf.getvalue() and time.time() < _deadline:
                time.sleep(0.05)
    return st, payload, buf.getvalue()


def _health():
    with urllib.request.urlopen(GW_URL + "/healthz", timeout=10) as r:
        return json.loads(r.read())


def _reset_legs():
    """把四条腿还原成「默认表 + 无覆盖」，再由场景自己摆。"""
    _clear_leg_env()
    _env(MM_FAILOVER_DISABLED_LEGS=None, MM_FAILOVER_LEG_ORDER=None,
         MM_FAILOVER_SHARED_MODE=None, MM_FAILOVER_ALLOWED_PATHS=None,
         MM_FAILOVER_STRIP_TOOLS=None, MM_FAILOVER_MAX_CONCURRENT=None,
         MM_FAILOVER_BAOSI_REASONING=None,
         GIGAFAB_MM_TOKEN=None, MM_FAILOVER_TOKEN=None)


# 3. 真起一遍 + healthz
srv = ThreadingHTTPServer(("127.0.0.1", 0), mmf.Handler)
srv.daemon_threads = True
threading.Thread(target=srv.serve_forever, daemon=True).start()
GW_URL = f"http://127.0.0.1:{srv.server_address[1]}"
time.sleep(0.2)
try:
    payload = _health()
    check("gateway-starts", payload.get("ok") is True, json.dumps(payload, ensure_ascii=False))
except Exception as e:
    check("gateway-starts", False, repr(e))
    sys.exit(1)

# ══ 场景 1/2/3/4：死腿 + 活腿 ⇒ 分级超时 / 换腿 / 冷却 / 健康排序 ═══════
_reset_legs()
_reset_state()
hang = _Fake("hang")
live = _Fake("live")
_env(MM_FAILOVER_LEG_MINIMAX_PRIMARY_BASE_URL=hang.url,
     MM_FAILOVER_LEG_BAOSI_GROK_BASE_URL=live.url,
     MM_FAILOVER_DISABLED_LEGS="minimax-secondary")

_t0 = time.time()
try:
    _status, _payload = _post("/v1/chat/completions", {"model": "minimax-m3.1-flash"})
    _err = None
except Exception as e:                       # 被测对象超时 ⇒ 断言失败（不挂住）
    _status, _payload, _err = None, b"", repr(e)
_elapsed = time.time() - _t0
# 竞态钉（变异测量中 3/23 同签名翻红）：客户端读满响应体先返回，而处理线程
# 的 _record_attempt("ok") 还在响应写完之后 —— 紧接着的 _health() 可能抢在
# 落账之前快照 _attempts，baosi-grok 的 ok 记录还没进去 ⇒ swap-leg 间歇红。
# 等该记录落账再断言（≤5s，轮询的是断言本身读的数据，不是时序猜测）；
# 等不到（真失败）则原样读数，断言照常判红。只等 baosi-grok：minimax-primary
# 的 net-error 记录在 baosi-grok 尝试开始前就已落账，不竞态。
_health1 = _health()
_deadline = time.time() + 5
while ("baosi-grok" not in [a["leg"] for a in (_health1.get("attempts") or [])]
       and time.time() < _deadline):
    time.sleep(0.05)
    _health1 = _health()

check("graded-timeout",
      _err is None and _status == 200 and _elapsed <= 30,
      f"status={_status} elapsed={_elapsed:.1f}s err={_err}")
check("graded-timeout-live-leg",
      _err is None and _status == 200 and _elapsed < 15,
      f"必须**先**烧掉死腿的连接超时再落到活腿: elapsed={_elapsed:.1f}s")
try:
    _served_by = json.loads(_payload).get("model")
except Exception:
    _served_by = None
check("graded-timeout-fallback-model",
      _served_by == mmf.BAOSI_FALLBACK_MODEL,
      f"活腿应当是替代腿 ⇒ 模型被改写为 {mmf.BAOSI_FALLBACK_MODEL}, 实得 {_served_by}")

_attempts = _health1.get("attempts") or []
_legs_tried = [a["leg"] for a in _attempts]
check("swap-leg",
      _legs_tried.count("minimax-primary") == 1 and "baosi-grok" in _legs_tried,
      f"传输层错误必须**换腿**：尝试序列={_legs_tried}")
_cool = (_health1.get("cooling") or {}).get("minimax-primary", 0)
check("cooldown-minutes", _cool >= 30, f"网络抖动的冷却必须是分钟级, 实得 {_cool}s")

# 健康排序：死腿在冷却 ⇒ 下一轮健康腿先试（不该再烧一次死腿的连接超时）
_t1 = time.time()
try:
    _status2, _payload2 = _post("/v1/chat/completions", {"model": "minimax-m3.1-flash"})
    _err2 = None
except Exception as e:
    _status2, _err2 = None, repr(e)
_elapsed2 = time.time() - _t1
_health2 = _health()
_order = _health2.get("order") or []
check("health-order",
      _err2 is None and _status2 == 200 and _elapsed2 < 1.5 and _order[:1] == ["baosi-grok"],
      f"冷却中的腿必须排后: order={_order} elapsed={_elapsed2:.2f}s")

# ══ 场景 5：节点级腿配置（关掉某腿）══════════════════════════════════
_reset_legs()
_reset_state()
hang2 = _Fake("hang")
live2 = _Fake("live")
_env(MM_FAILOVER_LEG_MINIMAX_PRIMARY_BASE_URL=hang2.url,
     MM_FAILOVER_LEG_MINIMAX_SECONDARY_BASE_URL=hang2.url,
     MM_FAILOVER_LEG_BAOSI_GROK_BASE_URL=live2.url,
     MM_FAILOVER_DISABLED_LEGS="minimax-primary,minimax-secondary")
_t2 = time.time()
try:
    _status3, _payload3 = _post("/v1/chat/completions", {"model": "minimax-m3.1-flash"})
    _err3 = None
except Exception as e:
    _status3, _err3 = None, repr(e)
_elapsed3 = time.time() - _t2
_health3 = _health()
_tried3 = [a["leg"] for a in (_health3.get("attempts") or [])]
_disabled_ok = all(not l.get("enabled") for l in (_health3.get("legs") or [])
                   if l.get("label", "").startswith("minimax"))
check("leg-disable",
      _err3 is None and _status3 == 200 and _elapsed3 < 1.5
      and not any(t.startswith("minimax") for t in _tried3) and _disabled_ok,
      f"关掉的腿不得进请求路径: 尝试序列={_tried3} elapsed={_elapsed3:.2f}s "
      f"legs_enabled={[(l['label'], l['enabled']) for l in (_health3.get('legs') or [])]}")

# ══ 场景 6/7/8：共享面护栏（令牌 / 端点白名单 / 工具隔离）══════════════
_reset_legs()
_reset_state()
live3 = _Fake("live")
_env(MM_FAILOVER_LEG_BAOSI_GROK_BASE_URL=live3.url,
     MM_FAILOVER_DISABLED_LEGS="minimax-primary,minimax-secondary",
     MM_FAILOVER_SHARED_MODE="1",
     GIGAFAB_MM_TOKEN="fake-tok-01")

_s_no, _b_no = _post("/v1/chat/completions", {"model": "grok-4.7"})
_s_bad, _b_bad = _post("/v1/chat/completions", {"model": "grok-4.7"}, token="wrong")
_s_ok, _b_ok = _post("/v1/chat/completions", {"model": "grok-4.7"},
                     token="fake-tok-01")
check("token-auth",
      _s_no == 401 and _s_bad == 401 and _s_ok == 200,
      f"缺令牌/错令牌必须 401，对令牌才 200: no={_s_no} wrong={_s_bad} right={_s_ok}")

_s_responses, _b_responses = _post("/v1/responses", {"model": "grok-4.7"},
                                    token="fake-tok-01")
_s_root, _b_root = _post("/", {}, token="fake-tok-01")
check("path-allowlist",
      _s_responses == 404 and _s_root == 404 and _s_ok == 200,
      f"共享面只暴露 /v1/chat/completions: /v1/responses={_s_responses} /={_s_root}")

_before = len(live3.requests)
_post("/v1/chat/completions",
      {"model": "grok-4.7", "tools": [{"type": "function", "function": {"name": "rm"}}],
       "tool_choice": "auto"},
      token="fake-tok-01")
_up_body = live3.requests[-1]["body"] if len(live3.requests) > _before else b""
try:
    _up_json = json.loads(_up_body) if _up_body else {}
except Exception:
    _up_json = {}
check("tools-strip",
      bool(_up_body) and "tools" not in _up_json and "tool_choice" not in _up_json,
      f"共享面必须剥掉工具面（纯文本补全代理）: 上游收到的键={sorted(_up_json.keys())}")

# ══ 场景 9：并发槽位（超限 ⇒ 自己扛 503，计数必须回落）═════════════════
_reset_legs()
_reset_state()
slow = _Fake("live", delay=1)   # 必须 < CONNECT_TIMEOUT(2s)，否则测的是超时不是并发
_env(MM_FAILOVER_LEG_BAOSI_GROK_BASE_URL=slow.url,
     MM_FAILOVER_DISABLED_LEGS="minimax-primary,minimax-secondary",
     MM_FAILOVER_SHARED_MODE="0", MM_FAILOVER_MAX_CONCURRENT="2")
_results = []


def _fire():
    try:
        st, _ = _post("/v1/chat/completions", {"model": "grok-4.7"}, timeout=30)
        _results.append(st)
    except Exception as e:
        _results.append(repr(e))


_threads = [threading.Thread(target=_fire) for _ in range(4)]
for _t in _threads:
    _t.start()
for _t in _threads:
    _t.join(40)
_limit_hits = [r for r in _results if r == 503]
_ok_hits = [r for r in _results if r == 200]
time.sleep(0.3)          # 让请求收尾的 finally 跑完（并发计数必须回落）
_h9 = _health()
check("concurrency-limit",
      len(_limit_hits) >= 1 and len(_ok_hits) >= 1 and _h9.get("inflight") == 0,
      f"超限必须被自己挡住(503)且不甩给上游: 结果={_results} 回落后 inflight={_h9.get('inflight')}")

# ══ 场景 11：保持重试（唯一腿先 503、3.5s 后恢复 ⇒ 请求等到恢复）══════
_reset_legs()
_reset_state()
rec = _Fake("recover", recover_after=3.5)
_env(MM_FAILOVER_LEG_BAOSI_GROK_BASE_URL=rec.url,
     MM_FAILOVER_DISABLED_LEGS="minimax-primary,minimax-secondary")
_t3 = time.time()
try:
    _status4, _payload4 = _post("/v1/chat/completions", {"model": "grok-4.7"}, timeout=40)
    _err4 = None
except Exception as e:
    _status4, _err4 = None, repr(e)
_elapsed4 = time.time() - _t3
check("hold-retry",
      _err4 is None and _status4 == 200 and 3 <= _elapsed4 <= 10,
      f"唯一腿 3.5s 后恢复 ⇒ 请求应被保持到恢复: status={_status4} elapsed={_elapsed4:.1f}s err={_err4}")

# ══ 场景 12：全腿长冷却（额度/腿级 600s）⇒ 不保持，立即收尾 ═══════════
_reset_legs()
_reset_state()
quota = _Fake("fixed", fixed_status=402,
              fixed_body='{"error":{"message":"Token Plan 用量上限 usage_limit_exceeded"}}'.encode())
legbad = _Fake("fixed", fixed_status=400,
               fixed_body=b'{"error":{"message":"model_not_found"}}')
_env(MM_FAILOVER_LEG_MINIMAX_PRIMARY_BASE_URL=quota.url,
     MM_FAILOVER_LEG_MINIMAX_SECONDARY_BASE_URL=quota.url,
     MM_FAILOVER_LEG_BAOSI_GROK_BASE_URL=legbad.url)
_t4 = time.time()
try:
    _status5, _payload5 = _post("/v1/chat/completions", {"model": "minimax-m3.1-flash"}, timeout=40)
    _err5 = None
except Exception as e:
    _status5, _err5 = None, repr(e)
_elapsed5 = time.time() - _t4
check("hold-skips-quota",
      _err5 is None and _status5 == 502 and _elapsed5 < 8,
      f"全腿 600s 长冷却 ⇒ 不值得保持, 应立即 502: status={_status5} elapsed={_elapsed5:.1f}s err={_err5}")

# ══ 场景 13：双 MiniMax 腿时间片轮换（单元级）═════════════════════════
_reset_state()
_old_rotate = mmf.MM_ROTATE_SECONDS
_old_time = time.time
try:
    mmf.MM_ROTATE_SECONDS = 100
    _rows = [({"label": "minimax-primary", "base": "https://api.minimaxi.com"}, None, True),
             ({"label": "minimax-secondary", "base": "https://api.minimaxi.com"}, None, True)]
    time.time = lambda: 1000.0
    _pref_a = mmf._mm_pref_label(_rows)
    time.time = lambda: 1100.0
    _pref_b = mmf._mm_pref_label(_rows)
    _rows_relay = [({"label": "minimax-primary", "base": "http://100.76.189.39:4180"}, None, True),
                   _rows[1]]
    time.time = lambda: 1000.0
    _pref_c = mmf._mm_pref_label(_rows_relay)
finally:
    time.time = _old_time
    mmf.MM_ROTATE_SECONDS = _old_rotate
check("mm-rotate",
      _pref_a == "minimax-primary" and _pref_b == "minimax-secondary" and _pref_c is None,
      f"相邻时间片优先腿应互换, 改道腿不参与: sliceA={_pref_a} sliceB={_pref_b} relay={_pref_c}")

# ══ 场景 14：裁决类禁用替代（先以机械流量作对照证替代路活着）══════════
# 对照面：Flash 点名 + 双 MiniMax 腿 503 ⇒ baosi-grok 替代必须照旧执行（200、
# 改写为兜底模型）；随后仅关掉 Claude 腿、点名 claude-opus-5-5 ⇒ 只许 502
# 「不判」，且 grok 假上游零新增命中、SERVED 记 leg=-。
_reset_legs()
_reset_state()
_mm503a = _Fake("fixed", fixed_status=503, fixed_body=b'{"error":{"message":"backend busy"}}')
_mm503b = _Fake("fixed", fixed_status=503, fixed_body=b'{"error":{"message":"backend busy"}}')
_grok_ctl = _Fake("live")
_claude_ctl = _Fake("live")
_env(MM_FAILOVER_LEG_MINIMAX_PRIMARY_BASE_URL=_mm503a.url,
     MM_FAILOVER_LEG_MINIMAX_SECONDARY_BASE_URL=_mm503b.url,
     MM_FAILOVER_LEG_BAOSI_GROK_BASE_URL=_grok_ctl.url,
     MM_FAILOVER_LEG_BAOSI_CLAUDE_BASE_URL=_claude_ctl.url)
_s_ctl, _p_ctl = _post("/v1/chat/completions", {"model": "MiniMax-M3.1-Flash"})
try:
    _ctl_model = json.loads(_p_ctl).get("model")
except Exception:
    _ctl_model = None
_grok_hits_ctl = len(_grok_ctl.requests)
_reset_state()
_env(MM_FAILOVER_DISABLED_LEGS="baosi-claude")
_s_v, _p_v, _cap_v = _post_capturing("/v1/chat/completions", {"model": "claude-opus-5-5"},
                                     expect="SERVED req=claude-opus-5-5 leg=- served=- rewritten=0")
check("verdict-no-substitute",
      _s_ctl == 200 and _ctl_model == mmf.BAOSI_FALLBACK_MODEL and _grok_hits_ctl >= 1
      and _s_v == 502 and len(_grok_ctl.requests) == _grok_hits_ctl
      and len(_claude_ctl.requests) == 0
      and "SERVED req=claude-opus-5-5 leg=- served=- rewritten=0" in _cap_v,
      f"对照(Flash⇒grok替代200) status={_s_ctl} model={_ctl_model} grok_hits={_grok_hits_ctl}; "
      f"裁决点名+Claude腿禁用 ⇒ 只许 502: status={_s_v} grok_hits={len(_grok_ctl.requests)} "
      f"claude_hits={len(_claude_ctl.requests)}")
_mm503a.stop(); _mm503b.stop(); _grok_ctl.stop(); _claude_ctl.stop()

# ══ 场景 15：Claude 腿短冷却暂败 ⇒ HOLD 耗尽后 502、零替代 ════════════
_reset_legs()
_reset_state()
_claude_503 = _Fake("fixed", fixed_status=503, fixed_body=b'{"error":{"message":"backend busy, try later"}}')
_grok_hold = _Fake("live")
_env(MM_FAILOVER_LEG_BAOSI_CLAUDE_BASE_URL=_claude_503.url,
     MM_FAILOVER_LEG_BAOSI_GROK_BASE_URL=_grok_hold.url,
     MM_FAILOVER_DISABLED_LEGS="minimax-primary,minimax-secondary")
_t15 = time.time()
_s_h, _p_h, _cap_h = _post_capturing("/v1/chat/completions", {"model": "claude-opus-5-5"}, timeout=60,
                                     expect="SERVED req=claude-opus-5-5 leg=- served=- rewritten=0")
_elapsed_h = time.time() - _t15
check("verdict-hold-then-502",
      _s_h == 502 and len(_grok_hold.requests) == 0 and len(_claude_503.requests) >= 2
      and _elapsed_h >= 6
      and "SERVED req=claude-opus-5-5 leg=- served=- rewritten=0" in _cap_h,
      f"Claude 腿暂败(503/短冷却) ⇒ 保持预算耗尽后 502、grok 零执行: status={_s_h} "
      f"elapsed={_elapsed_h:.1f}s claude_hits={len(_claude_503.requests)} grok_hits={len(_grok_hold.requests)}")
_claude_503.stop(); _grok_hold.stop()

# ══ 场景 16：机械面回归钉（替代照旧 + SERVED 记 rewritten=1）══════════
_reset_legs()
_reset_state()
_mm503c = _Fake("fixed", fixed_status=503, fixed_body=b'{"error":{"message":"backend busy"}}')
_mm503d = _Fake("fixed", fixed_status=503, fixed_body=b'{"error":{"message":"backend busy"}}')
_grok_reg = _Fake("live")
_claude_reg = _Fake("live")
_env(MM_FAILOVER_LEG_MINIMAX_PRIMARY_BASE_URL=_mm503c.url,
     MM_FAILOVER_LEG_MINIMAX_SECONDARY_BASE_URL=_mm503d.url,
     MM_FAILOVER_LEG_BAOSI_GROK_BASE_URL=_grok_reg.url,
     MM_FAILOVER_LEG_BAOSI_CLAUDE_BASE_URL=_claude_reg.url)
_s_m, _p_m, _cap_m = _post_capturing("/v1/chat/completions", {"model": "MiniMax-M3.1-Flash"},
                                     expect="SERVED req=MiniMax-M3.1-Flash leg=baosi-grok served=grok-4.7 rewritten=1")
try:
    _m_model = json.loads(_p_m).get("model")
except Exception:
    _m_model = None
_grok_sent = None
if _grok_reg.requests:
    try:
        _grok_sent = json.loads(_grok_reg.requests[-1]["body"]).get("model")
    except Exception:
        _grok_sent = None
check("verdict-mechanical-regression",
      _s_m == 200 and _m_model == mmf.BAOSI_FALLBACK_MODEL and _grok_sent == mmf.BAOSI_FALLBACK_MODEL
      and "SERVED req=MiniMax-M3.1-Flash leg=baosi-grok served=grok-4.7 rewritten=1" in _cap_m,
      f"机械面不许误伤: Flash+双 MiniMax 腿败 ⇒ grok 替代照旧+改写留痕: status={_s_m} "
      f"model={_m_model} sent={_grok_sent}")
_mm503c.stop(); _mm503d.stop(); _grok_reg.stop(); _claude_reg.stop()

# ══ 场景 17–21：#2142 v1.3 推理开关 (keep/none/auto) + /healthz 油量表 ══
# 推理开关只许动 baosi-grok 腿；MiniMax 腿请求体必须逐字未改；油量表是
# 纯内存滑动账本（零新增常驻），剩余占比 <15% 才建议只派低复杂度任务。
_reset_legs()
_reset_state()
_grok_r = _Fake("live")
_env(MM_FAILOVER_LEG_BAOSI_GROK_BASE_URL=_grok_r.url,
     MM_FAILOVER_DISABLED_LEGS="minimax-primary,minimax-secondary",
     MM_FAILOVER_BAOSI_REASONING="none")
_body_r = {"model": "grok-4.7",
           "reasoning": {"effort": "high", "summary": "detailed"},
           "reasoning_effort": "high",
           "messages": [{"role": "user", "content": "ping"}]}
_s_r, _p_r = _post("/v1/chat/completions", _body_r)
_up_r = json.loads(_grok_r.requests[-1]["body"]) if _grok_r.requests else {}
check("reasoning-none-grok",
      _s_r == 200 and _up_r.get("reasoning", {}).get("effort") == "none"
      and "summary" not in _up_r.get("reasoning", {})
      and _up_r.get("reasoning_effort") == "none",
      f"none 档：baosi-grok 腿 reasoning.effort 必须置 none 且去掉 summary: "
      f"上游收到 reasoning={_up_r.get('reasoning')} reasoning_effort={_up_r.get('reasoning_effort')}")
_grok_r.stop()

# none 档 + MiniMax 腿：请求体逐字未改（raw bytes 对照）+ 油量账本已记账
_reset_legs()
_reset_state()
_mm_r = _Fake("live")
_env(MM_FAILOVER_LEG_MINIMAX_PRIMARY_BASE_URL=_mm_r.url,
     MM_FAILOVER_DISABLED_LEGS="minimax-secondary,baosi-grok,baosi-claude",
     MM_FAILOVER_BAOSI_REASONING="none")
_body_mm = {"model": "MiniMax-M3.1-Flash",
            "reasoning": {"effort": "high", "summary": "detailed"},
            "reasoning_effort": "high",
            "messages": [{"role": "user", "content": "ping"}]}
_raw_r = json.dumps(_body_mm).encode()
_s_mr, _p_mr = _post("/v1/chat/completions", _body_mm)
_up_raw = _mm_r.requests[-1]["body"] if _mm_r.requests else b""
_fuel_after = mmf._fuel_bytes_in_window("minimax-primary")
check("reasoning-none-minimax-untouched",
      _s_mr == 200 and _up_raw == _raw_r,
      f"none 档：MiniMax 腿请求体必须逐字未改: 收到 {len(_up_raw)}B, 原样 {len(_raw_r)}B, 相等={_up_raw == _raw_r}")
check("fuel-update-wired",
      _fuel_after == len(_raw_r),
      f"请求路径必须记账：油量账本里 minimax-primary 窗口字节应为 {len(_raw_r)}B, 实得 {_fuel_after}B")
_mm_r.stop()

# keep 档（默认）：grok 腿 reasoning 原样不动
_reset_legs()
_reset_state()
_grok_k = _Fake("live")
_env(MM_FAILOVER_LEG_BAOSI_GROK_BASE_URL=_grok_k.url,
     MM_FAILOVER_DISABLED_LEGS="minimax-primary,minimax-secondary",
     MM_FAILOVER_BAOSI_REASONING="keep")
_s_k, _p_k = _post("/v1/chat/completions", _body_r)
_up_k = json.loads(_grok_k.requests[-1]["body"]) if _grok_k.requests else {}
check("reasoning-keep",
      _s_k == 200 and _up_k.get("reasoning", {}).get("effort") == "high"
      and _up_k.get("reasoning", {}).get("summary") == "detailed"
      and _up_k.get("reasoning_effort") == "high",
      f"keep 档：grok 腿 reasoning 必须原样不动: 上游收到 reasoning={_up_k.get('reasoning')}")
_grok_k.stop()

# auto 档：改写成 grok-4.7 才降级；原生 grok 不降级
_reset_legs()
_reset_state()
_grok_a = _Fake("live")
_mm503a = _Fake("fixed", fixed_status=503, fixed_body=b'{"error":{"message":"backend busy"}}')
_mm503b = _Fake("fixed", fixed_status=503, fixed_body=b'{"error":{"message":"backend busy"}}')
_body_a = {"model": "MiniMax-M3.1-Flash",
           "reasoning": {"effort": "high", "summary": "detailed"},
           "messages": [{"role": "user", "content": "ping"}]}
_env(MM_FAILOVER_LEG_MINIMAX_PRIMARY_BASE_URL=_mm503a.url,
     MM_FAILOVER_LEG_MINIMAX_SECONDARY_BASE_URL=_mm503b.url,
     MM_FAILOVER_LEG_BAOSI_GROK_BASE_URL=_grok_a.url,
     MM_FAILOVER_BAOSI_REASONING="auto")
_s_a, _p_a = _post("/v1/chat/completions", _body_a)
_up_a = json.loads(_grok_a.requests[-1]["body"]) if _grok_a.requests else {}
check("reasoning-auto-rewrite",
      _s_a == 200 and _up_a.get("model") == mmf.BAOSI_FALLBACK_MODEL
      and _up_a.get("reasoning", {}).get("effort") == "none"
      and "summary" not in _up_a.get("reasoning", {}),
      f"auto 档：改写成 grok-4.7 ⇒ 必须降级: 上游收到 model={_up_a.get('model')} reasoning={_up_a.get('reasoning')}")
_mm503a.stop(); _mm503b.stop()
_reset_legs()
_reset_state()
_grok_an = _Fake("live")
_env(MM_FAILOVER_LEG_BAOSI_GROK_BASE_URL=_grok_an.url,
     MM_FAILOVER_DISABLED_LEGS="minimax-primary,minimax-secondary",
     MM_FAILOVER_BAOSI_REASONING="auto")
_s_an, _p_an = _post("/v1/chat/completions", _body_r)
_up_an = json.loads(_grok_an.requests[-1]["body"]) if _grok_an.requests else {}
check("reasoning-auto-native",
      _s_an == 200 and _up_an.get("reasoning", {}).get("effort") == "high"
      and _up_an.get("reasoning", {}).get("summary") == "detailed",
      f"auto 档：原生 grok（无改写）⇒ 不降级: 上游收到 reasoning={_up_an.get('reasoning')}")
_grok_a.stop(); _grok_an.stop()

# 油量表（单元级 + /healthz 活读）：滑动窗口、C_max 反标定、t_reset、阈值
_reset_state()
_lbl = "minimax-primary"
_now = time.time()
with mmf._lock:
    mmf._fuel_events[_lbl] = [(_now - 17000, 8000), (_now - 19000, 5000)]
    mmf._fuel_cmax[_lbl] = 10000
    mmf._fuel_last_2056[_lbl] = _now - 1000
_pct, _nxt, _adv = mmf._fuel_get_state(_lbl)
check("fuel-gauge-sliding",
      _pct == 20.0 and _adv == "ALLOW_ALL" and 16900 <= _nxt <= 17100,
      f"窗口内 8000B/上限 10000B ⇒ 剩余 20.0%，19000s 前的 5000B 必须滑出窗口 "
      f"（窗口常量改错 ⇒ 本项必红）: pct={_pct} next_reset={_nxt}s advice={_adv}")
with mmf._lock:
    mmf._fuel_events[_lbl].append((_now, 1000))   # 窗口累计 9000B ⇒ 剩余 10%
_pct2, _nxt2, _adv2 = mmf._fuel_get_state(_lbl)
check("fuel-gauge-low-advice",
      _pct2 == 10.0 and _adv2 == "LOW_COMPLEXITY_ONLY",
      f"剩余 10%（<15%）⇒ 必须建议 LOW_COMPLEXITY_ONLY: pct={_pct2} advice={_adv2}")
_h_fg = _health()
_fg = _h_fg.get("fuel_gauge") or {}
check("fuel-gauge-healthz",
      isinstance(_fg.get("minimax_5h_remaining_pct"), (int, float))
      and isinstance(_fg.get("next_reset_in_sec"), int)
      and _fg.get("dispatch_advice") == "LOW_COMPLEXITY_ONLY"
      and mmf.FUEL_WINDOW_SECONDS == 18000,
      f"/healthz 三字段齐全且窗口常量 18000s: {_fg}")
_reset_state()
_pct3, _nxt3, _adv3 = mmf._fuel_get_state("minimax-primary")
check("fuel-gauge-uncalibrated",
      _pct3 == 100.0 and _nxt3 == 0 and _adv3 == "ALLOW_ALL",
      f"无 2056 历史不得编 c_max：静默状态报 100.0%/0/ALLOW_ALL: pct={_pct3} next_reset={_nxt3} advice={_adv3}")
mmf._fuel_update("minimax-primary", 4000)
mmf._fuel_record_2056("minimax-primary", mmf._fuel_bytes_in_window("minimax-primary"))
_pct4, _nxt4, _adv4 = mmf._fuel_get_state("minimax-primary")
check("fuel-record-2056",
      _pct4 == 0.0 and _adv4 == "LOW_COMPLEXITY_ONLY" and 17900 <= _nxt4 <= 18000,
      f"2056 触发时窗口 4000B ⇒ C_max 反标定为 4000B、剩余 0.0%、t_reset=t_2056+5h: "
      f"pct={_pct4} next_reset={_nxt4}s advice={_adv4}")
_reset_state()

# ══ 场景 10：拒绝绑 0.0.0.0 ═══════════════════════════════════════════
try:
    _p = subprocess.run([sys.executable, PATH],
                        env={**os.environ, "MM_FAILOVER_LISTEN_HOST": "0.0.0.0",
                             "MM_FAILOVER_LISTEN_PORT": "0"},
                        capture_output=True, timeout=10)
    _bind_rc, _bind_err = _p.returncode, (_p.stderr or b"").decode("utf-8", "replace")
except subprocess.TimeoutExpired:
    _bind_rc, _bind_err = None, "timeout: the process started instead of refusing"
check("bind-refusal",
      _bind_rc not in (0, None) and "0.0.0.0" in _bind_err,
      f"必须拒绝通配地址: rc={_bind_rc} err={_bind_err.strip()[:120]}")

for _f in (hang, live, hang2, live2, live3, slow, rec, quota, legbad):
    _f.stop()

print(f"\n=== {'全部通过' if not FAILS else '失败: ' + ', '.join(FAILS)} ===")
sys.exit(1 if FAILS else 0)
