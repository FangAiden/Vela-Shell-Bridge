import { createPage } from "../../app/page.js";
import { refreshBasicInfo } from "./about-basic.js";
import { refreshHardwareInfo } from "./about-shell.js";

const ABOUT_REFRESH_GAP_MS = 80;

function waitMs(ms) {
  return new Promise((resolve) => setTimeout(resolve, Math.max(0, Number(ms) || 0)));
}

export default createPage({
  data: {
    deviceName: "Root Shell Watch",
    model: "Watch DevKit",
    serial: "",
    language: "",
    region: "",
    screenText: "",

    firmware: "—",
    osVersion: "—",
    velaVersion: "—",
    uptimeText: "",

    deviceId: "UNKNOWN",
    storageUsed: "—",
    storageTotal: "—",
    storagePercent: 0,
    batteryPercent: 0,
    batteryText: "",

    networkTypeText: "",
    networkDetailText: "",
    brightnessPercent: 0,
    brightnessText: "",
    volumePercent: 0,
    volumeText: "",
    vibratorModeText: "",
    vibratorModeSub: "",
    localeText: "",
    locationText: "",
    compassText: "",
    accelText: "",

    kernelText: "",
    mountText: "",
    mountRawText: "",
    ipText: "",
    ipRawText: "",
    processText: "",

    cpuModelText: "",
    cpuMetaText: "",
    cpuInfoRawText: "",
    memUsedText: "",
    memTotalText: "",
    memUsedPercent: 0,
    memSubText: "",
    dataUsedText: "",
    dataTotalText: "",
    dataUsedPercent: 0,
    dataSubText: "",

    appName: "",
    appSourceText: "",
    appVersion: "0.1.0",
    buildNumber: "dev",
    packageName: "",
    sandboxPath: "",

    suStatus: "unknown", // unknown | checking | up | down
    suError: "",
    suStatusText: "Unknown",
    shellCapsText: "",
    shellCaps: [],

    isRefreshingAll: false,
    isRefreshingBasic: false,
    isRefreshingShell: false,
    currentScrollY: 0,

    showDetail: false,
    detailTitle: "",
    detailContent: "",
    detailAnim: "",
  },

  onShow() {
    if (this._enterRefreshTimer) {
      clearTimeout(this._enterRefreshTimer);
      this._enterRefreshTimer = 0;
    }
    // Let page finish rendering before starting system API calls.
    this._enterRefreshTimer = setTimeout(() => {
      this._enterRefreshTimer = 0;
      this.refreshAll("enter");
    }, 80);
  },

  onHide() {
    if (this._enterRefreshTimer) {
      clearTimeout(this._enterRefreshTimer);
      this._enterRefreshTimer = 0;
    }
  },

  onBackPress() {
    if (this.showDetail) {
      this.closeDetail();
      return true;
    }
    return false;
  },

  onScroll(e) {
    try {
      const y = (e && e.scrollY != null) ? e.scrollY : 0;
      const n = (typeof y === "number") ? y : parseFloat(String(y || "0"));
      if (isFinite(n)) this.currentScrollY = n;
    } catch (_) {}
  },

  restoreScroll(top) {
    try {
      let n = (typeof top === "number") ? top : parseFloat(String(top || "0"));
      if (!isFinite(n)) return;
      if (n < 0) n = 0;
      const el = this.$element && this.$element("infoScroll");
      if (el && typeof el.scrollTo === "function") {
        el.scrollTo({ top: n, behavior: "instant" });
      }
    } catch (_) {}
  },

  updateSuText() {
    if (this.suStatus === "checking") this.suStatusText = "Checking...";
    else if (this.suStatus === "up") this.suStatusText = "OK";
    else if (this.suStatus === "down") this.suStatusText = this.suError ? `DOWN: ${this.suError}` : "DOWN";
    else this.suStatusText = "Unknown";
  },

  openDetail(a, b) {
    try {
      let title = "";
      let key = "";

      if (typeof a === "string") {
        title = a;
        key = (typeof b === "string") ? b : "";
      } else {
        const e = a;
        const t = (e && (e.currentTarget || e.target)) || {};
        const attr = (t && t.attr) ? t.attr : {};
        const dataset = (t && t.dataset) ? t.dataset : {};

        const pickData = (obj, names) => {
          if (!obj || typeof obj !== "object") return "";
          for (let i = 0; i < names.length; i++) {
            const n = names[i];
            if (obj[n] != null) return obj[n];
          }
          // 兼容大小写/连字符差异
          const lowerMap = {};
          Object.keys(obj).forEach((k) => { lowerMap[String(k).toLowerCase()] = obj[k]; });
          for (let i = 0; i < names.length; i++) {
            const n = String(names[i]).toLowerCase();
            if (lowerMap[n] != null) return lowerMap[n];
            const n2 = n.replace(/[-_]/g, "");
            if (lowerMap[n2] != null) return lowerMap[n2];
          }
          return "";
        };

        title = pickData(attr, ["data-title", "dataTitle", "datatitle", "title"])
          || pickData(dataset, ["data-title", "dataTitle", "title"])
          || "详情";
        key = pickData(attr, ["data-key", "dataKey", "datakey", "key"])
          || pickData(dataset, ["data-key", "dataKey", "key"])
          || "";
      }

      let content = "";
      if (key && this[key] != null) content = String(this[key]);
      if (!content) content = "—";

      this.detailTitle = String(title || key || "详情");
      this.detailContent = content;
      this.showDetail = true;
      this.detailAnim = "detail-in";
    } catch (_) {}
  },

  closeDetail() {
    if (!this.showDetail) return;
    this.detailAnim = "detail-out";
    setTimeout(() => {
      this.showDetail = false;
      this.detailAnim = "";
      this.detailTitle = "";
      this.detailContent = "";
    }, 180);
  },

  async refreshAll(arg) {
    const mode = (typeof arg === "string")
      ? arg
      : (arg && typeof arg === "object" && typeof arg.mode === "string")
        ? arg.mode
        : "safe";
    const isEnterMode = mode === "enter";
    const isSafeMode = isEnterMode || mode === "safe";
    if (this.isRefreshingAll) return;
    this.isRefreshingAll = true;

    try {
      await refreshBasicInfo.call(this, {
        mode,
        collectLocation: !isSafeMode,
        collectSensors: !isSafeMode
      });
      if (isSafeMode) {
        this.suStatus = "unknown";
        this.suError = "";
        this.updateSuText();
        if (!this.shellCapsText) this.shellCapsText = "点击刷新后加载";
        return;
      }
      await waitMs(ABOUT_REFRESH_GAP_MS);
      await refreshHardwareInfo.call(this, { mode });
    } finally {
      this.isRefreshingAll = false;
    }
  }
});
