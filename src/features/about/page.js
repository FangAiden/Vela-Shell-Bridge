import { createPage } from "../../app/page.js";
import { refreshBasicInfo } from "./about-basic.js";
import { refreshHardwareInfo } from "./about-shell.js";
import suIpc from "../../services/su-daemon/index.js";

const ABOUT_REFRESH_GAP_MS = 80;
const DAEMON_PROBE_TIMEOUT_ENTER_MS = 650;
const DAEMON_PROBE_TIMEOUT_REFRESH_MS = 900;
// Debug switch: keep enter-mode basic collection, but skip it for manual full refresh.
const DISABLE_BASIC_ON_FULL_REFRESH = true;

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

  clearShellOnlyData(hintText) {
    this.kernelText = "";
    this.mountText = "";
    this.mountRawText = "";
    this.ipText = "";
    this.ipRawText = "";
    this.processText = "";

    this.cpuModelText = "";
    this.cpuMetaText = "";
    this.cpuInfoRawText = "";
    this.memUsedText = "";
    this.memTotalText = "";
    this.memUsedPercent = 0;
    this.memSubText = "";
    this.dataUsedText = "";
    this.dataTotalText = "";
    this.dataUsedPercent = 0;
    this.dataSubText = "";

    this.shellCaps = [];
    this.shellCapsText = hintText || "";
  },

  async probeDaemon(options) {
    const opt = options && typeof options === "object" ? options : {};
    const timeoutMs = (typeof opt.timeoutMs === "number" && opt.timeoutMs > 0)
      ? Math.floor(opt.timeoutMs)
      : DAEMON_PROBE_TIMEOUT_ENTER_MS;

    this.suStatus = "checking";
    this.suError = "";
    this.updateSuText();

    try {
      // Any structured response means daemon is reachable.
      const resp = await suIpc.management("get_settings", {}, { timeoutMs });
      if (resp && typeof resp === "object") {
        this.suStatus = "up";
        this.suError = "";
        this.updateSuText();
        return true;
      }
      this.suStatus = "down";
      this.suError = "empty response";
      this.updateSuText();
      return false;
    } catch (e) {
      this.suStatus = "down";
      this.suError = e && e.message ? String(e.message) : String(e || "daemon unavailable");
      this.updateSuText();
      return false;
    }
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
        : "full";
    const isEnterMode = mode === "enter";
    const isSafeMode = isEnterMode || mode === "safe";
    const shouldRefreshBasic = !(DISABLE_BASIC_ON_FULL_REFRESH && mode === "full");
    if (this.isRefreshingAll) return;
    this.isRefreshingAll = true;

    try {
      const daemonUp = await this.probeDaemon({
        timeoutMs: isEnterMode ? DAEMON_PROBE_TIMEOUT_ENTER_MS : DAEMON_PROBE_TIMEOUT_REFRESH_MS
      });

      if (shouldRefreshBasic) {
        await refreshBasicInfo.call(this, {
          mode,
          collectLocation: !isSafeMode,
          collectSensors: !isSafeMode
        });
      }

      if (isSafeMode) {
        if (daemonUp) {
          if (!this.shellCapsText) this.shellCapsText = "守护已运行，点击刷新加载 Shell 详情";
        } else {
          this.clearShellOnlyData("守护未运行，仅显示快应用信息");
        }
        return;
      }

      if (!daemonUp) {
        this.clearShellOnlyData("守护未运行，无法读取 Shell 详情");
        return;
      }

      await waitMs(ABOUT_REFRESH_GAP_MS);
      await refreshHardwareInfo.call(this, { mode });
    } finally {
      this.isRefreshingAll = false;
    }
  }
});
