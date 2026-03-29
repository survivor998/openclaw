# OpenClaw 升级后统一修复手册（Heartbeat + toolMsg + WebChat 重复显示）

更新时间：2026-03-29 22:05 CST  
分析报告：`/tmp/openclaw-log-analysis-report-2026-03-29.md`

## 1. 官方仓库最新结论（2026-03-29）

| 问题                                                                            | 官方状态                                                                                                                                                     | 处理策略                                          |
| ------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------- |
| Heartbeat 污染主会话元数据（`lastTo/deliveryContext/origin` 被 heartbeat 覆盖） | 未确认已在 2026.3.28/2026.3.29 官方包完全覆盖                                                                                                                | 保留源码级修复 + 升级后自动巡检与清理             |
| `toolMsg.content.filter is not a function`                                      | 仍存在升级后回归风险（依赖链/构建差异）                                                                                                                      | 保留安装后自动检测与热修                          |
| WebChat 单次输入出现重复 user 消息（fallback/retry 引发）                       | 官方有修复 PR 但未确认已进入你的安装包：[#52903](https://github.com/openclaw/openclaw/pull/52903)                                                            | 脚本优先应用官方 commit，失败则本地 fallback 补丁 |
| WebChat 显示 heartbeat poll 文本（`Read HEARTBEAT.md...`）                      | 仍为官方已知问题：[#49374](https://github.com/openclaw/openclaw/issues/49374)；对应修复 PR 未合并：[#36899](https://github.com/openclaw/openclaw/pull/36899) | 脚本回补 gateway + UI 过滤                        |
| Control UI 上一条内容粘到下一条（composer duplication）                         | 官方 open：[#24022](https://github.com/openclaw/openclaw/issues/24022)                                                                                       | 脚本保留队列重试 runId/idempotencyKey 稳定化补丁  |

## 2. 本次采用的“官方最佳可落地方案”

### 2.1 重复 user 消息（fallback/retry）

优先应用官方提交：

- `effb9cb3948ed9a8366042093de8a3eaa44875f2`
- `a63afd8ce043405561889c5fcb4f0965ad1edf06`

核心思路：

1. 在 `session-manager-init` 重试前剥离 trailing orphaned user messages。
2. 在 OpenAI WS 输入转换阶段，对“相邻且相同指纹”的 user message 去重（保留真实不同输入）。

### 2.2 Heartbeat poll 泄露到 WebChat 历史

优先参考官方 PR（未合并）中的实现：

- `b92c49b3e083559dcd84e1a42d57246781dacbb6`（PR #36899）

核心思路：

1. Gateway `chat.history` 过滤：
   - assistant 纯 `HEARTBEAT_OK`
   - user 端 heartbeat poll 前缀（`Read HEARTBEAT.md`）
2. UI `chat.history` 再做 defense-in-depth 过滤，避免漏网。

## 3. 三个文件已经整合的能力

### 3.1 `~/Desktop/openclaw-reapply-heartbeat-fix.sh`

当前脚本按如下顺序执行：

1. Heartbeat 主会话污染修复（源码级 + 安装后巡检）
2. 官方最佳修复回补（commit 优先，失败 fallback）：
   - fallback/retry 重复 user message 去重
   - heartbeat poll 历史过滤（gateway + UI）
3. WebChat 队列重试 runId/idempotencyKey 稳定化补丁（应对 #24022 类表现）
4. `toolMsg.content.filter` 检测与热修
5. Telegram webhook 清理、模型 failover 基线、重试策略、DNS 健康检查、日志热点排序。

### 3.2 `~/Desktop/openclaw-safe-upgrade.sh`

升级流程：

1. 安装官方版本（latest 或指定版本）
2. 调用 `openclaw-reapply-heartbeat-fix.sh` 自动回补
3. 二次校验：toolMsg、防故障转移、DNS、日志热点
4. 新增 24h 诊断指标：
   - webchat connect/disconnect 次数
   - transcript 重复消息桶计数
   - `heartbeatPollVisibleCount`

## 4. 推荐命令

```bash
~/Desktop/openclaw-safe-upgrade.sh
# 或
~/Desktop/openclaw-safe-upgrade.sh 2026.3.28
```

## 4.1 新增：npm 安装卡住自动恢复（2026-03-29 晚）

已针对以下真实故障做脚本级修复：

- `npm install -g openclaw@...` 卡在 `@matrix-org/matrix-sdk-crypto-nodejs` 的 `download-lib.js`
- `ENOTEMPTY: rename .../node_modules/openclaw -> .../.openclaw-*` 临时目录残留冲突

现在两个脚本都内置：

1. 安装命令超时监控（默认 900 秒）
2. 超时后自动杀掉安装进程树
3. 清理全局 `node_modules/.openclaw-*` 残留目录
4. 自动回退重试：`npm install -g --ignore-scripts ...`

可选环境变量：

- `OPENCLAW_SAFE_UPGRADE_INSTALL_TIMEOUT_SEC`（默认 `900`）
- `OPENCLAW_REAPPLY_INSTALL_TIMEOUT_SEC`（默认 `900`）

## 5. 快速核验

### 5.1 Heartbeat 主会话污染

```bash
node -e '
const fs=require("fs");
const p=process.env.HOME+"/.openclaw/agents/main/sessions/sessions.json";
const d=JSON.parse(fs.readFileSync(p,"utf8"));
const e=d["agent:main:main"];
console.log(JSON.stringify({
  polluted:e?.lastTo==="heartbeat"||e?.deliveryContext?.to==="heartbeat"||e?.origin?.provider==="heartbeat"
},null,2));
'
```

### 5.2 WebChat heartbeat poll 可见性

```bash
rg -n "Read HEARTBEAT\.md" ~/.openclaw/agents/main/sessions/*.jsonl | tail -n 30
```

### 5.3 WebChat 重连风暴

```bash
rg -n "\[ws\] webchat (connected|disconnected)" ~/.openclaw/logs/gateway.log ~/.openclaw/logs/gateway.err.log | tail -n 80
```

## 6. 备注

- 这次整合遵循你的要求：只把“官方最新版仍可能存在”的问题写入脚本；已明确官方彻底修复并进入稳定发布的项目不再单独维护补丁。
- 若后续官方 release notes 明确包含上述 commit/同等修复，可在脚本中删除对应 fallback 补丁分支。
