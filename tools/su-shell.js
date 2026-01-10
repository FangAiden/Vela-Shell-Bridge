// Single-file IPC client for authorized QuickApps.
// Usage: import suShell from "./su-shell.js"; suShell.exec("ls").then(...);
import file from "@system.file";

const BASE_URI = "internal://files/";
const REQUEST_TIMEOUT_MS = 1250;
const EXEC_OVERALL_TIMEOUT_MS = 30000;
const DEFAULT_POLL_INTERVAL_MS = 100;
const DEFAULT_STATUS_POLL_MS = 200;
const DAEMON_RETRY_INTERVAL_MS = 5000;
const NOOP = () => {};

// Must match Lua daemon config (src/lua/app/VelaShellBridge/app/lua/app/config.lua).
const IPC_SLOT_COUNT = 2;
const IPC_PENDING = "ipc_pending";

let daemonState = "unknown";
let lastDaemonFailTime = 0;
let pendingToken = 0;

const slotInUse = [];
for (let i = 0; i < IPC_SLOT_COUNT; i++) slotInUse[i] = false;
const slotWaiters = [];

let pollerRunning = false;
let pollTimer = null;
let pendingSize = 0;
const pending = {};

export class DaemonUnavailableError extends Error {
  constructor(message) {
    super(message || "SU daemon is not available");
    this.name = "DaemonUnavailableError";
  }
}

function genRequestId() {
  return Date.now().toString() + "_" + Math.floor(Math.random() * 100000);
}

function clampInt(n, min, max, fallback) {
  const v = Math.floor(Number(n));
  if (!isFinite(v)) return fallback;
  if (v < min) return min;
  if (v > max) return max;
  return v;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function normalizeDaemonStateOnTimeout() {
  daemonState = "down";
  lastDaemonFailTime = Date.now();
}

function safeDelete(uri) {
  if (!file.delete) return;
  try {
    file.delete({ uri, success: NOOP, fail: NOOP, complete: NOOP });
  } catch (_) {}
}

function writeText(uri, text) {
  return new Promise((resolve, reject) => {
    file.writeText({
      uri,
      text: text == null ? "" : String(text),
      success() {
        resolve();
      },
      fail(_d, code) {
        reject(new Error(`Write failed: ${code}`));
      },
      complete: NOOP,
    });
  });
}

function readText(uri) {
  return new Promise((resolve, reject) => {
    file.readText({
      uri,
      success(data) {
        resolve((data && data.text) || "");
      },
      fail(_d, code) {
        reject(new Error(`Read failed: ${code}`));
      },
      complete: NOOP,
    });
  });
}

function acquireSlot() {
  for (let i = 0; i < IPC_SLOT_COUNT; i++) {
    if (!slotInUse[i]) {
      slotInUse[i] = true;
      return { promise: Promise.resolve(i), cancel() {} };
    }
  }

  let waiter = null;
  const promise = new Promise((resolve) => {
    waiter = { resolve, canceled: false };
    slotWaiters.push(waiter);
  });

  return {
    promise,
    cancel() {
      if (waiter) waiter.canceled = true;
    },
  };
}

function releaseSlot(slot) {
  while (slotWaiters.length) {
    const w = slotWaiters.shift();
    if (!w || w.canceled) continue;
    slotInUse[slot] = true;
    w.resolve(slot);
    return;
  }
  slotInUse[slot] = false;
}

function addPending(entry) {
  pending[entry.id] = entry;
  pendingSize += 1;
  if (!pollerRunning) {
    pollerRunning = true;
    pollTimer = setTimeout(pollTick, 0);
  }
}

function removePending(id) {
  const entry = pending[id];
  if (!entry) return null;
  delete pending[id];
  pendingSize -= 1;
  return entry;
}

function minPollIntervalMs() {
  let min = 2000;
  for (const id in pending) {
    const it = pending[id];
    if (!it) continue;
    const v = it.pollInterval;
    if (typeof v === "number" && isFinite(v)) {
      if (v < min) min = v;
    }
  }
  return clampInt(min, 30, 2000, DEFAULT_POLL_INTERVAL_MS);
}

async function pollTick() {
  if (pendingSize <= 0) {
    pollerRunning = false;
    pollTimer = null;
    return;
  }

  const ids = Object.keys(pending);
  for (const id of ids) {
    const entry = pending[id];
    if (!entry) continue;

    let txt;
    try {
      txt = await readText(entry.resUri);
    } catch (_) {
      continue;
    }

    let obj;
    try {
      obj = JSON.parse(txt || "{}");
    } catch (_) {
      continue;
    }

    if (!obj || obj.id !== entry.id) continue;

    daemonState = "up";
    removePending(entry.id);
    clearTimeout(entry.timeoutId);
    safeDelete(entry.resUri);
    releaseSlot(entry.slot);

    try {
      entry.resolve(obj);
    } catch (_) {}
  }

  if (pendingSize <= 0) {
    pollerRunning = false;
    pollTimer = null;
    return;
  }

  pollTimer = setTimeout(pollTick, minPollIntervalMs());
}

export function sendIpcRequest(payload, options = {}) {
  const baseUri = options.baseUri || BASE_URI;
  const pollInterval = clampInt(
    options.pollInterval,
    30,
    2000,
    DEFAULT_POLL_INTERVAL_MS
  );
  const timeoutMs =
    options.timeoutMs != null ? options.timeoutMs : REQUEST_TIMEOUT_MS;

  if (daemonState === "down") {
    const now = Date.now();
    if (now - lastDaemonFailTime < DAEMON_RETRY_INTERVAL_MS) {
      return Promise.reject(
        new DaemonUnavailableError("SU daemon is down (cached)")
      );
    }
  }

  const id = payload.id || genRequestId();
  payload.id = id;
  const resUri = `${baseUri}ipc_response_${id}.json`;
  const text = JSON.stringify(payload);

  return new Promise((resolve, reject) => {
    let settled = false;
    let acquiredSlot = null;
    let slot = null;

    const timeoutId = setTimeout(() => {
      if (settled) return;
      settled = true;
      normalizeDaemonStateOnTimeout();

      if (acquiredSlot) acquiredSlot.cancel();

      const entry = removePending(id);
      if (entry) {
        safeDelete(entry.resUri);
        releaseSlot(entry.slot);
      } else if (slot != null) {
        releaseSlot(slot);
      }

      reject(new DaemonUnavailableError(`Timeout ${timeoutMs}ms (id=${id})`));
    }, timeoutMs);

    acquiredSlot = acquireSlot();
    acquiredSlot.promise.then(async (s) => {
      slot = s;
      if (settled) {
        releaseSlot(slot);
        return;
      }

      const reqUri = `${baseUri}ipc_slot_${slot}.req.json`;
      const readyUri = `${baseUri}ipc_slot_${slot}.ready`;
      const pendingUri = `${baseUri}${IPC_PENDING}`;

      try {
        await writeText(reqUri, text);
        await writeText(readyUri, id);
        pendingToken += 1;
        await writeText(pendingUri, String(pendingToken));
      } catch (e) {
        if (settled) {
          releaseSlot(slot);
          return;
        }
        settled = true;
        clearTimeout(timeoutId);
        releaseSlot(slot);
        reject(e);
        return;
      }

      if (settled) {
        releaseSlot(slot);
        return;
      }

      addPending({
        id,
        slot,
        resUri,
        pollInterval,
        timeoutId,
        resolve,
        reject,
      });
    });
  });
}

export async function exec(shellCmd, options = {}) {
  if (!shellCmd || typeof shellCmd !== "string") {
    throw new Error("Cmd required");
  }

  const isSync = options.sync !== false;
  const overallTimeoutMs = options.timeoutMs || EXEC_OVERALL_TIMEOUT_MS;
  const statusPollInterval = clampInt(
    options.statusPollInterval,
    50,
    2000,
    DEFAULT_STATUS_POLL_MS
  );

  const startResp = await sendIpcRequest(
    {
      type: "exec",
      cmd: "exec",
      args: { shell: shellCmd, sync: isSync },
    },
    {
      baseUri: options.baseUri,
      pollInterval: options.pollInterval,
      timeoutMs: isSync ? overallTimeoutMs + 2000 : REQUEST_TIMEOUT_MS,
    }
  );

  if (!startResp || !startResp.ok) {
    throw new Error((startResp && startResp.message) || "Exec start failed");
  }

  if (startResp.job_id && typeof options.onStart === "function") {
    try {
      options.onStart(startResp.job_id);
    } catch (_) {}
  }

  if (isSync) {
    const data = startResp.result || startResp.data || {};
    return {
      id: startResp.id,
      ok: true,
      mode: "sync",
      exitCode: data.exit_code,
      output: data.output,
      raw: startResp,
    };
  }

  const jobId = startResp.job_id;
  if (!jobId) {
    throw new Error("Missing job_id for async exec");
  }
  const startTime = Date.now();

  while (true) {
    if (Date.now() - startTime > overallTimeoutMs) {
      throw new Error(`Timeout ${overallTimeoutMs}ms`);
    }
    await sleep(statusPollInterval);

    const stResp = await sendIpcRequest(
      {
        type: "exec",
        cmd: "exec",
        args: { job_id: jobId },
      },
      { baseUri: options.baseUri, timeoutMs: REQUEST_TIMEOUT_MS }
    );

    if (!stResp || !stResp.ok) {
      throw new Error((stResp && stResp.message) || "Status failed");
    }

    if (stResp.result && typeof options.onProgress === "function") {
      try {
        const output = stResp.result.output;
        const pid = stResp.result.pid;
        if (output || pid) {
          options.onProgress(output, jobId, pid);
        }
      } catch (_) {}
    }

    if (stResp.state === "done") {
      const data = stResp.result || {};
      return {
        id: stResp.id,
        ok: true,
        mode: "async",
        jobId,
        exitCode: data.exit_code,
        output: data.output,
        pid: data.pid,
        raw: stResp,
      };
    }
  }
}

export function execSync(shellCmd, options = {}) {
  return exec(shellCmd, Object.assign({}, options, { sync: true }));
}

export async function kill(jobId, options = {}) {
  if (!jobId) throw new Error("jobId required");
  const resp = await sendIpcRequest(
    { type: "exec", cmd: "kill", args: { job_id: jobId } },
    {
      baseUri: options.baseUri,
      timeoutMs: options.timeoutMs || REQUEST_TIMEOUT_MS * 2,
    }
  );
  if (!resp || !resp.ok) throw new Error((resp && resp.message) || "kill failed");
  return resp.data || resp;
}

const suShell = { exec, execSync, kill, sendIpcRequest, DaemonUnavailableError };

export default suShell;
