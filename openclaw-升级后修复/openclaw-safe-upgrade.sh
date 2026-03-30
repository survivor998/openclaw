#!/bin/zsh
set -euo pipefail

TARGET_VERSION="${1:-latest}"
REAPPLY_SCRIPT="$HOME/Desktop/openclaw-reapply-heartbeat-fix.sh"
INSTALL_TIMEOUT_SEC="${OPENCLAW_SAFE_UPGRADE_INSTALL_TIMEOUT_SEC:-900}"

if ! command -v npm >/dev/null 2>&1; then
  echo "npm command not found in PATH" >&2
  exit 1
fi
if ! command -v openclaw >/dev/null 2>&1; then
  echo "openclaw command not found in PATH" >&2
  exit 1
fi
if [[ ! -x "$REAPPLY_SCRIPT" ]]; then
  echo "Reapply script not executable: $REAPPLY_SCRIPT" >&2
  exit 1
fi

kill_process_tree() {
  local pid="$1"
  local children
  children="$(pgrep -P "$pid" 2>/dev/null || true)"
  if [[ -n "$children" ]]; then
    while IFS= read -r child; do
      [[ -n "$child" ]] && kill_process_tree "$child"
    done <<< "$children"
  fi
  kill -TERM "$pid" 2>/dev/null || true
  sleep 1
  kill -KILL "$pid" 2>/dev/null || true
}

run_with_timeout() {
  local timeout_sec="$1"
  shift
  "$@" &
  local pid=$!
  local start=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    if (( SECONDS - start >= timeout_sec )); then
      echo "warn: command timed out after ${timeout_sec}s: $*" >&2
      kill_process_tree "$pid"
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 2
  done
  wait "$pid"
}

cleanup_openclaw_staging_dirs() {
  local npm_root
  npm_root="$(npm root -g 2>/dev/null | tr -d '\r')"
  if [[ -n "$npm_root" && -d "$npm_root" ]]; then
    find "$npm_root" -maxdepth 1 -type d -name '.openclaw-*' -exec rm -rf {} + 2>/dev/null || true
  fi
}

install_official_openclaw_with_fallback() {
  local spec="$1"
  cleanup_openclaw_staging_dirs
  if run_with_timeout "$INSTALL_TIMEOUT_SEC" npm install -g "$spec"; then
    return 0
  fi
  echo "warn: npm install -g $spec failed or timed out; retrying with --ignore-scripts" >&2
  cleanup_openclaw_staging_dirs
  run_with_timeout "$INSTALL_TIMEOUT_SEC" npm install -g --ignore-scripts "$spec"
}

echo "==> Upgrading OpenClaw to: $TARGET_VERSION"
if [[ "$TARGET_VERSION" == "latest" ]]; then
  install_official_openclaw_with_fallback "openclaw@latest"
else
  install_official_openclaw_with_fallback "openclaw@$TARGET_VERSION"
fi

echo "==> Version after official upgrade"
openclaw --version

echo "==> Official references for this upgrade flow"
cat <<'EOF'
- duplicate user messages on fallback retries: https://github.com/openclaw/openclaw/pull/52903
  commits: effb9cb3948ed9a8366042093de8a3eaa44875f2, a63afd8ce043405561889c5fcb4f0965ad1edf06
- heartbeat poll shown in webchat history: https://github.com/openclaw/openclaw/pull/36899 (not merged), issue: https://github.com/openclaw/openclaw/issues/49374
- composer duplication / accidental prepend: https://github.com/openclaw/openclaw/issues/24022
EOF

INSTALLED_VERSION="$(openclaw --version | awk 'NR==1 {print $2}')"
echo "==> Reapplying heartbeat/session/toolMsg fixes on version: $INSTALLED_VERSION"
"$REAPPLY_SCRIPT" "$INSTALLED_VERSION"

echo "==> Verifying toolMsg.content.filter guard in installed pi-agent-core"
node - <<'NODE'
const { execSync } = require("child_process");
const fs = require("fs");
const root = execSync("npm root -g", { encoding: "utf8" }).trim();
const file = `${root}/openclaw/node_modules/@mariozechner/pi-agent-core/dist/agent-loop.js`;
if (!fs.existsSync(file)) {
  console.error(`agent-loop.js not found: ${file}`);
  process.exit(2);
}
const text = fs.readFileSync(file, "utf8");
const unguarded =
  /\bmessage\.content\.filter\(\(c\)\s*=>\s*c\.type === "toolCall"\)/.test(text) ||
  /\bassistantMessage\.content\.filter\(\(c\)\s*=>\s*c\.type === "toolCall"\)/.test(text);
console.log(JSON.stringify({ file, guarded: !unguarded }, null, 2));
if (unguarded) process.exit(42);
NODE

echo "==> Verifying webchat heartbeat runtime filter in control-ui bundle"
node - <<'NODE'
const { execSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const root = execSync("npm root -g", { encoding: "utf8" }).trim();
const assetsDir = path.join(root, "openclaw", "dist", "control-ui", "assets");
if (!fs.existsSync(assetsDir)) {
  console.error(`control-ui assets not found: ${assetsDir}`);
  process.exit(2);
}
const files = fs.readdirSync(assetsDir).filter((f) => f.startsWith("index-") && f.endsWith(".js"));
if (files.length === 0) {
  console.error("control-ui index bundle not found");
  process.exit(2);
}
const bundlePath = path.join(assetsDir, files.sort().at(-1));
const text = fs.readFileSync(bundlePath, "utf8");
const hasRuntimeHeartbeatFilter =
  text.includes("Read HEARTBEAT.md") &&
  (text.includes("HEARTBEAT_OK") || text.includes("HEARTBEAT_TOKEN")) &&
  (
    text.includes("startsWith(HEARTBEAT_PROMPT_PREFIX)") ||
    text.includes("includes(HEARTBEAT_PROMPT_PREFIX)") ||
    text.includes("startsWith(eT)") ||
    text.includes("includes(eT)") ||
    text.includes("startsWith(\"Read HEARTBEAT.md\")")
  ) &&
  (
    text.includes("&& !isHeartbeatTextStream(") ||
    text.includes("&&!isHeartbeatTextStream(") ||
    text.includes("&& !nT(") ||
    text.includes("&&!nT(")
  );
console.log(JSON.stringify({ bundlePath, hasRuntimeHeartbeatFilter }, null, 2));
if (!hasRuntimeHeartbeatFilter) process.exit(42);
NODE

echo "==> Verifying model failover resilience"
node - <<'NODE'
const fs = require("fs");
const p = process.env.HOME + "/.openclaw/openclaw.json";
const cfg = JSON.parse(fs.readFileSync(p, "utf8"));
const model = cfg.agents?.defaults?.model || {};
const primary = typeof model.primary === "string" ? model.primary : "";
const fallbacks = Array.isArray(model.fallbacks) ? model.fallbacks.filter((x) => typeof x === "string" && x.trim()) : [];
const providers = new Set([primary, ...fallbacks].filter(Boolean).map((m) => String(m).split("/")[0]).filter(Boolean));
const healthy = Boolean(primary) && fallbacks.length >= 2 && providers.size >= 2;
console.log(JSON.stringify({ primary, fallbackCount: fallbacks.length, providerDiversity: providers.size, healthy }, null, 2));
if (!healthy) process.exit(42);
NODE

echo "==> Checking DNS health for Telegram/Feishu endpoints"
node - <<'NODE'
const dns = require("dns").promises;
const targets = ["api.telegram.org", "open.feishu.cn"];
(async () => {
  const out = [];
  for (const host of targets) {
    try {
      const res = await dns.lookup(host);
      out.push({ host, ok: true, address: res.address, family: res.family });
    } catch (e) {
      out.push({ host, ok: false, error: String(e && e.code ? e.code : e) });
    }
  }
  console.log(JSON.stringify({ dnsChecks: out }, null, 2));
})();
NODE

echo "==> Log hotspot summary (last 5 days)"
node - <<'NODE'
const fs = require("fs");
const home = process.env.HOME;
const paths = [home + "/.openclaw/logs/gateway.log", home + "/.openclaw/logs/gateway.err.log"];
const since = Date.now() - 5 * 24 * 60 * 60 * 1000;
const defs = [
  { key: "all_models_failed", severity: 100, regex: /All models failed|complete failover exhaustion/i },
  { key: "llm_network_error", severity: 70, regex: /LLM request failed: network connection error|Connection error|fetch failed|UND_ERR_CONNECT_TIMEOUT|ECONNRESET|ECONNREFUSED/i },
  { key: "typeerror_content_filter", severity: 80, regex: /content\.filter is not a function|toolMsg\.content\.filter|msg\.content\.filter/i },
  { key: "webchat_duplicate_retry", severity: 75, regex: /duplicate reflection requests|reflection requests sent repeatedly|openclaw-control-ui.*duplicate/i },
  { key: "webchat_reconnect_storm", severity: 55, regex: /\[ws\]\s+webchat\s+(connected|disconnected)/i },
  { key: "skill_path_outside_root", severity: 65, regex: /Skipping skill path that resolves outside its configured root/i },
  { key: "timeout", severity: 45, regex: /timed out|timeout/i },
  { key: "telegram_polling_conflict", severity: 50, regex: /polling runner stopped|polling stall detected|deleteWebhook failed|getUpdates|409 Conflict|webhook/i },
];
const counts = Object.fromEntries(defs.map((d) => [d.key, 0]));
for (const p of paths) {
  if (!fs.existsSync(p)) continue;
  for (const line of fs.readFileSync(p, "utf8").split("\n")) {
    const m = line.match(/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{2}:\d{2})/);
    if (!m) continue;
    const ts = new Date(m[1]).getTime();
    if (!Number.isFinite(ts) || ts < since) continue;
    for (const d of defs) if (d.regex.test(line)) counts[d.key] += 1;
  }
}
const ranked = defs.map((d) => ({ key: d.key, count: counts[d.key], score: counts[d.key] * d.severity })).sort((a, b) => b.score - a.score);
console.log(JSON.stringify({ windowDays: 5, ranked }, null, 2));
NODE

echo "==> Webchat duplicate-display diagnostics (last 24 hours)"
node - <<'NODE'
const fs = require("fs");
const home = process.env.HOME;
const logPaths = [home + "/.openclaw/logs/gateway.log", home + "/.openclaw/logs/gateway.err.log"];
const since = Date.now() - 24 * 60 * 60 * 1000;
let wsConnect = 0;
let wsDisconnect = 0;
for (const p of logPaths) {
  if (!fs.existsSync(p)) continue;
  for (const line of fs.readFileSync(p, "utf8").split("\n")) {
    const m = line.match(/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{2}:\d{2})/);
    if (!m) continue;
    const ts = new Date(m[1]).getTime();
    if (!Number.isFinite(ts) || ts < since) continue;
    if (/\[ws\]\s+webchat connected/i.test(line)) wsConnect += 1;
    if (/\[ws\]\s+webchat disconnected/i.test(line)) wsDisconnect += 1;
  }
}

const sessionsPath = home + "/.openclaw/agents/main/sessions/sessions.json";
let transcriptPath = null;
try {
  const store = JSON.parse(fs.readFileSync(sessionsPath, "utf8"));
  const main = store["agent:main:main"];
  if (main?.sessionId) {
    transcriptPath = `${home}/.openclaw/agents/main/sessions/${main.sessionId}.jsonl`;
  }
} catch {}
let userMessages = 0;
let duplicateBuckets = 0;
let duplicateBucketsNormalized = 0;
let abortedAssistantPlaceholderCount = 0;
function extractMessageText(msg) {
  if (!msg || typeof msg !== "object") return "";
  if (typeof msg.text === "string") return msg.text;
  if (typeof msg.content === "string") return msg.content;
  if (Array.isArray(msg.content)) {
    return msg.content.map((c) => (c && typeof c.text === "string" ? c.text : "")).join("\n").trim();
  }
  return "";
}
function normalizeForDedup(text) {
  return String(text || "")
    .replace(/<relevant-memories>[\s\S]*?<\/relevant-memories>/gi, "")
    .replace(/(?:Sender|Conversation info) \(untrusted metadata\):[\s\S]*?\x60\x60\x60[\s\S]*?\x60\x60\x60/gi, "")
    .replace(/\x60\x60\x60[\s\S]*?\x60\x60\x60/g, "")
    .replace(/\s+/g, " ")
    .trim();
}
if (transcriptPath && fs.existsSync(transcriptPath)) {
  const seen = new Map();
  const seenNormalized = new Map();
  for (const line of fs.readFileSync(transcriptPath, "utf8").split("\n")) {
    if (!line.trim()) continue;
    let obj;
    try { obj = JSON.parse(line); } catch { continue; }
    const msg = obj?.message;
    if (!msg) continue;
    const ts = typeof msg.timestamp === "number" ? msg.timestamp : 0;
    if (!ts || ts < since) continue;
    if (msg.role === "assistant" && msg.stopReason === "aborted") {
      const t = extractMessageText(msg);
      if (!t || !t.trim()) abortedAssistantPlaceholderCount += 1;
    }
    if (msg.role !== "user") continue;
    const text = extractMessageText(msg);
    if (!text) continue;
    userMessages += 1;
    const key = `${text}::${msg.idempotencyKey || ""}`;
    const normalized = normalizeForDedup(text);
    const keyNormalized = `${normalized}::${msg.idempotencyKey || ""}`;
    seen.set(key, (seen.get(key) || 0) + 1);
    if (normalized) seenNormalized.set(keyNormalized, (seenNormalized.get(keyNormalized) || 0) + 1);
  }
  duplicateBuckets = [...seen.values()].filter((n) => n > 1).length;
  duplicateBucketsNormalized = [...seenNormalized.values()].filter((n) => n > 1).length;
}

console.log(
  JSON.stringify(
    {
      windowHours: 24,
      webchatWsConnect: wsConnect,
      webchatWsDisconnect: wsDisconnect,
      userMessages,
      duplicateMessageBuckets: duplicateBuckets,
      duplicateMessageBucketsNormalized: duplicateBucketsNormalized,
      abortedAssistantPlaceholderCount,
      heartbeatPollVisibleCount:
        transcriptPath && fs.existsSync(transcriptPath)
          ? fs
              .readFileSync(transcriptPath, "utf8")
              .split("\n")
              .filter((line) => {
                if (!line.trim()) return false;
                try {
                  const obj = JSON.parse(line);
                  const msg = obj?.message;
                  if (!msg || msg.role !== "user") return false;
                  const text = typeof msg.content === "string"
                    ? msg.content
                    : Array.isArray(msg.content)
                      ? msg.content.map((c) => (c && typeof c.text === "string" ? c.text : "")).join("\n")
                      : typeof msg.text === "string"
                        ? msg.text
                        : "";
                  return text.includes("Read HEARTBEAT.md");
                } catch {
                  return false;
                }
              }).length
          : 0,
      note:
        duplicateBuckets > 0 || duplicateBucketsNormalized > 0
          ? "duplicate send/display likely; prioritize normalized dedupe + aborted-placeholder filtering backport"
          : "no transcript-level duplicate bucket detected in current main session",
    },
    null,
    2,
  ),
);
NODE

echo "==> Final verification"
openclaw --version
openclaw gateway health

echo "==> Safe upgrade finished"
