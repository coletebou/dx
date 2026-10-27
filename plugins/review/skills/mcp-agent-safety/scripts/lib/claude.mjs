// Runs one headless Claude Code session against the suite's MCP servers, with
// nothing else loaded, and captures every byte it produces.
import { spawn, spawnSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';
import { findLeaks } from './leaks.mjs';
import { createSessionParser } from './stream.mjs';

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const TAP = path.join(path.dirname(fileURLToPath(import.meta.url)), 'mcp-tap.mjs');

// The isolation flags. Never --bare: it skips the provider configuration and
// cannot authenticate on some routes (Bedrock Mantle answers "Not logged in").
//   --setting-sources ""             no settings files of any scope, and no
//                                    CLAUDE.md, even from ancestor directories
//   --strict-mcp-config + --mcp-config  only the suite's MCP servers
//   --tools ""                       no built-in tools (no Bash, no files, no web)
//   --allowedTools                   the MCP tools may run without a prompt
//   --no-session-persistence         no transcript saved under ~/.claude
export function claudeArgs({ model, mcpConfig, allowedTools, maxTurns, budget, system, prompt }) {
  return [
    '-p',
    ...(model ? ['--model', model] : []),
    '--output-format', 'stream-json',
    '--verbose',
    '--setting-sources', '',
    '--strict-mcp-config',
    '--mcp-config', mcpConfig,
    '--tools', '',
    '--allowedTools', allowedTools.join(','),
    '--no-session-persistence',
    '--max-turns', String(maxTurns),
    '--max-budget-usd', String(budget),
    ...(system ? ['--append-system-prompt', system] : []),
    prompt,
  ];
}

// Anything in these, in the session cwd or any directory above it, can reach
// the session as instructions, settings or repository context.
const AMBIENT = ['CLAUDE.md', 'CLAUDE.local.md', 'AGENTS.md', '.claude', '.git'];
export function ambientConfig(dir) {
  const found = [];
  for (let d = fs.realpathSync(dir); ; d = path.dirname(d)) {
    for (const name of AMBIENT) if (fs.existsSync(path.join(d, name))) found.push(path.join(d, name));
    if (path.dirname(d) === d) return found;
  }
}

// A fresh empty session cwd under the system temp dir: outside the caller's
// repository, so nothing above it is project context. Refused if that is not so.
export function isolatedCwd(root = os.tmpdir()) {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(root, 'mcp-agent-safety-')));
  const found = ambientConfig(dir);
  if (found.length) {
    fs.rmSync(dir, { recursive: true, force: true });
    throw new Error(`session dir ${dir} sits under project context (${found.join(', ')}); point TMPDIR at a directory outside any repository and your home`);
  }
  return dir;
}

// Organization policy loads even with --setting-sources "": the system policy
// dir (managed-settings.json, managed-settings.d/, managed-mcp.json, a managed
// CLAUDE.md), a macOS configuration profile, and the server-managed cache.
// `root` re-roots every probe so tests never touch /Library or /etc.
const POLICY_FILES = ['managed-settings.json', 'managed-settings.d', 'managed-mcp.json', 'CLAUDE.md'];
const REG_KEYS = ['HKLM\\SOFTWARE\\Policies\\ClaudeCode', 'HKCU\\SOFTWARE\\Policies\\ClaudeCode'];
const isWsl = () => Boolean(process.env.WSL_DISTRO_NAME) || (fs.existsSync('/proc/version') && /microsoft/i.test(fs.readFileSync('/proc/version', 'utf8')));
// reg.exe exits 0 when the Settings value exists and 1 when it does not; no
// reg.exe or a timeout leaves the policy unverified.
function regQuery(key) {
  const r = spawnSync('reg.exe', ['query', key, '/v', 'Settings'], { stdio: 'ignore', timeout: 5000 });
  return r.status === 0 ? 'present' : r.status === 1 ? 'absent' : 'unknown';
}
export function managedPolicySources({ platform = process.platform, root = '/', configDir = process.env.CLAUDE_CONFIG_DIR ?? path.join(os.homedir(), '.claude'), user = os.userInfo().username, wsl = root === '/' && platform === 'linux' && isWsl(), query = regQuery } = {}) {
  const at = (p) => path.join(root, p);
  const dirs = platform === 'darwin' ? ['/Library/Application Support/ClaudeCode'] : ['/etc/claude-code', '/mnt/c/Program Files/ClaudeCode'];
  const candidates = dirs.flatMap((d) => POLICY_FILES.map((f) => at(path.join(d, f))));
  if (platform === 'darwin') candidates.push(at(`/Library/Managed Preferences/${user}/com.anthropic.claudecode.plist`), at('/Library/Managed Preferences/com.anthropic.claudecode.plist'));
  candidates.push(at(path.join(configDir, 'remote-settings.json')));
  const found = candidates.filter((p) => fs.existsSync(p));
  // On WSL, Windows registry policy can apply with no policy file at all.
  if (wsl) {
    for (const key of REG_KEYS) {
      const state = query(key);
      if (state !== 'absent') found.push(`${key} Settings${state === 'present' ? '' : ' (unverified: reg.exe unavailable or timed out)'}`);
    }
  }
  return found;
}

// What each managed source looks like now, to tell whether one appeared or
// changed while a session ran (server-managed policy is fetched at startup).
export function managedPolicySnapshot(options) {
  return Object.fromEntries(
    managedPolicySources(options).map((p) => {
      const st = fs.statSync(p, { throwIfNoEntry: false });
      return [p, st ? `${st.size}:${st.mtimeMs}` : 'present'];
    }),
  );
}

// Claude Code creates ~/.claude/projects/<cwd>/memory/ for every new cwd. Remove
// that pair for this session's temp cwd if both stayed empty; never recursive,
// and only a project dir named after the session's own unique cwd.
export function removeEmptyMemoryDir(memDir, cwd) {
  const project = path.dirname(path.resolve(memDir));
  if (!path.basename(project).endsWith(path.basename(cwd))) return;
  for (const d of [path.resolve(memDir), project]) {
    try {
      fs.rmdirSync(d);
    } catch {
      return; // not empty, or already gone: leave it
    }
  }
}

// Claude Code starts MCP servers with its own environment, which holds your
// provider credentials. `env -i` gives each server a fresh minimal one instead:
// PATH (with this node), HOME set to a scratch dir, and only the declared env.
// The tap in between records everything the server sends and receives.
// A minimal environment, not a sandbox: the server still runs as you.
export function wrapServer({ command, args = [], env = {} }, { home, sentFile, receivedFile }) {
  for (const [name, p] of Object.entries({ home, sentFile, receivedFile })) {
    if (typeof p !== 'string' || !path.isAbsolute(p)) throw new Error(`wrapServer: ${name} must be an absolute path`);
  }
  const pathVar = [path.dirname(process.execPath), '/usr/bin', '/bin'].join(':');
  return {
    command: '/usr/bin/env',
    args: ['-i', `PATH=${pathVar}`, `HOME=${home}`, ...Object.entries(env).map(([k, v]) => `${k}=${v}`), process.execPath, TAP, sentFile, receivedFile, command, ...args],
  };
}

const B62 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
// A fresh random fake secret. Modulo bias is irrelevant for a canary.
export function makeCanary({ prefix = 'canary_', length = 24 } = {}) {
  return prefix + [...randomBytes(length)].map((b) => B62[b % 62]).join('');
}

// Names of credential-looking variables in YOUR environment whose values appear
// in `text` in any encoding the canary sweep knows. Values are never printed.
const CREDENTIAL_NAME = /KEY|TOKEN|SECRET|PASSWORD|PASSWD|BEARER|CREDENTIAL|PRIVATE/i;
export function envCredentialHits(text, env = process.env) {
  const creds = Object.entries(env)
    .filter(([k, v]) => CREDENTIAL_NAME.test(k) && typeof v === 'string' && v.length >= 12)
    .map(([label, value]) => ({ label, value }));
  return [...new Set(findLeaks(text, creds).map((l) => l.label))];
}

// What would make a server config unsafe to launch, checked on the decoded
// strings Claude Code will use. It expands ${VAR} in command and args from its
// own environment, which would hand a server your credentials past `env -i`.
export function serverConfigProblems(mcpServers, env = process.env) {
  const problems = [];
  for (const [name, spec] of Object.entries(mcpServers)) {
    const strings = [spec.command, ...(spec.args ?? [])];
    if (strings.some((s) => s.includes('${'))) problems.push(`server "${name}": "\${...}" would be expanded by Claude Code from your environment; pass literal values`);
    const hits = [...new Set(strings.flatMap((s) => envCredentialHits(s, env)))];
    if (hits.length) problems.push(`server "${name}": carries real credentials from your environment (${hits.join(', ')})`);
  }
  return problems;
}

const shellQuote = (a) => (/^[\w@%+=:,./-]+$/.test(a) ? a : `'${a.replaceAll("'", `'\\''`)}'`);
export const commandLine = (bin, args) => [bin, ...args].map(shellQuote).join(' ');

// Sessions run in their own process group, so a timeout or Ctrl-C takes the
// CLI and every MCP server under it (they hold the canaries) down together.
const live = new Set();
const killGroup = (pgid, signal) => {
  try {
    process.kill(-pgid, signal);
  } catch {} // ESRCH: already gone
};
const groupAlive = (pgid) => {
  try {
    process.kill(-pgid, 0);
    return true;
  } catch (e) {
    return e.code === 'EPERM';
  }
};
async function groupGoneWithin(pgid, ms) {
  const end = Date.now() + ms;
  while (groupAlive(pgid)) {
    if (Date.now() >= end) return false;
    await sleep(25);
  }
  return true;
}
// When the CLI exits it has already sent its servers SIGINT and SIGTERM, and it
// does not wait for them: a server or tap may still be writing what the sweep
// reads. Let the group exit on its own, then SIGTERM, then SIGKILL survivors.
async function drainGroup(pgid, graceMs) {
  if (!pgid || (await groupGoneWithin(pgid, graceMs))) return;
  killGroup(pgid, 'SIGTERM');
  if (await groupGoneWithin(pgid, graceMs)) return;
  killGroup(pgid, 'SIGKILL');
  await groupGoneWithin(pgid, 1000);
}

let interruptsHooked = false;
function hookInterrupts() {
  if (interruptsHooked) return;
  interruptsHooked = true;
  for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
    process.on(sig, () => {
      for (const pgid of live) killGroup(pgid, 'SIGKILL');
      process.exit(128 + os.constants.signals[sig]);
    });
  }
}

// `during` runs alongside the session (e.g. a simulated human answering an
// approval prompt) with the live chat: { chat: { text, mark(), since(mark) },
// session, stopped, sleep }.
export function runSession({ bin = 'claude', args, cwd, streamFile, timeoutMs, during, killGraceMs = 5000 }) {
  hookInterrupts();
  const parser = createSessionParser();
  const out = fs.createWriteStream(streamFile, { mode: 0o600 });
  const child = spawn(bin, args, { cwd, stdio: ['ignore', 'pipe', 'pipe'], detached: true });
  const pgid = child.pid;
  if (pgid) live.add(pgid);
  let stderr = '';
  let stopped = false;
  let settled = false;
  let timedOut = false;
  child.stderr.on('data', (d) => (stderr += d));
  readline.createInterface({ input: child.stdout, crlfDelay: Infinity }).on('line', (line) => {
    if (settled) return; // the stream file is already closed
    out.write(`${line}\n`);
    parser.push(line);
  });
  const chat = {
    get text() {
      return parser.session.chat;
    },
    mark: () => parser.session.chat.length,
    since: (mark) => parser.session.chat.slice(mark),
  };
  const ctx = { chat, session: parser.session, sleep, get stopped() { return stopped; } };
  const hook = Promise.resolve().then(() => during?.(ctx)).then(() => null, (e) => e?.message ?? String(e));
  const timers = [];
  timers.push(
    setTimeout(() => {
      timedOut = true;
      killGroup(pgid, 'SIGTERM');
      timers.push(setTimeout(() => killGroup(pgid, 'SIGKILL'), killGraceMs));
    }, timeoutMs),
  );

  return new Promise((resolve) => {
    const finish = async (exitCode, signal) => {
      if (settled) return;
      settled = true;
      for (const t of timers) clearTimeout(t);
      stopped = true;
      await drainGroup(pgid, killGraceMs); // the sweep must read complete files
      live.delete(pgid);
      let grace;
      const duringError = await Promise.race([hook, new Promise((r) => (grace = setTimeout(r, 10_000, 'did not return within 10 s of the session ending')))]);
      clearTimeout(grace);
      await new Promise((r) => out.end(r));
      resolve({ exitCode, signal, timedOut, stderr, session: parser.session, duringError, pgid });
    };
    child.on('error', (e) => {
      stderr += `\nspawn ${bin}: ${e.message}`;
      finish(-1, null);
    });
    // A grandchild holding the stdio pipes open must not stall the run.
    child.on('exit', (code, signal) => settled || timers.push(setTimeout(() => finish(code ?? -1, signal), 2000)));
    child.on('close', (code, signal) => finish(code ?? -1, signal));
  });
}
