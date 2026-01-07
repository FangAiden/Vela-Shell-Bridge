// src/pages/su-ipc-public.js
// Minimal IPC client for external apps: exec + kill only (no management APIs).
import file from "@system.file";

const BASE = "internal://files/";
const REQUEST_TIMEOUT = 1250;
const EXEC_OVERALL_TIMEOUT = 30000;
const STATUS_POLL_INTERVAL = 200;

let currentExecution = null;
let daemonState = "unknown";
let lastDaemonFailTime = 0;
const DAEMON_RETRY_INTERVAL = 5000;

function genRequestId() {
  return Date.now().toString() + "_" + Math.floor(Math.random() * 100000);
}

class DaemonUnavailableError extends Error {
  constructor(message) {
    super(message || "SU daemon is not available");
    this.name = "DaemonUnavailableError";
  }
}

function sendIpcRequest(payload, options = {}) {
  const baseUri = options.baseUri || BASE;
  const pollInterval = options.pollInterval || 100;
  const timeoutMs = options.timeoutMs || REQUEST_TIMEOUT;

  if (daemonState === "down") {
    const now = Date.now();
    if (now - lastDaemonFailTime < DAEMON_RETRY_INTERVAL) {
      return Promise.reject(new DaemonUnavailableError("SU daemon is down (cached)"));
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
      daemonState = "down";
      lastDaemonFailTime = Date.now();
      reject(new DaemonUnavailableError(`Timeout ${timeoutMs}ms (id=${id})`));
    }, timeoutMs);

    function safeSettle(fn) {
      if (settled) return;
      settled = true;
      clearTimeout(timeoutId);
      try { fn(); } catch (e) { reject(e); }
    }

    function pollResponse() {
      if (settled) return;
      file.readText({
        uri: resUri,
        success(data) {
          if (settled) return;
          let obj;
          try { obj = JSON.parse(data.text || "{}"); } catch (_) { setTimeout(pollResponse, pollInterval); return; }
          if (!obj || obj.id !== id) { setTimeout(pollResponse, pollInterval); return; }
          daemonState = "up";
          safeSettle(() => {
            if (file.delete) try { file.delete({ uri: resUri }); } catch (_) {}
            resolve(obj);
          });
        },
        fail() { if (!settled) setTimeout(pollResponse, pollInterval); }
      });
    }

    file.writeText({
      uri: reqUri,
      text,
      success() { setTimeout(pollResponse, pollInterval); },
      fail(_d, code) { safeSettle(() => { reject(new Error(`Write failed: ${code}`)); }); }
    });
  });
}

function runExclusive(taskFn) {
  if (currentExecution) return Promise.reject(new Error("BUSY: Previous command running"));
  const p = Promise.resolve().then(taskFn);
  currentExecution = p;
  const unlock = () => { if (currentExecution === p) currentExecution = null; };
  return p.then(v => { unlock(); return v; }, e => { unlock(); throw e; });
}

function clampInt(n, minv, maxv, fallback) {
  const v = Math.floor(Number(n));
  if (!isFinite(v)) return fallback;
  if (v < minv) return minv;
  if (v > maxv) return maxv;
  return v;
}

function suExec(shellCmd, options = {}) {
  if (!shellCmd || typeof shellCmd !== "string") return Promise.reject(new Error("Cmd required"));

  const isSync = options.sync === true;
  const onProgress = options.onProgress;
  const onStart = options.onStart;
  const overallTimeoutMs = options.timeoutMs || EXEC_OVERALL_TIMEOUT;

  return runExclusive(async () => {
    const pollInterval = clampInt(
      options.statusPollInterval,
      50,
      2000,
      STATUS_POLL_INTERVAL
    );

    let startResp;
    startResp = await sendIpcRequest({
      type: "exec",
      cmd: "exec",
      args: { shell: shellCmd, sync: isSync }
    }, { timeoutMs: isSync ? (overallTimeoutMs + 2000) : REQUEST_TIMEOUT });

    if (!startResp.ok) throw new Error(startResp.message || "Exec start failed");

    if (startResp.job_id && typeof onStart === "function") {
      try { onStart(startResp.job_id); } catch (_) {}
    }

    if (isSync) {
      const data = startResp.result || startResp.data || {};
      return {
        id: startResp.id, ok: true, mode: "sync",
        exitCode: data.exit_code, output: data.output, raw: startResp
      };
    }

    const jobId = startResp.job_id;
    const startTime = Date.now();

    while (true) {
      if (Date.now() - startTime > overallTimeoutMs) throw new Error(`Timeout ${overallTimeoutMs}ms`);
      await new Promise(r => setTimeout(r, pollInterval));

      const stResp = await sendIpcRequest({
        type: "exec",
        cmd: "exec",
        args: { job_id: jobId }
      }, { timeoutMs: REQUEST_TIMEOUT });

      if (!stResp.ok) throw new Error(stResp.message || "Status failed");

      if (stResp.result) {
        const { output, pid } = stResp.result;
        if (typeof onProgress === "function" && (output || pid)) {
          try { onProgress(output, jobId, pid); } catch (_) {}
        }
      }

      if (stResp.state === "done") {
        const data = stResp.result || {};
        return {
          id: stResp.id, ok: true, mode: "async", jobId,
          exitCode: data.exit_code, output: data.output, pid: data.pid,
          raw: stResp
        };
      }
    }
  });
}

function killJob(jobId) {
  if (!jobId) return Promise.reject(new Error("jobId required"));
  return sendIpcRequest(
    { type: "exec", cmd: "kill", args: { job_id: jobId } },
    { timeoutMs: REQUEST_TIMEOUT * 2 }
  ).then(resp => {
    if (!resp.ok) throw new Error(resp.message || "kill failed");
    return resp.data || resp;
  });
}

const suIpc = {
  exec: suExec,
  kill: killJob
};

function suExecCompat(cmd, options) {
  return suExec(cmd, options);
}
Object.assign(suExecCompat, suIpc);

export default suExecCompat;
export { suExec, killJob, DaemonUnavailableError };
