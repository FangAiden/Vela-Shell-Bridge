import file from "@system.file";

const BASE = "internal://files/";
const REQUEST_TIMEOUT = 1250;
const DAEMON_RETRY_INTERVAL = 5000;

let daemonState = "unknown";
let lastDaemonFailTime = 0;

// Must match Lua daemon config (src/lua/app/VelaShellBridge/app/lua/app/config.lua).
const IPC_SLOT_COUNT = 2;
const IPC_PENDING = "ipc_pending";

let pendingToken = 0;

const slotInUse = [];
for (let i = 0; i < IPC_SLOT_COUNT; i++) slotInUse[i] = false;
const slotWaiters = [];

export class DaemonUnavailableError extends Error {
  constructor(message) {
    super(message || "SU daemon is not available");
    this.name = "DaemonUnavailableError";
  }
}

function genRequestId() {
  return Date.now().toString() + "_" + Math.floor(Math.random() * 100000);
}

function clampInt(n, minv, maxv, fallback) {
  const v = Math.floor(Number(n));
  if (!isFinite(v)) return fallback;
  if (v < minv) return minv;
  if (v > maxv) return maxv;
  return v;
}

function safeDelete(uri) {
  if (!file.delete) return;
  try {
    file.delete({ uri });
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

let pollerRunning = false;
let pollTimer = null;
let pendingSize = 0;
const pending = {};

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
  return clampInt(min, 30, 2000, 100);
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

function markDaemonDown() {
  daemonState = "down";
  lastDaemonFailTime = Date.now();
}

export function sendIpcRequest(payload, options = {}) {
  const baseUri = options.baseUri || BASE;
  const pollInterval = clampInt(options.pollInterval, 30, 2000, 100);
  const timeoutMs = options.timeoutMs || REQUEST_TIMEOUT;

  if (daemonState === "down") {
    const now = Date.now();
    if (now - lastDaemonFailTime < DAEMON_RETRY_INTERVAL) {
      return Promise.reject(new DaemonUnavailableError("SU daemon is down (cached)"));
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
      markDaemonDown();

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
