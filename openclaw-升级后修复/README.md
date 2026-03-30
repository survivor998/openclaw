# openclaw 升级后修复

本目录汇总 OpenClaw 升级后的统一修复资产，便于在新版本安装后快速回放修复并核验结果。

## 包含文件

1. `OpenClaw_升级后统一修复手册_heartbeat_toolMsg_20260329.md`
   - 升级后统一修复手册（heartbeat 污染、toolMsg 防护、WebChat 重复显示问题）
   - 包含官方 issue 状态、执行顺序、核验命令

2. `openclaw-reapply-heartbeat-fix.sh`
   - 源码级复打修复脚本
   - 包含 heartbeat 污染修复、toolMsg 防护、WebChat 重复发送/显示防护补丁、回归测试与健康检查

3. `openclaw-safe-upgrade.sh`
   - 安全升级脚本
   - 先升级官方版本，再自动调用复打脚本，最后做二次核验与日志诊断

## 推荐使用顺序

1. 执行安全升级

```bash
./openclaw-升级后修复/openclaw-safe-upgrade.sh 2026.3.28
```

2. 若需仅回放修复

```bash
./openclaw-升级后修复/openclaw-reapply-heartbeat-fix.sh 2026.3.28
```

## 升级后快速定位（建议先做）

```bash
# 1) 版本与健康
openclaw --version
openclaw gateway health

# 2) 主会话是否被 heartbeat 污染
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

## 清理策略（已固化）

- 临时构建与测试目录（`openclaw-fixed-worktrees/*`）可随时删除，不影响下次修复。
- 核心保留文件仅三份：手册 + `reapply` 脚本 + `safe-upgrade` 脚本。
- 下次升级后，优先执行 `openclaw-safe-upgrade.sh`，若失败再单独执行 `openclaw-reapply-heartbeat-fix.sh`。

## 目标

- 避免 heartbeat 污染主会话上下文再次出现
- 防止 `toolMsg.content.filter` 类型错误导致会话中断
- 降低 WebChat 在重连场景下“输入一次显示两次”的复发概率（含非相邻重复去重）
