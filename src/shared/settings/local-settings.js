import storage from "@system.storage";

const STORAGE_KEY = "vela_shell_bridge_local_settings_v1";

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
  ipc: {
    jsPollIntervalMs: 200,
  },
  about: {
    developerName: "",
    developerContact: "",
    updateUrl: "",
  },
  ime: {
    keyboardType: "QWERTY",
    vibrateMode: "short",
    screenType: "circle",
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

  if (raw.ipc && typeof raw.ipc === "object") {
    if (raw.ipc.jsPollIntervalMs != null) {
      out.ipc.jsPollIntervalMs = clampInt(raw.ipc.jsPollIntervalMs, 50, 2000, out.ipc.jsPollIntervalMs);
    }
  }

  if (raw.about && typeof raw.about === "object") {
    const dn = raw.about.developerName;
    const dc = raw.about.developerContact;
    const url = raw.about.updateUrl;
    if (typeof dn === "string") out.about.developerName = dn.trim().slice(0, 80);
    if (typeof dc === "string") out.about.developerContact = dc.trim().slice(0, 120);
    if (typeof url === "string") out.about.updateUrl = url.trim().slice(0, 200);
  }

  if (raw.ime && typeof raw.ime === "object") {
    const kt = raw.ime.keyboardType;
    const vm = raw.ime.vibrateMode;
    const st = raw.ime.screenType;
    const ml = raw.ime.maxLength;
    if (kt === "QWERTY" || kt === "T9") out.ime.keyboardType = kt;
    if (vm === "" || vm === "short" || vm === "long") out.ime.vibrateMode = vm;
    if (st === "circle" || st === "rect" || st === "pill-shaped") out.ime.screenType = st;
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
      resolve(false);
    }, timeoutMs || 800);

    try {
      storage.set({
        key,
        value,
        success: () => {
          if (done) return;
          done = true;
          clearTimeout(t);
          resolve(true);
        },
        fail: () => {
          if (done) return;
          done = true;
          clearTimeout(t);
          resolve(false);
        },
      });
    } catch (_) {
      if (done) return;
      done = true;
      clearTimeout(t);
      resolve(false);
    }
  });
}

let cache = null;
let inflight = null;

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
    let obj = null;
    if (raw && typeof raw === "string") {
      try {
        obj = JSON.parse(raw);
      } catch (_) {
        obj = null;
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

  if (patch.ipc && typeof patch.ipc === "object") {
    if (patch.ipc.jsPollIntervalMs != null) {
      next.ipc.jsPollIntervalMs = clampInt(patch.ipc.jsPollIntervalMs, 50, 2000, next.ipc.jsPollIntervalMs);
    }
  }

  if (patch.about && typeof patch.about === "object") {
    if (typeof patch.about.developerName === "string") {
      next.about.developerName = patch.about.developerName.trim().slice(0, 80);
    }
    if (typeof patch.about.developerContact === "string") {
      next.about.developerContact = patch.about.developerContact.trim().slice(0, 120);
    }
    if (typeof patch.about.updateUrl === "string") {
      next.about.updateUrl = patch.about.updateUrl.trim().slice(0, 200);
    }
  }

  if (patch.ime && typeof patch.ime === "object") {
    if (patch.ime.keyboardType === "QWERTY" || patch.ime.keyboardType === "T9") {
      next.ime.keyboardType = patch.ime.keyboardType;
    }
    if (patch.ime.vibrateMode === "" || patch.ime.vibrateMode === "short" || patch.ime.vibrateMode === "long") {
      next.ime.vibrateMode = patch.ime.vibrateMode;
    }
    if (patch.ime.screenType === "circle" || patch.ime.screenType === "rect" || patch.ime.screenType === "pill-shaped") {
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
  const current = await getLocalSettings();
  const next = applyPatch(current, patch);
  const ok = await storageSetRaw(STORAGE_KEY, JSON.stringify(next));
  if (ok) {
    cache = next;
    syncGlobal(cache);
  }
  return next;
}

export async function setUiTransitionsEnabled(enabled) {
  return updateLocalSettings({ ui: { enableTransitions: !!enabled } });
}

export async function setJsPollIntervalMs(ms) {
  return updateLocalSettings({ ipc: { jsPollIntervalMs: ms } });
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
