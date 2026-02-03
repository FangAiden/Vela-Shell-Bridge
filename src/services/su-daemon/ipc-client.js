import file from "@system.file";

const BASE = "internal://files/";
const REQUEST_TIMEOUT = 1500;
const POLL_INTERVAL = 80;
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

// Request queue to ensure only one request at a time
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
      } catch (_) {
        // Response not ready yet
      }
    };

    // Write request and start polling
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

/**
 * Send IPC request using 2-file protocol:
 *   - Requests are queued to ensure only one at a time
 *   - Write request to ipc_in.json
 *   - Poll ipc_out.json for response
 */
export function sendIpcRequest(payload, options = {}) {
  return new Promise((resolve, reject) => {
    requestQueue.push({ payload, options, resolve, reject });
    processQueue();
  });
}
