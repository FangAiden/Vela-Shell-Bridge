import storage from "@system.storage";
import file from "@system.file";

const STORAGE_KEY = "vela_shell_bridge_local_settings_v1";
const FALLBACK_FILE_URI = "internal://files/local_settings_v1.json";
const NOOP = () => {};

const G = (() => {
  try {
    if (typeof globalThis !== "undefined") return globalThis;
  } catch (_) {}
  try {
    if (typeof global !== "undefined") return global;
  } catch (_) {}
  return {};
})();

const DEFAULTS = {
  v: 1,
  ui: {
    enableTransitions: true,
  },
  remote: {
    enabled: false,
    token: "",
  },
  shell: {
    execMode: "async", // "sync" | "async"
  },
  ime: {
    keyboardType: "QWERTY",
    vibrateMode: "short",
    screenType: "auto",
    maxLength: 5,
  },
};

function syncGlobal(next) {
  try {
    G.__VSB_LOCAL_SETTINGS__ = next;
  } catch (_) {}
}

if (!G.__VSB_LOCAL_SETTINGS__) {
  syncGlobal(JSON.parse(JSON.stringify(DEFAULTS)));
}

function clampInt(n, min, max, fallback) {
  const v = Math.floor(Number(n));
  if (!isFinite(v)) return fallback;
  if (v < min) return min;
  if (v > max) return max;
  return v;
}

function normalize(raw) {
  const out = JSON.parse(JSON.stringify(DEFAULTS));
  if (!raw || typeof raw !== "object") return out;

  if (raw.ui && typeof raw.ui === "object") {
    if (typeof raw.ui.enableTransitions === "boolean") {
      out.ui.enableTransitions = raw.ui.enableTransitions;
    }
  }

  if (raw.remote && typeof raw.remote === "object") {
    if (typeof raw.remote.enabled === "boolean") out.remote.enabled = raw.remote.enabled;
    if (typeof raw.remote.token === "string") out.remote.token = raw.remote.token.trim().slice(0, 32);
  }

  if (raw.shell && typeof raw.shell === "object") {
    const em = raw.shell.execMode;
    if (em === "sync" || em === "async") out.shell.execMode = em;
  }

  if (raw.ime && typeof raw.ime === "object") {
    const kt = raw.ime.keyboardType;
    const vm = raw.ime.vibrateMode;
    const st = raw.ime.screenType;
    const ml = raw.ime.maxLength;
    if (kt === "QWERTY" || kt === "T9") out.ime.keyboardType = kt;
    if (vm === "" || vm === "short" || vm === "long") out.ime.vibrateMode = vm;
    if (st === "auto" || st === "circle" || st === "rect" || st === "pill-shaped") out.ime.screenType = st;
    if (ml != null) out.ime.maxLength = clampInt(ml, 1, 9, out.ime.maxLength);
  }
  if (out.ime.screenType === "pill-shaped" && out.ime.keyboardType === "T9") {
    out.ime.keyboardType = "QWERTY";
  }

  return out;
}

function storageGetRaw(key, timeoutMs) {
  return new Promise((resolve) => {
    let done = false;
    const t = setTimeout(() => {
      if (done) return;
      done = true;
      resolve(null);
    }, timeoutMs || 800);

    try {
      storage.get({
        key,
        success: (data) => {
          if (done) return;
          done = true;
          clearTimeout(t);
          if (data && data.value != null) resolve(data.value);
          else resolve(data);
        },
        fail: () => {
          if (done) return;
          done = true;
          clearTimeout(t);
          resolve(null);
        },
      });
    } catch (_) {
      if (done) return;
      done = true;
      clearTimeout(t);
      resolve(null);
    }
  });
}

function storageSetRaw(key, value, timeoutMs) {
  return new Promise((resolve) => {
    let done = false;
    const t = setTimeout(() => {
      if (done) return;
      done = true;
      resolve({ ok: false, reason: "timeout", code: 0, message: "" });
    }, timeoutMs || 800);

    try {
      storage.set({
        key,
        value,
        success: () => {
          if (done) return;
          done = true;
          clearTimeout(t);
          resolve({ ok: true, reason: "", code: 0, message: "" });
        },
        fail: (data, code) => {
          if (done) return;
          done = true;
          clearTimeout(t);
          const msg =
            (data && typeof data === "object" && data.message) ||
            (typeof data === "string" ? data : "");
          resolve({
            ok: false,
            reason: "fail",
            code: code || 0,
            message: String(msg || ""),
          });
        },
      });
    } catch (_) {
      if (done) return;
      done = true;
      clearTimeout(t);
      resolve({ ok: false, reason: "throw", code: 0, message: "" });
    }
  });
}

function fileGetRaw(uri, timeoutMs) {
  return new Promise((resolve) => {
    let done = false;
    const t = setTimeout(() => {
      if (done) return;
      done = true;
      resolve(null);
    }, timeoutMs || 1200);

    try {
      file.readText({
        uri,
        success: (data) => {
          if (done) return;
          done = true;
          clearTimeout(t);
          if (data && data.text != null) resolve(String(data.text));
          else resolve(null);
        },
        fail: () => {
          if (done) return;
          done = true;
          clearTimeout(t);
          resolve(null);
        },
        complete: NOOP,
      });
    } catch (_) {
      if (done) return;
      done = true;
      clearTimeout(t);
      resolve(null);
    }
  });
}

function fileSetRaw(uri, text, timeoutMs) {
  return new Promise((resolve) => {
    let done = false;
    const t = setTimeout(() => {
      if (done) return;
      done = true;
      resolve({ ok: false, reason: "file_timeout", code: 0, message: "" });
    }, timeoutMs || 1800);

    try {
      file.writeText({
        uri,
        text: String(text == null ? "" : text),
        success: () => {
          if (done) return;
          done = true;
          clearTimeout(t);
          resolve({ ok: true, reason: "", code: 0, message: "" });
        },
        fail: (data, code) => {
          if (done) return;
          done = true;
          clearTimeout(t);
          const msg =
            (data && typeof data === "object" && data.message) ||
            (typeof data === "string" ? data : "");
          resolve({
            ok: false,
            reason: "file_fail",
            code: code || 0,
            message: String(msg || ""),
          });
        },
        complete: NOOP,
      });
    } catch (_) {
      if (done) return;
      done = true;
      clearTimeout(t);
      resolve({ ok: false, reason: "file_throw", code: 0, message: "" });
    }
  });
}

function parseRawSettings(raw) {
  if (raw == null) return null;
  if (typeof raw === "string") {
    const text = raw.trim();
    if (!text) return null;
    try {
      return JSON.parse(text);
    } catch (_) {
      return null;
    }
  }
  if (typeof raw === "object") return raw;
  return null;
}

let cache = null;
let inflight = null;
let writeChain = Promise.resolve();

function waitMs(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function runWriteExclusive(task) {
  const next = writeChain.then(task, task);
  writeChain = next.catch(() => {});
  return next;
}

async function persistLocalSettings(value) {
  const plan = [
    { timeout: 1200, wait: 80 },
    { timeout: 1800, wait: 140 },
    { timeout: 2600, wait: 0 },
  ];
  let last = { ok: false, reason: "unknown", code: 0, message: "" };
  for (let i = 0; i < plan.length; i++) {
    const step = plan[i];
    const ret = await storageSetRaw(STORAGE_KEY, value, step.timeout);
    if (ret && ret.ok) return ret;
    last = ret || last;
    if (step.wait > 0 && i < plan.length - 1) {
      await waitMs(step.wait);
    }
  }
  const fb = await fileSetRaw(FALLBACK_FILE_URI, value, 2200);
  if (fb && fb.ok) {
    return fb;
  }
  return fb || last;
}

export function getCachedLocalSettings() {
  return cache || G.__VSB_LOCAL_SETTINGS__ || null;
}

export function getCachedTransitionsEnabled() {
  const local = getCachedLocalSettings();
  if (!local || !local.ui) return true;
  return local.ui.enableTransitions !== false;
}

export async function getLocalSettings(options = {}) {
  if (!options.force && cache) return cache;
  if (inflight) return inflight;

  inflight = (async () => {
    const raw = await storageGetRaw(STORAGE_KEY);
    let obj = parseRawSettings(raw);

    if (!obj) {
      const fbRaw = await fileGetRaw(FALLBACK_FILE_URI, 1500);
      obj = parseRawSettings(fbRaw);
      if (obj) {
        storageSetRaw(STORAGE_KEY, JSON.stringify(normalize(obj)), 1200).catch(() => {});
      }
    }

    cache = normalize(obj);
    syncGlobal(cache);
    inflight = null;
    return cache;
  })();

  return inflight;
}

function applyPatch(current, patch) {
  const next = normalize(current);
  if (!patch || typeof patch !== "object") return next;

  if (patch.ui && typeof patch.ui === "object") {
    if (typeof patch.ui.enableTransitions === "boolean") {
      next.ui.enableTransitions = patch.ui.enableTransitions;
    }
  }

  if (patch.remote && typeof patch.remote === "object") {
    if (typeof patch.remote.enabled === "boolean") next.remote.enabled = patch.remote.enabled;
    if (typeof patch.remote.token === "string") next.remote.token = patch.remote.token.trim().slice(0, 32);
  }

  if (patch.shell && typeof patch.shell === "object") {
    const em = patch.shell.execMode;
    if (em === "sync" || em === "async") next.shell.execMode = em;
  }

  if (patch.ime && typeof patch.ime === "object") {
    if (patch.ime.keyboardType === "QWERTY" || patch.ime.keyboardType === "T9") {
      next.ime.keyboardType = patch.ime.keyboardType;
    }
    if (patch.ime.vibrateMode === "" || patch.ime.vibrateMode === "short" || patch.ime.vibrateMode === "long") {
      next.ime.vibrateMode = patch.ime.vibrateMode;
    }
    if (patch.ime.screenType === "auto" || patch.ime.screenType === "circle" || patch.ime.screenType === "rect" || patch.ime.screenType === "pill-shaped") {
      next.ime.screenType = patch.ime.screenType;
    }
    if (patch.ime.maxLength != null) {
      next.ime.maxLength = clampInt(patch.ime.maxLength, 1, 9, next.ime.maxLength);
    }
  }
  if (next.ime.screenType === "pill-shaped" && next.ime.keyboardType === "T9") {
    next.ime.keyboardType = "QWERTY";
  }

  return next;
}

export async function updateLocalSettings(patch) {
  return runWriteExclusive(async () => {
    const current = await getLocalSettings();
    const next = applyPatch(current, patch);
    const persisted = await persistLocalSettings(JSON.stringify(next));
    if (!persisted || !persisted.ok) {
      const reason = persisted && persisted.reason ? persisted.reason : "unknown";
      const code = persisted && persisted.code ? `:${persisted.code}` : "";
      throw new Error(`persist local settings failed (${reason}${code})`);
    }
    cache = next;
    syncGlobal(cache);
    return next;
  });
}

export async function setUiTransitionsEnabled(enabled) {
  return updateLocalSettings({ ui: { enableTransitions: !!enabled } });
}

export async function setRemoteEnabled(enabled) {
  return updateLocalSettings({ remote: { enabled: !!enabled } });
}

export async function setRemoteToken(token) {
  return updateLocalSettings({ remote: { token: String(token == null ? "" : token) } });
}

export function getLocalDefaults() {
  return JSON.parse(JSON.stringify(DEFAULTS));
}
