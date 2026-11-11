# mm-failover

codex 的 MiniMax 双号 + Baosi 自动故障转移代理：监听 `127.0.0.1:4180`，按腿健康度排序、熔断与换腿重试把请求送到健康的上游腿；入口 `mm_failover.py`，部署 `scripts/deploy_mm_failover.sh`（macmini，见 `units/`），测试 `python3 mm_failover_selftest.py` 与 `python3 -m unittest discover -s services/mm-failover/tests -v`。

- 代码：`mm_failover.py`（网关）+ `mm_failover_selftest.py`（16 个场景自检，退出码 0 = 全过；部署脚本与 `tests/mm_failover_provenance_acceptance.sh` 均按此二文件名取用，勿改名、勿移入 `tests/`）。
- `units/`：macmini 侧 launchd 单元模板 `com.gigafab.mm-failover.plist`（现网 plist 在宿主 `~/Library/LaunchAgents/`，本文件为入仓副本；令牌绝不写入 plist，只放 0600 env 文件）。
- 兜底模型与实测表：`provenance.md`（measured-models 段；改模型名必须先改表，门禁逐字比对 `BAOSI_FALLBACK_MODEL`）。
- 共享面护栏：非回环绑定即启用——拒绝通配地址（`0.0.0.0` 直接拒绝启动）、强制 Bearer 令牌、只暴露 `/v1/chat/completions` 与 `/healthz`、剥掉 tools 面、并发槽位上限。
