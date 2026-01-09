// Single-file IPC client for authorized QuickApps.
// Usage: import suShell from "./su-shell.js"; suShell.exec("ls").then(...);
import file from "@system.file";

const BASE_URI = "internal://files/";
const REQUEST_TIMEOUT_MS = 1250;
const EXEC_OVERALL_TIMEOUT_MS = 30000;
const DEFAULT_POLL_INTERVAL_MS = 100;
const DEFAULT_STATUS_POLL_MS = 200;
const DAEMON_RETRY_INTERVAL_MS = 5000;

let daemonState = "unknown";
let lastDaemonFailTime = 0;

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
  const reqUri = `${baseUri}ipc_request_${id}.json`;
  const resUri = `${baseUri}ipc_response_${id}.json`;
  const text = JSON.stringify(payload);

  return new Promise((resolve, reject) => {
    let settled = false;
    const timeoutId = setTimeout(() => {
      if (settled) return;
      settled = true;
      normalizeDaemonStateOnTimeout();
      reject(new DaemonUnavailableError(`Timeout ${timeoutMs}ms (id=${id})`));
    }, timeoutMs);

    function safeSettle(fn) {
      if (settled) return;
      settled = true;
      clearTimeout(timeoutId);
      try {
        fn();
      } catch (e) {
        reject(e);
      }
    }

    function pollResponse() {
      if (settled) return;
      file.readText({
        uri: resUri,
        success(data) {
          if (settled) return;
          let obj;
          try {
            obj = JSON.parse(data.text || "{}");
          } catch (_) {
            setTimeout(pollResponse, pollInterval);
            return;
          }
          if (!obj || obj.id !== id) {
            setTimeout(pollResponse, pollInterval);
            return;
          }
          daemonState = "up";
          safeSettle(() => {
            if (file.delete) {
              try {
                file.delete({ uri: resUri });
              } catch (_) {}
            }
            resolve(obj);
          });
        },
        fail() {
          if (!settled) setTimeout(pollResponse, pollInterval);
        },
      });
    }

    file.writeText({
      uri: reqUri,
      text,
      success() {
        setTimeout(pollResponse, pollInterval);
      },
      fail(_d, code) {
        safeSettle(() => {
          reject(new Error(`Write failed: ${code}`));
        });
      },
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
