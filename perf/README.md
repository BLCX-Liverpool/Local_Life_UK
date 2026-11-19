# 隔离压测方案

本目录实现经确认的缓存 A/B、秒杀阶梯压测和业务对账方案。测试不修改业务逻辑，固定使用 Compose 项目 `hmdp-perf`、数据库 `hmdp_optimization_test` 和该项目自己的数据卷。

## 安全边界

- 不得把脚本指向开发库、演示库或生产库。
- `prepare-fixture.sh` 同时检查 Compose 项目名和数据库名，并要求显式设置 `HMDP_PERF_ALLOW_RESET=yes`。
- 正式压测还要求 `HMDP_PERF_CONFIRM_FORMAL_RUN=yes`。
- `stop-stack.sh` 默认保留数据卷，不执行 `down -v`。
- 压测专用用户 ID 为 `900001..910000`，券 ID 默认为 `990001`。
- JMeter 应在独立压测机运行；本机 `SMOKE` 只用于验证脚本和链路。

## 目录

```text
perf/
├── docker-compose.perf.yml       隔离 API 服务覆盖配置
├── jmeter/
│   ├── cache-read.jmx            80/20 店铺详情读取
│   └── seckill.jmx               不同登录用户的秒杀请求
├── scripts/                      启动、夹具、执行、分析和验收
├── sql/                          夹具与最终状态查询
├── generated/                    运行时 token CSV，Git 忽略
├── results/                      JTL、HTML 仪表板和 JSON 结果，Git 忽略
└── report-template.md            正式报告模板
```

## 环境要求

- Docker 和 Docker Compose。
- Java 8 或更高版本。
- Python 3。
- curl。
- Apache JMeter 5.6.3。

JMeter 未安装时：

```bash
perf/scripts/install-jmeter.sh
```

安装脚本从 Apache Archive 下载二进制包并校验官方 SHA-512 文件，结果放在 `perf/.tools/`。

## 正式测试服务器基线

10000 用户档代表 10000 个不同登录用户各提交一次请求；L4A/L4B 分别把这 10000 个请求控制在 800/1000 RPS。用户数不是同时保持的 TCP 连接数，也不是 RPS。

正式测试应把发压机与被测服务分开，并位于同一地域/可用区：

| 角色 | 建议配置 | 说明 |
| --- | --- | --- |
| Java API | 8 vCPU / 16 GiB，JVM 6–8 GiB | 作为 1000 RPS 档位的起始基线 |
| MySQL | 4 vCPU / 8 GiB，SSD/NVMe | 独立实例，连接池默认 30 |
| Redis | 2 vCPU / 4 GiB | 独立实例，避免与 JVM 争抢内存 |
| RabbitMQ | 2 vCPU / 4 GiB | 独立实例并监控 ready/unacked |
| JMeter 发压机 | 8 vCPU / 8 GiB | 不与 API 共机，网络带宽至少 1 Gbps |

如果只能使用一台服务器承载 API、MySQL、Redis 和 RabbitMQ，建议至少 16 vCPU / 32 GiB / NVMe；该结果只能说明整机组合容量，不能直接归因到 Java 服务。最终报告必须记录真实实例规格、JVM 参数和网络位置。

## 启动隔离环境

```bash
perf/scripts/start-stack.sh
```

默认入口为 `http://127.0.0.1:18081`。隔离环境启用 MySQL、Redis、RabbitMQ 和 Java API；Memcached明确停用且不启动，Kafka、RocketMQ、Canal和行为分析不参与本轮测试。

## 低档冒烟

冒烟使用 20 个用户、20 份库存和 10 RPS，不属于正式容量结论：

```bash
perf/scripts/run-seckill-tier.sh SMOKE
```

## 正式秒杀档位

| 场景 | 不同用户 | HTTP 请求 | 目标 RPS | 库存 | 目的 |
| --- | ---: | ---: | ---: | ---: | --- |
| L1 | 1000 | 1000 | 100 | 1000 | 基础容量 |
| L2 | 2000 | 2000 | 200 | 2000 | 中等压力 |
| L3 | 5000 | 5000 | 500 | 5000 | 主要容量目标 |
| L4A | 10000 | 10000 | 800 | 10000 | 高压稳定性 |
| L4B | 10000 | 10000 | 1000 | 10000 | 全局限流边界 |
| DUPLICATE | 1000 | 2000 | 200 | 1000 | 每用户重复两次 |
| STOCK | 5000 | 5000 | 500 | 3000 | 库存不足与零超卖 |
| LIMIT | 2000 | 2000 | 1500 | 2000 | 受控 429 |

每次正式运行都重置隔离测试夹具：

```bash
export HMDP_PERF_CONFIRM_FORMAL_RUN=yes
perf/scripts/run-seckill-tier.sh L1
```

状态查询不混入主发压流量。JMeter 完成后，脚本最多等待 5 分钟，直到 Redis Stream、Outbox 和 RabbitMQ 排空，再执行库存与订单对账。

## 缓存 A/B分档

两个模式分别是：

- A：业务缓存关闭，直接回源 MySQL。
- B：Caffeine + Redis，Memcached 关闭。

两组都保留Redis服务，因为登录和项目基础功能依赖Redis；A组只是让店铺详情绕过业务缓存。缓存档位为C1/C2/C3/C4/C5，分别对应100/200/500/800/1000 RPS。每轮在同一个JMeter进程内预热30秒、正式运行60秒，并保留10秒收尾缓冲；网页报告和统计只包含正式60秒。每档按`AB/BA/AB/BA/AB`执行，A、B各五轮并比较中位数。

运行全部缓存档位：

```bash
export HMDP_PERF_CONFIRM_FORMAL_RUN=yes
perf/scripts/run-cache-ab.sh ALL
```

也可以先单独验证某一档：

```bash
perf/scripts/run-cache-ab.sh C1
```

结果同时给出各档P50/P95/P99降低比例、Caffeine/Redis/MySQL QPS、MySQL回源降低比例，以及满足目标RPS、单秒峰值不超过目标的150%、P95不超过200ms、P99不超过500ms、零超时、零5xx和零业务失败时的最高通过RPS。容量提升按`B组最高通过RPS/A组最高通过RPS-1`计算；如果B组通过最高测试档，只能表述为“至少达到1000 RPS”。

## 全套执行

全套包含约84分钟的缓存A/B分档（另加容器重启和报告生成时间），以及所有秒杀档位：

```bash
export HMDP_PERF_CONFIRM_FORMAL_RUN=yes
perf/scripts/run-formal-suite.sh
```

可通过以下变量调整预热和正式阶段时长，但正式报告必须记录实际值：

```bash
export HMDP_PERF_CACHE_DURATION_SECONDS=60
export HMDP_PERF_CACHE_WARMUP_SECONDS=30
```

## 结果

每个秒杀结果目录包含：

- `results.jtl`：原始请求结果。
- `dashboard/`：JMeter HTML 报告。
- `http-summary.json`：吞吐、P50/P95/P99、超时、429和业务结果。
- `final-state.json`：库存、订单、预约、Stream、Outbox、RabbitMQ和死信。
- `verification.json`：统一验收结论与失败原因。

每个缓存轮次目录还包含：

- `metrics-before.prom`、`metrics-after.prom`：正式阶段前后的原始指标快照。
- `cache-metrics.json`：Caffeine命中、Redis命中、MySQL回源增量及对应QPS。
- `results.jtl`：包含预热、正式和收尾缓冲的原始请求。
- `measurement.jtl`：只包含正式60秒，是网页报告和汇总的输入。
- `latency-by-second.csv`：逐秒请求数与延迟。
- `metadata.json`：档位、A/B模式、轮次、RPS和时长。

缓存A/B根目录的`verification.json`汇总五轮中位数、各档延迟降低比例和容量提升；`cache-ab-report.html`是可直接用浏览器打开的统一可视化报告。即使某个档位因负载突发被判为无效，脚本也会先生成HTML报告，再以非零状态结束。

也可以对已有结果单独生成或重新生成统一报告：

```bash
latest="$(find perf/results -mindepth 1 -maxdepth 1 -type d -name '*-cache-ab-*' | sort | tail -n 1)"
python3 perf/scripts/generate_cache_html_report.py \
  "$latest/verification.json" \
  "$latest/cache-ab-report.html"
```

主验收条件：

```text
初始库存 = 数据库剩余库存 + 成功订单数
数据库剩余库存 - Redis剩余库存 - 未完成预约数 = 0
未完成预约数 = 0
Stream lag/pending/review = 0
Outbox pending/inflight/review = 0
RabbitMQ ready/unacked = 0
死信和异常消息 = 0
一人多单违规 = 0
```

正式档要求请求到达RPS保持在目标值的95%～105%、P95不超过200ms、P99不超过500ms、零超时和零非预期5xx。到达RPS按计划窗口计算；若实际到达跨度超过计划窗口，则改用更长的实际跨度，避免把Poisson到达在窗口首尾的自然空白误判为超额吞吐。报告另列活跃到达窗口RPS和完成吞吐。L4B与LIMIT允许受控429，但仍需通过全部业务对账。

## 停止

```bash
perf/scripts/stop-stack.sh
```

命令保留隔离数据卷，便于复核。需要删除隔离卷时应人工核对 Compose 项目确实为 `hmdp-perf` 后再单独执行，脚本不会自动删除。

