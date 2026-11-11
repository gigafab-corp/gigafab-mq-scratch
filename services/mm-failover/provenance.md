# provenance —— mm-failover 网关源码快照的**来源与指纹**

本目录下的两个文件是**仓内真值源**（原为 macmini `~/.local/bin/` 的快照，
2026-10-22 纳管进仓；2026-10-28 起**以仓内为唯一真源**，现场副本由
`scripts/deploy_mm_failover.sh` 铺下去）。

<!-- fingerprints:start -->
mm_failover.py 7df226decd2beead7fcc15068f784d56
mm_failover_selftest.py 92aa0aaf534f374efad5961e2143b39c
<!-- fingerprints:end -->

**指纹是棘轮**：`tests/mm_failover_provenance_acceptance.sh` 会核对上面
`fingerprints:start/end` 之间的两行 ⇒ 任何对网关代码的改动都**必须**同时更新
本文件 ⇒ 「谁改了网关、改了什么」从此有机器证据，而不是「裸目录里的东西被人
sed 过一口」。

**（`mm_failover_selftest.py` 相对宿主副本有一处**必要**改动：路径由写死的
`~/.local/bin/mm-failover.py` 改为**相对本文件** ⇒ 仓内镜像与宿主副本都能自检。）**

## 实测模型表（真源用哪个兜底模型，由这张表说了算）

<!-- measured-models:start -->
| leg | model | status | measured | command |
|---|---|---|---|---|
| kilo | nvidia/nemotron-3-ultra-550b-a55b:free | delisted | 2026-10-28 | `curl -sS -o /dev/null -w '%{http_code}' https://kilo.ai/api/openrouter/v1/chat/completions -H "Authorization: Bearer $KILO_API_KEY" -H 'Content-Type: application/json' -d '{"model":"nvidia/nemotron-3-ultra-550b-a55b:free","messages":[{"role":"user","content":"ping"}]}'` ⇒ 2026-10-28 董事长令：彻底清理 kilo |
| kilo | minimax/minimax-m3.1-flash:free | delisted | 2026-10-28 | `curl -sS -o /dev/null -w '%{http_code}' https://kilo.ai/api/openrouter/v1/chat/completions -H "Authorization: Bearer $KILO_API_KEY" -H 'Content-Type: application/json' -d '{"model":"minimax/minimax-m3.1-flash:free","messages":[{"role":"user","content":"ping"}]}'` ⇒ 404 model_not_found（已从 Kilo 目录下架） |
| baosi | grok-4.7 | available | 2026-10-28 | `curl -sS -o /dev/null -w '%{http_code}' https://baosiapi.com/v1/chat/completions -H "Authorization: Bearer $BAOSIAPI_API_KEY" -H 'Content-Type: application/json' -d '{"model":"grok-4.7","messages":[{"role":"user","content":"ping"}]}'` |
| minimax | minimax-M3.1-Flash-Preview | available | 2026-10-28 | `curl -sS -o /dev/null -w '%{http_code}' https://api.minimaxi.com/v1/chat/completions -H "Authorization: Bearer $MINIMAX_API_KEY_PRIMARY" -H 'Content-Type: application/json' -d '{"model":"minimax-M3.1-Flash-Preview","messages":[{"role":"user","content":"ping"}]}'`（**仅 macmini 直连实测可达**；aimax 上直连 15s 超时 / 经代理 `SSL_ERROR_SYSCALL`） |
| baosi | grok-4.7 | measured | 2026-11-06 | `MM_FAILOVER_BAOSI_REASONING=none python3 services/mm-failover/mm_failover_selftest.py` ⇒ reasoning-none-grok / reasoning-none-minimax-untouched PASS（none 档：grok 腿 reasoning.effort=none 且去掉 summary，MiniMax 腿请求体逐字未改；上游 grok-4.7 传 reasoning_effort=none 实测 64s→6.04s 见 #2142 正文） |
<!-- measured-models:end -->

**状态词**：`measured` = 行为实测行（本行测的是 grok-4.7 的 reasoning=none 降级行为，不是可用性），不参与兜底模型比对（该比对只取 `status=available` 的 baosi 行）；再添一条 `available` 的 baosi 行会使提取值成两行而翻红，须先改门禁判据（另行呈批），故本行暂记 `measured`。

`tests/mm_failover_provenance_acceptance.sh` 会把**真源的 `BAOSI_FALLBACK_MODEL`**
与本表里 `status=available` 的 baosi 行**逐字比对** ⇒ 「兜底模型写错了」不再
是一句注释，而是一条会红的断言。⇒ **改了模型名必须先改这张表**（表带日期与
实测命令 ⇒ 可复核，不散落在注释里）。

### 附表 · 强模型道实测（2026-10-31 施工批复测，暂置附表的原因见下）

| leg | model | status | measured | command |
|---|---|---|---|---|
| baosi-claude | claude-opus-5-5 | available | 2026-10-31 | `curl -sS https://baosiapi.com/v1/chat/completions -H "Authorization: Bearer $BAOSIAPI_API_KEY" -H 'Content-Type: application/json' -d '{"model":"claude-opus-5-5","messages":[{"role":"user","content":"ping"}],"max_tokens":8}'` ⇒ 200、响应 `model` 逐字 `claude-opus-5-5`、`usage_source=anthropic`；同批目录 6 别名 c-f-5→claude-fable-5、c-f-5-1→claude-fable-5-1、c-o-4-8→claude-opus-4-8、c-o-5→claude-opus-5、c-o-5-5→claude-opus-5-5、c-s-5-5→claude-sonnet-5-5 全部同法 ping 200 且映射回全名、指纹同为 anthropic ⇒ 入网关 `CLAUDE_ALIASES` |

**为何暂置附表**：上表（measured-models 段）的机器判据把该段内**全部**
`status=available` 的 baosi 行提取后与 `BAOSI_FALLBACK_MODEL` **逐字等式
比对**（验收脚本该段的既有假设：baosi 账号只有一个 available 模型＝兜底
模型）。强模型道的第二条 available 记录（原生腿模型、非兜底）入正表会使
提取值成两行、判据翻红（施工批实测 FAIL 一条即此）。本行数据与正表同格
（日期＋命令＋结果齐），暂置附表保判据不破；**迁入正表的条件**＝验收脚本
该比对先改为按兜底腿作用域（如比对「兜底模型 ∈ available 集」或按腿名
分行）——那是门禁判据面的变更，须另行呈批，不在本 PR 内自改。本注即该
呈批项的登记面，PR 正文同步列明。

## 2026-10-28 真源回正（工单 #2085）

现场曾有**三份**各不相同的 `mm_failover.py`（仓内 / macmini 部署副本 / aimax
部署副本）⇒ 跑一次部署脚本就把宿主打回**已下架**的模型；同时旧版只有一个
`UPSTREAM_TIMEOUT=900`（**每 socket 操作**计时，不是总时长）⇒ 一条不可达的
上游腿就能烧满工匠预算（3000s）⇒ 级联永远轮不到健康腿 ⇒ **四张核心工单
零产出**。本版把四条病根**回仓**：

| # | 病根 | 本版的根治 | 机器判据（自检名） |
|---|---|---|---|
| ① | 腿级超时缺位（死腿烧光预算） | `CONNECT_TIMEOUT`（连接+响应头+首字节，默认 20s）与 `STREAM_TIMEOUT`（流式，默认 900s）**分级** | `graded-timeout` |
| ② | 同上游重试是纯浪费 | 传输层错误**换腿**不换同腿 | `swap-leg` |
| ③ | 原生腿压死健康兜底腿 | 排序按**健康度**（冷却/连续失败排后），「原生腿优先」只在都健康时生效 | `health-order` |
| ④ | 冷却太短（5s ⇒ 刚挂的腿立刻又被选中） | 网络抖动冷却 5s → **60s**；连续失败达阈值 ⇒ **熔断 120s** | `cooldown-minutes` |
| ⑤ | 跨节点行为不一致 | **节点级腿配置**（环境变量启停 / 排序 / 改 base_url / 改 key 源 / 改兜底模型）⇒ 同仓不同机可差异化 | `leg-disable` |
| ⑥ | 共享面裸奔 | 拒绝绑 `0.0.0.0` + Bearer 令牌 + 端点白名单 + 工具面剥离 + 并发槽位 | `bind-refusal` / `token-auth` / `path-allowlist` / `tools-strip` / `concurrency-limit` |

自检（`mm_failover_selftest.py`）全部用**本地假上游**（127.0.0.1），**不打真网**、
不碰任何真实凭证 ⇒ 任何机器上都能复现同一组判决；每条判据都有**定点变异自证**
（门禁里 M4–M12）。

## 2026-10-28 v1.2（三腿收敛 + 杀 502 保持 + 双号错峰）

承 #2085 回正与同日董事长令（三机统一 `minimax-primary / minimax-secondary /
baosi-grok`、彻底清理 kilo）：仓内先行收敛三腿与改名（旧腿名经 `LEG_ALIASES`
兼容节点 env），共享面令牌改为仅共享模式校验，独苗腿传输抖动加 1 次原地
重试。v1.2 在此之上补两条：

| # | 病根 | 本版的根治 | 机器判据（自检名） |
|---|---|---|---|
| ⑦ | 全腿暂败即 502 ⇒ 客户端指数退避死锁（2026-10-28 19:31 事故：双腿 2056 + baosi 瞬断 ⇒ codex 挂死 6m03s） | 全腿失败后若有腿是抖动/熔断档冷却，**保持请求**按粒度重试（总预算 `MM_FAILOVER_HOLD_BUDGET` 默认 90s）；全腿额度/腿级长冷却（600s）则不保持、立即收尾 | `hold-retry` / `hold-skips-quota` |
| ⑧ | 主备式烧腿：主腿先烧干、次腿再烧干，两号窗口同日相继见底 | 两条**直连** MiniMax 腿都健康时按时间片轮换优先腿（`MM_FAILOVER_MM_ROTATE_SECONDS` 默认 3600s），两号均匀消耗；改道腿不参与 | `mm-rotate` |

`server_version` 自本版起为 `mm-failover/1.2`。

### 节点级腿配置（环境变量）

| 变量 | 作用 | 例子 |
|---|---|---|
| `MM_FAILOVER_DISABLED_LEGS` | 关掉某些腿（逗号分隔） | `minimax-key2,minimax-key3` |
| `MM_FAILOVER_LEG_ORDER` | 改排序（逗号分隔） | `kilo-minimax-free,baosi-grok` |
| `MM_FAILOVER_LEG_<TAG>_ENABLED` | 单腿开关（`0`/`1`） | `MM_FAILOVER_LEG_MINIMAX_KEY2_ENABLED=0` |
| `MM_FAILOVER_LEG_<TAG>_BASE_URL` | 改上游地址 | `http://100.76.189.39:4180` |
| `MM_FAILOVER_LEG_<TAG>_KEY_ENV` | 改密钥来源 | `GIGAFAB_MM_TOKEN` |
| `MM_FAILOVER_LEG_<TAG>_MODEL` | 改兜底模型 | `nvidia/nemotron-3-ultra-550b-a55b:free` |
| `MM_FAILOVER_CONNECT_TIMEOUT` | 连接+首字节超时（秒） | `20` |
| `MM_FAILOVER_STREAM_TIMEOUT` | 流式生成长超时（秒） | `900` |
| `MM_FAILOVER_MAX_CONCURRENT` | 并发槽位 | `16` |
| `MM_FAILOVER_HOLD_BUDGET` | 全腿暂败保持请求总预算（秒，`0`=禁用） | `90` |
| `MM_FAILOVER_HOLD_POLL` | 保持期间重试粒度（秒） | `10` |
| `MM_FAILOVER_MM_ROTATE_SECONDS` | 双 MiniMax 直连腿轮换时间片（秒，`0`=禁用） | `3600` |
| `MM_FAILOVER_SHARED_MODE` | 共享面开关（`auto`/`1`/`0`） | `1` |
| `MM_FAILOVER_ALLOWED_PATHS` | 端点白名单 | `/v1/chat/completions,/healthz` |
| `GIGAFAB_MM_TOKEN` | 共享面 Bearer 令牌（**只在 env 文件，0600，不入仓**） | — |

`<TAG>` = 腿名大写、连字符换下划线（`minimax-key2` → `MINIMAX_KEY2`）。

### 并联形态样例（Mac mini ⇄ Aimax，董事长 2026-10-28 晨间裁定）

**Mac mini 侧**（两个实例：本地回环 + Tailnet 共享面）：

```sh
# 本地回环实例（本机 codex 用，不共享面 ⇒ 不要令牌）
MM_FAILOVER_LISTEN_HOST=127.0.0.1 MM_FAILOVER_LISTEN_PORT=4180 \
  mm-failover.py

# Tailnet 共享面实例：**只绑 Tailscale IP**（绝不 0.0.0.0）＋ 强制令牌
MM_FAILOVER_LISTEN_HOST=100.76.189.39 MM_FAILOVER_LISTEN_PORT=4180 \
MM_FAILOVER_SHARED_MODE=1 GIGAFAB_MM_TOKEN=<令牌> \
MM_FAILOVER_ALLOWED_PATHS=/v1/chat/completions,/healthz \
MM_FAILOVER_MAX_CONCURRENT=16 \
  mm-failover.py
```

**Aimax 侧**（不自己够 MiniMax，直接用 Mac mini 上**已验证健康**的网关）：

```sh
# 关掉本机够不到的 minimax 原生腿；腿指向 Mac mini 的共享面网关
MM_FAILOVER_DISABLED_LEGS=minimax-key2,minimax-key3 \
MM_FAILOVER_LEG_KILO_MINIMAX_FREE_BASE_URL=http://100.76.189.39:4180 \
MM_FAILOVER_LEG_KILO_MINIMAX_FREE_KEY_ENV=GIGAFAB_MM_TOKEN \
  mm-failover.py
```

护栏（**机器铁律**，各有断言）：① 只绑 Tailscale IP（拒 `0.0.0.0`）② 共享面
强制 Bearer 令牌（缺/错 ⇒ 401）③ 只暴露 `/v1/chat/completions`（其余 404）且
剥掉工具面（纯文本补全代理）④ 并发槽位上限（超限 ⇒ 自己回 503，**不把 429
甩给上游**；请求结束后计数必须回落）。

**密钥纪律**：网关**从环境变量**读上游 key（`MINIMAX_API_KEY_PRIMARY` /
`MINIMAX_API_KEY_SECONDARY` / `KILO_API_KEY` / `BAOSIAPI_API_KEY`）⇒
**仓内这份不含任何凭证**，也**不得**含。zen 账号那一把 key 只在本机 env
（`kilo-gateway.env`），**不进仓**；共享面令牌同理（env 文件，0600）。

**2026-10-26 变更**：监听地址改为**环境变量可覆盖**
（`MM_FAILOVER_LISTEN_HOST` / `MM_FAILOVER_LISTEN_PORT`，默认仍是 `127.0.0.1:4180`）——
为了让别的节点经 Tailscale 把**同一个网关**当云端通道用，而**不必把钥匙搬走**。

**为什么必须进仓**：改动原先只活在本机 ⇒ **主机重建就丢**（而这套网关是
codex 车道的 502 止血线）。进仓之后，仓内是**真值源**，宿主副本可由
`scripts/deploy_mm_failover.sh` 重新铺回去。⇒ 该脚本另有一道**第三版本闸门**
（部署台账 `.mm-failover.deployed.md5`）：宿主副本既不是台账里那份、也不是当前
真源 ⇒ **拒绝铺**（这正是"三份版本"这场病能被机器抓住的地方）。

## 2026-10-31 强模型道步 1（候选，未部署）：baosi-claude 原生腿 + 裁决禁替

承 S3 强模型道设计与 STRONG-PATH-CONSTRUCTION-PREP 裁定（步 2 部署须待本 PR
按正常序合流，仓外不得部署未合流件）。本版在 v1.2 之上补三件：

| # | 病根/缺口 | 本版的根治 | 机器判据（自检名） |
|---|---|---|---|
| ⑨ | Claude 强模型无原生腿：点名 claude-opus-5-5 会被 baosi-grok 替代腿改写成 grok-4.7 执行（D20 病灶：以强模型之名行 Grok 之实） | 新增 `baosi-claude` 原生腿（`_is_claude_model`：`claude-*` 族 + 实测别名 `CLAUDE_ALIASES`；key 与 baosi-grok 共用 `BAOSIAPI_API_KEY`，不新增凭证） | `verdict-mechanical-regression`（机械面替代照旧） |
| ⑩ | 强腿不可用时弱模型代判无机器阻断 | `VERDICT_MODELS={"claude-opus-5-5"}`：裁决类请求在归类段只许 Claude 原生腿接，其余腿（含替代腿）一律跳过 ⇒ 强腿禁用/冷却时只能 HOLD 后 502「不判」 | `verdict-no-substitute` / `verdict-hold-then-502` |
| ⑪ | 一调最终由谁执行无对账面 | 每调收尾打一行 `SERVED req=… leg=… served=… rewritten=…`（成响应记腿名；全腿用尽记 `leg=- served=-`），供 Beta 侧 attest 三查对账 | 三新场景内嵌 SERVED 断言 |

注意：部署本版会同时带入 canonical 既有的 `BAD_TTL_QUOTA 600→18000` 变化
（仓内真源相对 macmini 现役 fork 的谱系差，非本批引入）⇒ 部署窗口须知悉
额度冷却随之变长。`server_version` 维持 `mm-failover/1.2`（部署形态不变）。

## 2026-11-06 v1.3（#2142：推理开关 + /healthz 5h 油量表，零新增常驻）

| # | 缺口 | 本版的根治 | 机器判据（自检名） |
|---|---|---|---|
| ⑫ | baosi/grok 腿全局 effort=high，网关原样转发，无降级开关 | `MM_FAILOVER_BAOSI_REASONING`（keep/none/auto）：none ⇒ baosi-grok 腿 `reasoning.effort` 置 none 并去掉 summary；auto ⇒ 仅当本腿把模型改写成 grok-4.7 时才降级；keep（默认）不动；MiniMax 腿请求体逐字不动 | `reasoning-none-grok` / `reasoning-none-minimax-untouched` / `reasoning-keep` / `reasoning-auto-rewrite` / `reasoning-auto-native` |
| ⑬ | 2056（MiniMax 5h 额度耗尽）是突发事故，无油量可见性 | 纯内存滑动账本（`FUEL_WINDOW_SECONDS=18000`）：请求字节进窗口、2056 触发时窗口累计字节反标定 C_max、`t_reset = t_2056 + 5h`、剩余 <15% ⇒ `LOW_COMPLEXITY_ONLY`；/healthz 暴露 `fuel_gauge` 三字段；无 2056 历史不编 c_max | `fuel-gauge-sliding` / `fuel-gauge-low-advice` / `fuel-gauge-healthz` / `fuel-gauge-uncalibrated` / `fuel-record-2056` / `fuel-update-wired` |

`server_version` 维持 `mm-failover/1.2`（部署形态不变）。
