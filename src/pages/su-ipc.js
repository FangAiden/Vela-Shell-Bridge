// su-ipc.js  (QuickApp 通用 SU IPC 模块：AppA/AppB 都可以用)
// - exec: suExec(shellCmd, options)
// - management: suExec.management.{getPolicies,setPolicy,getLogs,clearLogs,setAllowlist}
// - 带守护存活检测：Lua 端未启动时快速返回 SU_DAEMON_UNAVAILABLE

import file from '@system.file';
import app from '@system.app' 

const BASE = 'internal://files/';

// 单次 IPC 请求等待超时（用来判断守护是否在线）
const REQUEST_TIMEOUT = 1250;

// 整个 suExec 允许的最长等待时间（包含 job 轮询）
const EXEC_OVERALL_TIMEOUT = 30000;

// 轮询 job 状态的间隔
const STATUS_POLL_INTERVAL = 200;

// 全局串行锁
let currentExecution = null;

let SandboxPath = `/data/files/`;
let QuickAppPath = `/data/app/`;
let packageName = getPackageName();

// 守护状态机
let daemonState = 'unknown';   // 'unknown' | 'up' | 'down'
let lastDaemonFailTime = 0;
// 守护判定为 down 后，这段时间内直接失败，不再尝试写文件 / 轮询
const DAEMON_RETRY_INTERVAL = 5000; // ms

function getPackageName() {
  return app.getInfo().packageName;
}

function genRequestId() {
  return Date.now().toString() + '_' + Math.floor(Math.random() * 100000);
}

/**
 * 守护不可用错误类型
 */
class DaemonUnavailableError extends Error {
  constructor(message) {
    super(message || 'SU daemon is not available');
    this.name = 'DaemonUnavailableError';
    this.code = 'SU_DAEMON_UNAVAILABLE';
  }
}

/**
 * 底层：发送一次 IPC 请求并得到原始响应 JSON
 * payload: { id?, type, cmd, args? }
 */
function sendIpcRequest(payload, options = {}) {
  const baseUri = options.baseUri || BASE;
  const pollInterval = options.pollInterval || 100;
  const timeoutMs = options.timeoutMs || REQUEST_TIMEOUT;

  // ① 守护状态预检查：down & 冷却期内 -> 直接失败
  if (daemonState === 'down') {
    const now = Date.now();
    if (now - lastDaemonFailTime < DAEMON_RETRY_INTERVAL) {
      return Promise.reject(new DaemonUnavailableError('SU daemon is down (cached)'));
    }
    // 冷却期过了，允许再试一次
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

      // ② 请求在 timeoutMs 内没拿到 response -> 判定守护 down
      daemonState = 'down';
      lastDaemonFailTime = Date.now();

      reject(new DaemonUnavailableError(`SU IPC timeout after ${timeoutMs} ms (id=${id})`));
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

          let rawText = data.text;
          let obj;
          try {
            obj = JSON.parse(rawText || '{}');
          } catch (e) {
            setTimeout(pollResponse, pollInterval);
            return;
          }

          if (!obj || obj.id !== id) {
            setTimeout(pollResponse, pollInterval);
            return;
          }

          // ③ 收到任何响应 -> 守护在线
          daemonState = 'up';

          safeSettle(() => {
            if (file.delete) {
              try { file.delete({ uri: resUri }); } catch (_) {}
            }
            resolve(obj);
          });
        },
        fail(_data, _code) {
          if (!settled) {
            setTimeout(pollResponse, pollInterval);
          }
        }
      });
    }

    file.writeText({
      uri: reqUri,
      text,
      success() {
        setTimeout(pollResponse, pollInterval);
      },
      fail(_data, code) {
        safeSettle(() => {
          reject(new Error(`SU IPC writeText failed: ${code}`));
        });
      }
    });
  });
}

/**
 * 串行化执行：同一时间只允许一个 SU 流程在飞
 */
function runExclusive(taskFn) {
  if (currentExecution) {
    return Promise.reject(new Error('SU is busy: previous command is still running'));
  }

  const p = Promise.resolve().then(taskFn);
  currentExecution = p;

  const unlock = () => {
    if (currentExecution === p) {
      currentExecution = null;
    }
  };

  return p.then(
    (v) => {
      unlock();
      return v;
    },
    (err) => {
      unlock();
      throw err;
    }
  );
}

/**
 * 通用 exec：对外仍是“一次 await”，内部是 start + status 两步
 *
 * - 如果 Lua 守护没启动：
 *   - 第一条请求 ~REQUEST_TIMEOUT 内判定为 DaemonUnavailableError
 *   - 后续 DAEMON_RETRY_INTERVAL 内再次调用，立即抛同样错误（不写文件）
 */
function suExec(shellCmd, options = {}) {
  if (!shellCmd || typeof shellCmd !== 'string') {
    return Promise.reject(new Error('shellCmd must be a non-empty string'));
  }

  const pollInterval = options.statusPollInterval || STATUS_POLL_INTERVAL;
  const overallTimeoutMs = options.timeoutMs || EXEC_OVERALL_TIMEOUT;

  return runExclusive(async () => {
    const startTime = Date.now();

    // 1) start job（type=exec, cmd=exec, args.shell）
    let startResp;
    try {
      startResp = await sendIpcRequest({
        type: 'exec',
        cmd: 'exec',
        args: { shell: shellCmd }
      }, { timeoutMs: REQUEST_TIMEOUT });
    } catch (err) {
      // 守护不可用错误直接透传
      throw err;
    }

    if (!startResp.ok) {
      const msg = startResp.message || (startResp.error && startResp.error.message) || 'SU exec start failed';
      const err = new Error(msg);
      err.raw = startResp;
      throw err;
    }

    const jobId = startResp.job_id;
    if (!jobId) {
      const err = new Error('SU exec start: missing job_id');
      err.raw = startResp;
      throw err;
    }

    // 2) poll status（type=exec, args.job_id）
    while (true) {
      if (Date.now() - startTime > overallTimeoutMs) {
        throw new Error(`SU exec overall timeout after ${overallTimeoutMs} ms`);
      }

      await new Promise(r => setTimeout(r, pollInterval));

      let stResp;
      try {
        stResp = await sendIpcRequest({
          type: 'exec',
          cmd: 'exec',
          args: { job_id: jobId }
        }, { timeoutMs: REQUEST_TIMEOUT });
      } catch (err) {
        // 守护中途挂掉 -> 抛出 DaemonUnavailableError
        throw err;
      }

      if (!stResp.ok) {
        const msg = stResp.message || (stResp.error && stResp.error.message) || 'SU exec status failed';
        const err = new Error(msg);
        err.raw = stResp;
        throw err;
      }

      if (stResp.state === 'running') {
        continue;
      }

      if (stResp.state === 'done') {
        const data = stResp.result || {};
        return {
          id: stResp.id,
          ok: true,
          jobId,
          exitCode: data.exit_code,
          status: data.status,
          success: data.success,
          output: data.output,
          raw: stResp
        };
      }

      const err = new Error(`Unknown job state: ${stResp.state}`);
      err.raw = stResp;
      throw err;
    }
  });
}

/**
 * 管理端 API（AppA 使用）
 * - 这些接口同样走 sendIpcRequest，因此也有守护存活检测
 */
const management = {
  getPolicies(options = {}) {
    return runExclusive(async () => {
      const resp = await sendIpcRequest({
        type: 'management',
        cmd: 'get_policies',
        args: {}
      }, options);

      if (!resp.ok) {
        const err = new Error(resp.message || 'getPolicies failed');
        err.raw = resp;
        throw err;
      }
      return resp.data;
    });
  },

  setPolicy(appId, policy, options = {}) {
    return runExclusive(async () => {
      const resp = await sendIpcRequest({
        type: 'management',
        cmd: 'set_policy',
        args: { app_id: appId, policy }
      }, options);

      if (!resp.ok) {
        const err = new Error(resp.message || 'setPolicy failed');
        err.raw = resp;
        throw err;
      }
      return resp.data;
    });
  },

  getLogs(options = {}) {
    return runExclusive(async () => {
      const resp = await sendIpcRequest({
        type: 'management',
        cmd: 'get_logs',
        args: {}
      }, options);

      if (!resp.ok) {
        const err = new Error(resp.message || 'getLogs failed');
        err.raw = resp;
        throw err;
      }
      return resp.data;
    });
  },

  clearLogs(options = {}) {
    return runExclusive(async () => {
      const resp = await sendIpcRequest({
        type: 'management',
        cmd: 'clear_logs',
        args: {}
      }, options);

      if (!resp.ok) {
        const err = new Error(resp.message || 'clearLogs failed');
        err.raw = resp;
        throw err;
      }
      return resp.data;
    });
  },

  setAllowlist(list, options = {}) {
    return runExclusive(async () => {
      const resp = await sendIpcRequest({
        type: 'management',
        cmd: 'set_allowlist',
        args: { allowlist: list }
      }, options);

      if (!resp.ok) {
        const err = new Error(resp.message || 'setAllowlist failed');
        err.raw = resp;
        throw err;
      }
      return resp.data;
    });
  }
};

// 挂在主函数上，方便统一引用
suExec.exec = suExec;
suExec.management = management;
suExec.getSandboxPath = function () {
  return SandboxPath;
};
suExec.getQuickAppPath = function () {
  return QuickAppPath;
};
suExec.getPackageName = function () {
  return packageName;
};

// 提供一个调试用的获取守护状态的函数
suExec.getDaemonState = function () {
  return {
    state: daemonState,
    lastFailTime: lastDaemonFailTime
  };
};

export default suExec;
