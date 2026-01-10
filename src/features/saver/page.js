import brightness from "@system.brightness";
import device from "@system.device";
import prompt from "@system.prompt";
import { createPage } from "../../app/page.js";

function getGlobalThis() {
  try {
    if (typeof globalThis !== "undefined") return globalThis;
  } catch (_) {}
  try {
    if (typeof global !== "undefined") return global;
  } catch (_) {}
  return {};
}

function clampNumber(n, min, max, fallback) {
  const v = Number(n);
  if (!isFinite(v)) return fallback;
  if (v < min) return min;
  if (v > max) return max;
  return v;
}

function callSuccess(fn, args, timeoutMs) {
  return new Promise((resolve, reject) => {
    let done = false;
    const t = setTimeout(() => {
      if (done) return;
      done = true;
      reject(new Error("timeout"));
    }, timeoutMs || 800);

    try {
      fn(Object.assign({}, args || {}, {
        success: (data) => {
          if (done) return;
          done = true;
          clearTimeout(t);
          resolve(data);
        },
        fail: (data, code) => {
          if (done) return;
          done = true;
          clearTimeout(t);
          const msg =
            data && (data.message || data.msg)
              ? data.message || data.msg
              : code != null
                ? String(code)
                : "fail";
          reject(new Error(msg));
        },
      }));
    } catch (e) {
      if (done) return;
      done = true;
      clearTimeout(t);
      reject(e);
    }
  });
}

const G = getGlobalThis();

function toast(msg, duration) {
  try {
    prompt.showToast({ message: String(msg || ""), duration: duration || 900 });
  } catch (_) {}
}

export default createPage({
  data: {
    showHud: true,

    dotX: 0,
    dotY: 0,
    dotOpacity: 0.08,

    keepOn: false,
    keepOnError: "",
  },

  onInit() {
    this._active = false;
    this._dotTimer = null;
    this._hudTimer = null;
    this._screenW = 0;
    this._screenH = 0;

    // 初始落点（避免首帧全黑时的固定像素）
    this.dotX = 120;
    this.dotY = 80;
  },

  onShow() {
    this.enterSaver();
  },

  onHide() {
    this.exitSaver();
  },

  onDestroy() {
    this.exitSaver();
  },

  onBackPress() {
    this.exitSaver();
    return false;
  },

  onTap() {
    this.showHud = true;
    this.resetHudTimer();
  },

  resetHudTimer() {
    if (this._hudTimer) {
      clearTimeout(this._hudTimer);
      this._hudTimer = null;
    }
    this._hudTimer = setTimeout(() => {
      this.showHud = false;
      this._hudTimer = null;
    }, 1800);
  },

  async ensureScreenSize() {
    if (this._screenW > 0 && this._screenH > 0) return;

    let sw = 0;
    let sh = 0;
    try {
      const info = await callSuccess(device.getInfo.bind(device), {}, 900);
      sw = parseInt(info && info.screenWidth, 10);
      sh = parseInt(info && info.screenHeight, 10);
    } catch (_) {}

    if (!isFinite(sw) || sw <= 0) sw = 480;
    if (!isFinite(sh) || sh <= 0) sh = 320;

    this._screenW = sw;
    this._screenH = sh;
    try {
      G.__VSB_SCREEN_SIZE__ = { w: sw, h: sh };
    } catch (_) {}
  },

  pickNextDot() {
    const sw = this._screenW || (G.__VSB_SCREEN_SIZE__ && G.__VSB_SCREEN_SIZE__.w) || 480;
    const sh = this._screenH || (G.__VSB_SCREEN_SIZE__ && G.__VSB_SCREEN_SIZE__.h) || 320;

    const margin = 48;
    const minX = margin;
    const maxX = Math.max(margin, sw - margin);
    const minY = margin;
    const maxY = Math.max(margin, sh - margin);

    const x = minX + Math.random() * (maxX - minX);
    const y = minY + Math.random() * (maxY - minY);
    const op = 0.04 + Math.random() * 0.08;

    this.dotX = Math.round(clampNumber(x, 0, sw, 0));
    this.dotY = Math.round(clampNumber(y, 0, sh, 0));
    this.dotOpacity = clampNumber(op, 0.03, 0.15, 0.08);
  },

  startDotMover() {
    this.stopDotMover();
    this.pickNextDot();
    this._dotTimer = setInterval(() => {
      try {
        this.pickNextDot();
      } catch (_) {}
    }, 14000);
  },

  stopDotMover() {
    if (this._dotTimer) {
      clearInterval(this._dotTimer);
      this._dotTimer = null;
    }
  },

  async enterSaver() {
    if (this._active) return;
    this._active = true;

    this.showHud = true;
    if (this._hudTimer) {
      clearTimeout(this._hudTimer);
      this._hudTimer = null;
    }

    await this.ensureScreenSize();
    this.startDotMover();

    try {
      if (!brightness || typeof brightness.setKeepScreenOn !== "function") {
        this.keepOn = false;
        this.keepOnError = "brightness.setKeepScreenOn 不可用";
        return;
      }
      await callSuccess(brightness.setKeepScreenOn.bind(brightness), { keepScreenOn: true }, 900);
      this.keepOn = true;
      this.keepOnError = "";
      this.resetHudTimer();
    } catch (e) {
      this.keepOn = false;
      this.keepOnError = e && e.message ? e.message : "开启失败";
      toast(`开启常亮失败：${this.keepOnError}`, 1200);
    }
  },

  exitSaver() {
    if (!this._active) return;
    this._active = false;

    this.stopDotMover();
    if (this._hudTimer) {
      clearTimeout(this._hudTimer);
      this._hudTimer = null;
    }

    try {
      if (brightness && typeof brightness.setKeepScreenOn === "function") {
        brightness.setKeepScreenOn({ keepScreenOn: false });
      }
    } catch (_) {}
  },
});
