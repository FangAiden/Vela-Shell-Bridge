// src/pages/su-ipc.js
import file from '@system.file';
import app from '@system.app';

const BASE = 'internal://files/';
const REQUEST_TIMEOUT = 1250;
const EXEC_OVERALL_TIMEOUT = 30000;
const STATUS_POLL_INTERVAL = 200;

let currentExecution = null;
let daemonState = 'unknown';
let lastDaemonFailTime = 0;
const DAEMON_RETRY_INTERVAL = 5000;

function genRequestId() {
  return Date.now().toString() + '_' + Math.floor(Math.random() * 100000);
}

class DaemonUnavailableError extends Error {
  constructor(message) {
    super(message || 'SU daemon is not available');
    this.name = 'DaemonUnavailableError';
  }
}

function sendIpcRequest(payload, options = {}) {
  const baseUri = options.baseUri || BASE;
  const pollInterval = options.pollInterval || 100;
  const timeoutMs = options.timeoutMs || REQUEST_TIMEOUT;

  if (daemonState === 'down') {
    const now = Date.now();
    if (now - lastDaemonFailTime < DAEMON_RETRY_INTERVAL) {
      return Promise.reject(new DaemonUnavailableError('SU daemon is down (cached)'));
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
      daemonState = 'down';
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
          try { obj = JSON.parse(data.text || '{}'); } catch (e) { setTimeout(pollResponse, pollInterval); return; }
          if (!obj || obj.id !== id) { setTimeout(pollResponse, pollInterval); return; }
          daemonState = 'up';
          safeSettle(() => {
            if (file.delete) try { file.delete({ uri: resUri }); } catch (_) {}
            resolve(obj);
          });
        },
        fail() { if (!settled) setTimeout(pollResponse, pollInterval); }
      });
    }

    file.writeText({
      uri: reqUri, text,
      success() { setTimeout(pollResponse, pollInterval); },
      fail(_d, code) { safeSettle(() => { reject(new Error(`Write failed: ${code}`)); }); }
    });
  });
}

function runExclusive(taskFn) {
  if (currentExecution) return Promise.reject(new Error('BUSY: Previous command running'));
  const p = Promise.resolve().then(taskFn);
  currentExecution = p;
  const unlock = () => { if (currentExecution === p) currentExecution = null; };
  return p.then(v => { unlock(); return v; }, e => { unlock(); throw e; });
}

// ---------------------------------------------------------
// 核心 suExec
// ---------------------------------------------------------
function suExec(shellCmd, options = {}) {
  if (!shellCmd || typeof shellCmd !== 'string') return Promise.reject(new Error('Cmd required'));

  const isSync = options.sync === true;
  const onProgress = options.onProgress;
  const onStart = options.onStart;
  const pollInterval = options.statusPollInterval || STATUS_POLL_INTERVAL;
  const overallTimeoutMs = options.timeoutMs || EXEC_OVERALL_TIMEOUT;

  return runExclusive(async () => {
    // 1. 发送 Start 请求
    let startResp;
    try {
      startResp = await sendIpcRequest({
        type: 'exec', cmd: 'exec',
        args: { shell: shellCmd, sync: isSync }
      }, { timeoutMs: isSync ? (overallTimeoutMs + 2000) : REQUEST_TIMEOUT });
    } catch (err) { throw err; }

    if (!startResp.ok) throw new Error(startResp.message || 'Exec start failed');

    // 2. 回调 JobID
    if (startResp.job_id && typeof onStart === 'function') {
      try { onStart(startResp.job_id); } catch (_) {}
    }

    // A. 同步直接返回
    if (isSync) {
      const data = startResp.result || startResp.data || {};
      return {
        id: startResp.id, ok: true, mode: 'sync',
        exitCode: data.exit_code, output: data.output, raw: startResp
      };
    }

    // B. 异步轮询
    const jobId = startResp.job_id;
    const startTime = Date.now();

    while (true) {
      if (Date.now() - startTime > overallTimeoutMs) throw new Error(`Timeout ${overallTimeoutMs}ms`);
      await new Promise(r => setTimeout(r, pollInterval));

      let stResp;
      try {
        stResp = await sendIpcRequest({
          type: 'exec', cmd: 'exec', args: { job_id: jobId }
        }, { timeoutMs: REQUEST_TIMEOUT });
      } catch (err) { throw err; }

      if (!stResp.ok) throw new Error(stResp.message || 'Status failed');

      // [新增] 传递 PID
      if (stResp.result) {
        const { output, pid } = stResp.result;
        if (typeof onProgress === 'function' && (output || pid)) {
          try { onProgress(output, jobId, pid); } catch (_) {}
        }
      }

      if (stResp.state === 'done') {
        const data = stResp.result || {};
        return {
          id: stResp.id, ok: true, mode: 'async', jobId,
          exitCode: data.exit_code, output: data.output, pid: data.pid,
          raw: stResp
        };
      }
    }
  });
}

function killJob(jobId) {
  if (!jobId) return Promise.reject(new Error('jobId required'));

  // 允许在 exec 轮询期间随时 kill：不要走 runExclusive，否则会被 BUSY 拦住
  return sendIpcRequest(
    { type: 'exec', cmd: 'kill', args: { job_id: jobId } },
    { timeoutMs: REQUEST_TIMEOUT * 2 }
  ).then(resp => {
    if (!resp.ok) throw new Error(resp.message || 'kill failed');
    return resp.data || resp;
  });
}

const suIpc = {
  exec: suExec,
  kill: killJob
};

// ---------------------------------------------------------
// Management：管理类命令（get_logs / clear_logs / policies ...）
// ---------------------------------------------------------
function management(cmd, args = {}, options = {}) {
  if (!cmd || typeof cmd !== 'string') return Promise.reject(new Error('cmd required'));
  return sendIpcRequest(
    { type: 'management', cmd, args: args || {} },
    { timeoutMs: options.timeoutMs || REQUEST_TIMEOUT }
  );
}

async function getLogs(options = {}) {
  const resp = await management('get_logs', {}, options);
  if (!resp || resp.ok !== true) throw new Error((resp && resp.message) || 'get_logs failed');
  return resp.data;
}

async function clearLogs(options = {}) {
  const resp = await management('clear_logs', {}, options);
  if (!resp || resp.ok !== true) throw new Error((resp && resp.message) || 'clear_logs failed');
  return resp.data;
}

async function getPolicies(options = {}) {
  const resp = await management("get_policies", {}, options);
  if (!resp || resp.ok !== true) throw new Error((resp && resp.message) || "get_policies failed");
  return resp.data || {};
}

async function setPolicy(appId, policy, options = {}) {
  if (!appId) throw new Error("appId required");
  if (!policy) throw new Error("policy required");
  const resp = await management("set_policy", { app_id: appId, policy }, options);
  if (!resp || resp.ok !== true) throw new Error((resp && resp.message) || "set_policy failed");
  return resp.data;
}

async function getAllowlist(options = {}) {
  const resp = await management("get_allowlist", {}, options);
  if (!resp || resp.ok !== true) throw new Error((resp && resp.message) || "get_allowlist failed");
  const data = resp.data || {};
  const list = data.allowlist;
  return Array.isArray(list) ? list : [];
}

async function setAllowlist(list, options = {}) {
  const resp = await management("set_allowlist", { allowlist: Array.isArray(list) ? list : [] }, options);
  if (!resp || resp.ok !== true) throw new Error((resp && resp.message) || "set_allowlist failed");
  return resp.data;
}

async function scanApps(options = {}) {
  const resp = await management("scan_apps", {}, options);
  if (!resp || resp.ok !== true) throw new Error((resp && resp.message) || "scan_apps failed");
  const data = resp.data || {};
  const apps = data.apps;
  return Array.isArray(apps) ? apps : [];
}

suIpc.management = management;
suIpc.getLogs = getLogs;
suIpc.clearLogs = clearLogs;
suIpc.getPolicies = getPolicies;
suIpc.setPolicy = setPolicy;
suIpc.getAllowlist = getAllowlist;
suIpc.setAllowlist = setAllowlist;
suIpc.scanApps = scanApps;

// 兼容两种用法：
// - import suExec from "../su-ipc"; suExec("ls")
// - import suIpc from "../su-ipc.js"; suIpc.exec("ls")
function suExecCompat(cmd, options) {
  return suExec(cmd, options);
}
Object.assign(suExecCompat, suIpc);

export default suExecCompat;
