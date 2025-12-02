// su-ipc.js  (QuickApp 通用 SU IPC 模块)
// 功能全集：
// 1. suExec(cmd): 默认异步执行
// 2. suExec(cmd, { sync: true }): 同步阻塞执行
// 3. suExec(cmd, { onStart: (id)=>{} }): [新增] 获取任务ID，用于 Kill
// 4. suExec(cmd, { onProgress: (log, id)=>{} }): 实时输出
// 5. suExec.kill(jobId): 主动杀死任务

import file from '@system.file';
import app from '@system.app';

const BASE = 'internal://files/';
const REQUEST_TIMEOUT = 1250;
const EXEC_OVERALL_TIMEOUT = 30000;
const STATUS_POLL_INTERVAL = 200;

let currentExecution = null;
let SandboxPath = `/data/files/`;
let QuickAppPath = `/data/app/`;
let packageName = getPackageName();

let daemonState = 'unknown';
let lastDaemonFailTime = 0;
const DAEMON_RETRY_INTERVAL = 5000;

function getPackageName() {
  return app.getInfo().packageName;
}

function genRequestId() {
  return Date.now().toString() + '_' + Math.floor(Math.random() * 100000);
}

class DaemonUnavailableError extends Error {
  constructor(message) {
    super(message || 'SU daemon is not available');
    this.name = 'DaemonUnavailableError';
    this.code = 'SU_DAEMON_UNAVAILABLE';
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
      reject(new DaemonUnavailableError(`SU IPC timeout after ${timeoutMs} ms (id=${id})`));
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
      uri: reqUri,
      text,
      success() { setTimeout(pollResponse, pollInterval); },
      fail(_data, code) { safeSettle(() => { reject(new Error(`SU IPC writeText failed: ${code}`)); }); }
    });
  });
}

function runExclusive(taskFn) {
  if (currentExecution) {
    return Promise.reject(new Error('SU is busy: previous command is still running'));
  }
  const p = Promise.resolve().then(taskFn);
  currentExecution = p;
  const unlock = () => { if (currentExecution === p) currentExecution = null; };
  return p.then(v => { unlock(); return v; }, e => { unlock(); throw e; });
}

function suExec(shellCmd, options = {}) {
  if (!shellCmd || typeof shellCmd !== 'string') {
    return Promise.reject(new Error('shellCmd must be a non-empty string'));
  }

  const isSync = options.sync === true;
  const onProgress = options.onProgress;
  const onStart = options.onStart; // [新增]
  const pollInterval = options.statusPollInterval || STATUS_POLL_INTERVAL;
  const overallTimeoutMs = options.timeoutMs || EXEC_OVERALL_TIMEOUT;

  return runExclusive(async () => {
    let startResp;
    try {
      startResp = await sendIpcRequest({
        type: 'exec', cmd: 'exec',
        args: { shell: shellCmd, sync: isSync }
      }, { 
        timeoutMs: isSync ? (overallTimeoutMs + 2000) : REQUEST_TIMEOUT 
      });
    } catch (err) { throw err; }

    if (!startResp.ok) {
      const err = new Error(startResp.message || 'SU exec start failed');
      err.raw = startResp;
      throw err;
    }

    // [新增] 启动成功，立即回调 jobId
    if (startResp.job_id && typeof onStart === 'function') {
        try { onStart(startResp.job_id); } catch (_) {}
    }

    if (isSync) {
      const data = startResp.result || startResp.data || {};
      return {
        id: startResp.id, ok: true, mode: 'sync',
        exitCode: data.exit_code, status: data.status,
        success: data.success, output: data.output, raw: startResp
      };
    }

    const jobId = startResp.job_id;
    if (!jobId) throw new Error('SU exec start: missing job_id');

    const startTime = Date.now();
    while (true) {
      if (Date.now() - startTime > overallTimeoutMs) {
        throw new Error(`SU exec overall timeout after ${overallTimeoutMs} ms`);
      }
      await new Promise(r => setTimeout(r, pollInterval));

      let stResp;
      try {
        stResp = await sendIpcRequest({
          type: 'exec', cmd: 'exec', args: { job_id: jobId }
        }, { timeoutMs: REQUEST_TIMEOUT });
      } catch (err) { throw err; }

      if (!stResp.ok) throw new Error(stResp.message || 'SU exec status failed');

      if (stResp.result && stResp.result.output && typeof onProgress === 'function') {
          try { onProgress(stResp.result.output, jobId); } catch (_) {}
      }

      if (stResp.state === 'done') {
        const data = stResp.result || {};
        return {
          id: stResp.id, ok: true, mode: 'async', jobId,
          exitCode: data.exit_code, status: data.status,
          success: data.success, output: data.output, raw: stResp
        };
      }
    }
  });
}

function killJob(jobId) {
  return runExclusive(async () => {
    const resp = await sendIpcRequest({
      type: 'exec', cmd: 'kill', args: { job_id: jobId }
    });
    if (!resp.ok) throw new Error(resp.message || 'kill failed');
    return resp.data || resp;
  });
}

const management = {
  getPolicies: (opts) => wrapMgmt('get_policies', {}, opts),
  setPolicy: (appId, pol, opts) => wrapMgmt('set_policy', { app_id: appId, policy: pol }, opts),
  getLogs: (opts) => wrapMgmt('get_logs', {}, opts),
  clearLogs: (opts) => wrapMgmt('clear_logs', {}, opts),
  setAllowlist: (list, opts) => wrapMgmt('set_allowlist', { allowlist: list }, opts)
};

function wrapMgmt(cmd, args, options) {
  return runExclusive(async () => {
    const resp = await sendIpcRequest({ type: 'management', cmd, args }, options);
    if (!resp.ok) throw new Error(resp.message || cmd + ' failed');
    return resp.data;
  });
}

suExec.exec = suExec;
suExec.kill = killJob;
suExec.management = management;
suExec.getSandboxPath = () => SandboxPath;
suExec.getQuickAppPath = () => QuickAppPath;
suExec.getPackageName = () => packageName;

export default suExec;