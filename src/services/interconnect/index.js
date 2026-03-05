import interconnect from "@system.interconnect";
import suIpc from "../su-daemon/index.js";
import { getCachedLocalSettings, getLocalSettings, updateLocalSettings } from "../../shared/settings/local-settings.js";

const PROTOCOL_VERSION = 1;
const DEFAULT_RPC_TIMEOUT_MS = 15000;
const MAX_REPLY_CHARS = 12000;

const STATE = {
  remoteEnabled: false,
  token: "",
  connected: false,
  readyState: -1,
  lastOpenAt: 0,
  lastCloseAt: 0,
  lastCloseCode: 0,
  lastCloseReason: "",
  lastErrorAt: 0,
  lastErrorCode: 0,
  lastErrorMessage: "",
};

let conn = null;
let started = false;

function clampInt(n, min, max, fallback) {
  const v = Math.floor(Number(n));
  if (!isFinite(v)) return fallback;
  if (v < min) return min;
  if (v > max) return max;
  return v;
}

function safeStr(v) {
  if (v == null) return "";
  return String(v);
}

function parseInterconnectError(data, code, fallback) {
  const out = {
    code: 0,
    message: safeStr(fallback || ""),
  };
  const codeNum = Number(code);
  if (isFinite(codeNum) && codeNum !== 0) out.code = codeNum;

  if (data && typeof data === "object") {
    const c = Number(data.code);
    if (isFinite(c) && c !== 0) out.code = c;

    const d = safeStr(data.data).trim();
    if (d) out.message = d;
    else {
      const m = safeStr(data.message).trim();
      if (m) out.message = m;
    }
  } else {
    const s = safeStr(data).trim();
    if (s) out.message = s;
  }
  return out;
}

function recordLastError(data, code, fallback) {
  const err = parseInterconnectError(data, code, fallback);
  STATE.lastErrorAt = Date.now();
  STATE.lastErrorCode = err.code;
  STATE.lastErrorMessage = err.message || safeStr(fallback || "");
}

function isToken4(v) {
  return /^\d{4}$/.test(safeStr(v).trim());
}

function genToken4() {
  let n = 0;
  if (typeof crypto !== "undefined" && crypto.getRandomValues) {
    const arr = new Uint16Array(1);
    crypto.getRandomValues(arr);
    n = arr[0] % 10000;
  } else {
    n = Math.floor(Math.random() * 10000);
  }
  return String(n).padStart(4, "0");
}

async function loadRemoteConfig() {
  const local = await getLocalSettings().catch(() => getCachedLocalSettings());
  const remote = local && typeof local.remote === "object" ? local.remote : {};
  STATE.remoteEnabled = !!remote.enabled;
  const token = safeStr(remote.token).trim();
  STATE.token = isToken4(token) ? token : "";
}

async function ensureTokenIfEnabled() {
  if (!STATE.remoteEnabled) return;
  if (isToken4(STATE.token)) return;
  const nextToken = genToken4();
  const next = await updateLocalSettings({ remote: { token: nextToken } }).catch(() => null);
  const remote = next && typeof next.remote === "object" ? next.remote : {};
  const saved = safeStr(remote.token).trim();
  STATE.token = isToken4(saved) ? saved : nextToken;
}

function normalizeIncomingData(raw) {
  if (raw == null) return null;
  if (typeof raw === "object") return raw;
  const text = safeStr(raw).trim();
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch (_) {
    return null;
  }
}

function sanitizeReply(obj) {
  try {
    const text = JSON.stringify(obj);
    if (text.length <= MAX_REPLY_CHARS) return obj;

    if (obj && obj.ok && obj.result && typeof obj.result.output === "string") {
      const keep = Math.max(0, MAX_REPLY_CHARS - 300);
      obj.result.output = obj.result.output.slice(0, keep) + "\n...(truncated)";
      obj.result.truncated = true;
      return obj;
    }
  } catch (_) {}
  return {
    v: PROTOCOL_VERSION,
    id: obj && obj.id ? obj.id : "",
    ok: false,
    error: { code: "REPLY_TOO_LARGE", message: "Reply too large" },
    message: "Reply too large",
  };
}

function sendReply(payload) {
  if (!conn) return;
  const safe = sanitizeReply(payload);
  const text = JSON.stringify(safe);

  let triedFallback = false;
  const sendWith = (useText) => {
    const packet = useText ? text : safe;
    try {
      conn.send({
        data: packet,
        success() {},
        fail(data, code) {
          const err = parseInterconnectError(data, code, "send failed");
          if (!triedFallback && /invalid\s*data/i.test(err.message || "")) {
            triedFallback = true;
            sendWith(!useText);
            return;
          }
          recordLastError(data, code, "send failed");
        },
      });
    } catch (e) {
      if (!triedFallback && /invalid\s*data/i.test(safeStr(e && e.message))) {
        triedFallback = true;
        sendWith(!useText);
        return;
      }
      recordLastError(e, 0, "send throw");
    }
  };

  // Interconnect demo uses object payload (`data: {...}`); keep it as primary.
  // Fallback to string when peer expects JSON text.
  sendWith(false);
}

async function mgmt(cmd, args, options = {}) {
  const timeoutMs = clampInt(options.timeoutMs, 200, 60000, 3000);
  const resp = await suIpc.management(cmd, args || {}, { timeoutMs });
  if (!resp || resp.ok !== true) {
    throw new Error((resp && resp.message) || `${cmd} failed`);
  }
  return resp.data;
}

function reject(id, code, message, extra) {
  const payload = {
    v: PROTOCOL_VERSION,
    id,
    ok: false,
    error: { code, message },
    message,
  };
  if (extra && typeof extra === "object") Object.assign(payload, extra);
  return payload;
}

function resolve(id, result) {
  return { v: PROTOCOL_VERSION, id, ok: true, result: result == null ? null : result };
}

async function handleRpc(req) {
  const id = safeStr(req && req.id).trim();
  const method = safeStr(req && req.method).trim();
  const params = req && typeof req.params === "object" ? req.params : {};

  if (!id || !method) {
    return reject(id || "", "BAD_REQUEST", "id/method required");
  }

  if (method === "hello") {
    return resolve(id, {
      server: "VelaShellBridge",
      protocol: PROTOCOL_VERSION,
      remoteEnabled: STATE.remoteEnabled,
      hasToken: !!STATE.token,
      ts: Date.now(),
    });
  }

  if (!STATE.remoteEnabled) {
    return reject(id, "REMOTE_DISABLED", "Remote control disabled");
  }

  if (STATE.token) {
    const token = safeStr(req && req.token).trim();
    if (!token || token !== STATE.token) {
      return reject(id, "AUTH_FAILED", "Invalid token");
    }
  }

  if (method === "shell.exec") {
    const cmd = safeStr(params && params.cmd).trim();
    if (!cmd) return reject(id, "BAD_REQUEST", "params.cmd required");
    const timeoutMs = clampInt(params && params.timeoutMs, 300, 60000, DEFAULT_RPC_TIMEOUT_MS);
    const sync = params && params.sync !== false;

    const res = await suIpc.exec(cmd, { sync, timeoutMs });
    const raw = res && res.raw ? res.raw : {};
    const cwd =
      raw && raw.result && raw.result.cwd != null ? safeStr(raw.result.cwd)
        : raw && raw.data && raw.data.cwd != null ? safeStr(raw.data.cwd)
          : "";

    return resolve(id, {
      cmd,
      mode: res && res.mode ? res.mode : sync ? "sync" : "async",
      exitCode: res && res.exitCode != null ? res.exitCode : null,
      output: res && res.output != null ? safeStr(res.output) : "",
      pid: res && res.pid != null ? res.pid : null,
      jobId: res && res.jobId ? res.jobId : null,
      cwd,
    });
  }

  if (method === "fs.read") {
    const path = safeStr(params && params.path).trim();
    if (!path) return reject(id, "BAD_REQUEST", "params.path required");

    const offset = clampInt(params && params.offset, 0, 0x7fffffff, 0);
    const length = clampInt(params && params.length, 1, 32 * 1024, 2048);
    const encoding = safeStr(params && params.encoding).trim() || "base64";

    const data = await mgmt("fs_read", { path, offset, length, encoding }, { timeoutMs: 6000 });
    return resolve(id, data);
  }

  if (method === "fs.write") {
    const path = safeStr(params && params.path).trim();
    const data = safeStr(params && params.data);
    if (!path) return reject(id, "BAD_REQUEST", "params.path required");
    if (!data) return reject(id, "BAD_REQUEST", "params.data required");

    const mode = safeStr(params && params.mode).trim() || "append"; // append | truncate
    const encoding = safeStr(params && params.encoding).trim() || "base64";

    const out = await mgmt("fs_write", { path, data, mode, encoding }, { timeoutMs: 12000 });
    return resolve(id, out);
  }

  if (method === "fs.stat") {
    const path = safeStr(params && params.path).trim();
    if (!path) return reject(id, "BAD_REQUEST", "params.path required");
    const out = await mgmt("fs_stat", { path }, { timeoutMs: 3000 });
    return resolve(id, out);
  }

  if (method === "shell.getCwd") {
    const out = await mgmt("shell_get_cwd", {}, { timeoutMs: 1500 });
    return resolve(id, out);
  }

  if (method === "shell.setCwd") {
    const cwd = safeStr(params && params.cwd).trim();
    if (!cwd) return reject(id, "BAD_REQUEST", "params.cwd required");
    const out = await mgmt("shell_set_cwd", { cwd }, { timeoutMs: 1500 });
    return resolve(id, out);
  }

  return reject(id, "UNKNOWN_METHOD", `Unknown method: ${method}`);
}

function onMessage(evt) {
  const raw =
    evt && typeof evt === "object" && Object.prototype.hasOwnProperty.call(evt, "data")
      ? evt.data
      : evt;
  const payload = normalizeIncomingData(raw);
  if (!payload || typeof payload !== "object") {
    return;
  }
  handleRpc(payload)
    .then((resp) => sendReply(resp))
    .catch((e) => {
      const id = safeStr(payload && payload.id).trim();
      sendReply(reject(id, "INTERNAL_ERROR", e && e.message ? e.message : "internal error"));
    });
}

function startConn() {
  if (started) return;
  started = true;

  try {
    conn = interconnect.instance();
  } catch (e) {
    conn = null;
    started = false;
    STATE.lastErrorAt = Date.now();
    STATE.lastErrorMessage = e && e.message ? e.message : "interconnect.instance failed";
    return;
  }

  try {
    conn.getReadyState({
      success(data) {
        STATE.readyState = data && data.status != null ? data.status : -1;
      },
      fail(data, code) {
        STATE.readyState = -1;
        STATE.connected = false;
        recordLastError(data, code, "getReadyState failed");
      },
    });
  } catch (_) {}

  conn.onmessage = onMessage;
  conn.onopen = () => {
    STATE.connected = true;
    STATE.lastOpenAt = Date.now();
  };
  conn.onclose = (data) => {
    STATE.connected = false;
    STATE.lastCloseAt = Date.now();
    {
      const err = parseInterconnectError(data, 0, "");
      STATE.lastCloseCode = err.code;
      STATE.lastCloseReason = err.message;
    }
  };
  conn.onerror = (data) => {
    STATE.connected = false;
    recordLastError(data, 0, "connection error");
  };
}

function stopConn() {
  started = false;
  conn = null;
  STATE.connected = false;
  STATE.readyState = -1;
}

export async function initInterconnectBridge() {
  await loadRemoteConfig();
  await ensureTokenIfEnabled();
  if (STATE.remoteEnabled) {
    startConn();
  } else {
    stopConn();
  }
  return getInterconnectState();
}

export async function reloadInterconnectBridgeConfig() {
  await loadRemoteConfig();
  await ensureTokenIfEnabled();
  if (STATE.remoteEnabled) startConn();
  else stopConn();
  return getInterconnectState();
}

export function getInterconnectState() {
  return Object.assign({}, STATE, {
    tokenMasked: STATE.token ? `${STATE.token.slice(0, 2)}****` : "",
  });
}

