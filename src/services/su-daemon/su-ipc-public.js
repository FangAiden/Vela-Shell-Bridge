/**
 * VelaShellBridge - 第三方 QuickApp 使用的 Shell 执行客户端
 */

import file from "@system.file";

// ============== IPC Client ==============

const BASE = "internal://files/";
const REQUEST_TIMEOUT = 1500;
const POLL_INTERVAL = 80;
const MAX_QUEUE_LENGTH = 50;
const NOOP = () => {};

export class DaemonUnavailableError extends Error {
  constructor(message) {
    super(message || "SU daemon is not available");
    this.name = "DaemonUnavailableError";
  }
}

function genRequestId() {
  return Date.now().toString() + "_" + Math.floor(Math.random() * 100000);
}

function writeText(uri, text) {
  return new Promise((resolve, reject) => {
    file.writeText({
      uri,
      text: text == null ? "" : String(text),
      success: resolve,
      fail: (_d, code) => reject(new Error(`Write failed: ${code}`)),
      complete: NOOP,
    });
  });
}

function readText(uri) {
  return new Promise((resolve, reject) => {
    file.readText({
      uri,
      success: (data) => resolve((data && data.text) || ""),
      fail: (_d, code) => reject(new Error(`Read failed: ${code}`)),
      complete: NOOP,
    });
  });
}

function deleteFile(uri) {
  return new Promise((resolve) => {
    if (!file.delete) {
      resolve();
      return;
    }
    file.delete({ uri, success: resolve, fail: resolve, complete: NOOP });
  });
}

// Request queue
let currentRequest = null;
const requestQueue = [];

function processQueue() {
  if (currentRequest || requestQueue.length === 0) return;

  const { payload, options, resolve, reject } = requestQueue.shift();
  currentRequest = doSendRequest(payload, options)
    .then((result) => {
      currentRequest = null;
      resolve(result);
      processQueue();
    })
    .catch((err) => {
      currentRequest = null;
      reject(err);
      processQueue();
    });
}

function doSendRequest(payload, options) {
  const baseUri = options.baseUri || BASE;
  const timeoutMs = options.timeoutMs || REQUEST_TIMEOUT;

  const id = payload.id || genRequestId();
  payload.id = id;

  const inUri = `${baseUri}ipc_in.json`;
  const outUri = `${baseUri}ipc_out.json`;
  const text = JSON.stringify(payload);

  return new Promise((resolve, reject) => {
    let settled = false;
    let pollTimer = null;

    const timeoutId = setTimeout(() => {
      if (settled) return;
      settled = true;
      if (pollTimer) clearInterval(pollTimer);
      deleteFile(inUri).catch(NOOP);
      reject(new DaemonUnavailableError(`Timeout ${timeoutMs}ms (id=${id})`));
    }, timeoutMs);

    const checkResponse = async () => {
      if (settled) return;

      try {
        const txt = await readText(outUri);
        const obj = JSON.parse(txt || "{}");

        if (obj && obj.id === id) {
          settled = true;
          clearTimeout(timeoutId);
          if (pollTimer) clearInterval(pollTimer);
          deleteFile(outUri).catch(NOOP);
          resolve(obj);
        }
      } catch (_) {}
    };

    writeText(inUri, text)
      .then(() => {
        if (settled) return;
        pollTimer = setInterval(checkResponse, POLL_INTERVAL);
        checkResponse();
      })
      .catch((e) => {
        if (settled) return;
        settled = true;
        clearTimeout(timeoutId);
        reject(e);
      });
  });
}

function sendIpcRequest(payload, options = {}) {
  return new Promise((resolve, reject) => {
    if (requestQueue.length >= MAX_QUEUE_LENGTH) {
      reject(new DaemonUnavailableError(`Request queue full (max=${MAX_QUEUE_LENGTH})`));
      return;
    }
    requestQueue.push({ payload, options, resolve, reject });
    processQueue();
  });
}

// ============== Exec Client ==============

const EXEC_TIMEOUT = 30000;
const STATUS_POLL_INTERVAL = 200;

let busy = false;

async function exec(shellCmd, options = {}) {
  if (!shellCmd || typeof shellCmd !== "string") {
    throw new Error("Cmd required");
  }

  const isSync = options.sync === true;

  // For async mode without wait, don't block
  if (!isSync && options.wait === false) {
    return doExecStart(shellCmd, false);
  }

  if (busy) {
    throw new Error("BUSY: Previous command running");
  }

  busy = true;
  try {
    return await doExec(shellCmd, options);
  } finally {
    busy = false;
  }
}

async function doExecStart(shellCmd, isSync) {
  const startResp = await sendIpcRequest(
    {
      type: "exec",
      cmd: "exec",
      args: { shell: shellCmd, sync: isSync },
    },
    { timeoutMs: REQUEST_TIMEOUT }
  );

  if (!startResp.ok) {
    throw new Error(startResp.message || "Exec start failed");
  }

  return {
    ok: true,
    jobId: startResp.job_id,
    state: startResp.state,
    raw: startResp,
  };
}

async function doExec(shellCmd, options) {
  const isSync = options.sync === true;
  const onProgress = options.onProgress;
  const onStart = options.onStart;
  const overallTimeoutMs = options.timeoutMs || EXEC_TIMEOUT;
  const pollInterval = options.statusPollInterval || STATUS_POLL_INTERVAL;

  const startResp = await sendIpcRequest(
    {
      type: "exec",
      cmd: "exec",
      args: { shell: shellCmd, sync: isSync },
    },
    { timeoutMs: isSync ? overallTimeoutMs + 2000 : REQUEST_TIMEOUT }
  );

  if (!startResp.ok) {
    throw new Error(startResp.message || "Exec start failed");
  }

  if (startResp.job_id && typeof onStart === "function") {
    try {
      onStart(startResp.job_id);
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
  const startTime = Date.now();

  while (true) {
    if (Date.now() - startTime > overallTimeoutMs) {
      throw new Error(`Timeout ${overallTimeoutMs}ms`);
    }

    await new Promise((r) => setTimeout(r, pollInterval));

    const stResp = await sendIpcRequest(
      {
        type: "exec",
        cmd: "exec",
        args: { job_id: jobId },
      },
      { timeoutMs: REQUEST_TIMEOUT }
    );

    if (!stResp.ok) {
      throw new Error(stResp.message || "Status failed");
    }

    if (stResp.result && typeof onProgress === "function") {
      const { output, pid } = stResp.result;
      if (output || pid) {
        try {
          onProgress(output, jobId, pid);
        } catch (_) {}
      }
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

async function poll(jobId, options = {}) {
  if (!jobId) throw new Error("jobId required");

  const resp = await sendIpcRequest(
    {
      type: "exec",
      cmd: "exec",
      args: { job_id: jobId },
    },
    { timeoutMs: options.timeoutMs || REQUEST_TIMEOUT }
  );

  if (!resp.ok) {
    throw new Error(resp.message || "Poll failed");
  }

  const data = resp.result || {};
  return {
    ok: true,
    jobId,
    state: resp.state,
    output: data.output || "",
    exitCode: data.exit_code,
    pid: data.pid,
    raw: resp,
  };
}

function kill(jobId) {
  if (!jobId) return Promise.reject(new Error("jobId required"));
  return sendIpcRequest(
    { type: "exec", cmd: "kill", args: { job_id: jobId } },
    { timeoutMs: REQUEST_TIMEOUT * 2 }
  ).then((resp) => {
    if (!resp.ok) throw new Error(resp.message || "kill failed");
    return resp.data || resp;
  });
}

// ============== Export ==============

const suIpc = { exec, poll, kill };

function suExecCompat(cmd, options) {
  return exec(cmd, options);
}

Object.assign(suExecCompat, suIpc);

export default suExecCompat;
