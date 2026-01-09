import file from "@system.file";

const BASE = "internal://files/";
const REQUEST_TIMEOUT = 1250;
const DAEMON_RETRY_INTERVAL = 5000;

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

export function sendIpcRequest(payload, options = {}) {
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
