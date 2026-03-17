import prompt from "@system.prompt";
import app from "@system.app";
import suIpc from "../../services/su-daemon/index.js";
import device from "@system.device";
import { createPage } from "../../app/page.js";
import { getInterconnectState, reloadInterconnectBridgeConfig } from "../../services/interconnect/index.js";
import { getCachedTransitionsEnabled, getLocalSettings, setRemoteEnabled, setRemoteToken, updateLocalSettings } from "../../shared/settings/local-settings.js";

const SETTINGS_CALL_GAP_MS = 60;
const DEVICE_INFO_TIMEOUT_MS = 1200;
const POST_SHOW_REFRESH_DELAY_MS = 180;

function clampInt(n, minv, maxv, fallback) {
  const v = Math.floor(Number(n));
  if (!isFinite(v)) return fallback;
  if (v < minv) return minv;
  if (v > maxv) return maxv;
  return v;
}

function uniqStrings(list) {
  const out = [];
  const seen = {};
  (Array.isArray(list) ? list : []).forEach((it) => {
    const s = String(it == null ? "" : it).trim();
    if (!s) return;
    if (seen[s]) return;
    seen[s] = true;
    out.push(s);
  });
  return out;
}

function buildSummary(list) {
  const arr = uniqStrings(list);
  if (!arr.length) return "未启用";
  if (arr.length <= 3) return `已启用：${arr.join(", ")}`;
  return `已启用：${arr.slice(0, 3).join(", ")} 等 ${arr.length} 条`;
}

function callAppGetInfo() {
  try {
    return app.getInfo() || {};
  } catch (_) {
    return {};
  }
}

function safeStr(v) {
  if (v == null) return "";
  return String(v);
}

function execModeLabel(mode) {
  return mode === "sync" ? "同步" : "异步";
}

function execModeSub(mode) {
  return mode === "sync"
    ? "同步模式：低延迟，命令执行期间阻塞UI"
    : "异步模式：不阻塞UI，支持实时输出和终止";
}

function buildRemoteSummary(enabled, token) {
  if (!enabled) return "未启用（点击开启）";
  if (token) return `已启用 · 配对码：${token}`;
  return "已启用 · 配对码生成中（点击刷新）";
}

function buildRemoteStatusText(state) {
  const st = state && typeof state === "object" ? state : {};
  if (!st.remoteEnabled) return "未启用";
  if (st.connected) return "已连接";
  if (st.lastErrorMessage) return `错误：${st.lastErrorMessage}`;
  if (st.lastCloseAt) return st.lastCloseReason ? `已断开：${st.lastCloseReason}` : "已断开";
  return "等待连接...";
}

function splitBlacklistInput(text) {
  return String(text == null ? "" : text)
    .split(/[\n,，]+/)
    .map((x) => x.trim())
    .filter(Boolean);
}

const DEFAULT_IME_SETTINGS = {
  keyboardType: "QWERTY",
  vibrateMode: "short",
  screenType: "auto",
  maxLength: 5,
};

function normalizeImeKeyboard(v) {
  return v === "T9" ? "T9" : "QWERTY";
}

function normalizeImeVibrate(v) {
  if (v === "" || v === "short" || v === "long") return v;
  return DEFAULT_IME_SETTINGS.vibrateMode;
}

function normalizeImeScreen(v) {
  if (v === "auto" || v === "circle" || v === "rect" || v === "pill-shaped") return v;
  return "auto";
}

function waitMs(ms) {
  return new Promise((resolve) => setTimeout(resolve, Math.max(0, Number(ms) || 0)));
}

function normalizeImeSettings(raw) {
  const src = raw && typeof raw === "object" ? raw : {};
  const out = {
    keyboardType: normalizeImeKeyboard(src.keyboardType),
    vibrateMode: normalizeImeVibrate(src.vibrateMode),
    screenType: normalizeImeScreen(src.screenType),
    maxLength: clampInt(src.maxLength, 1, 9, DEFAULT_IME_SETTINGS.maxLength),
  };
  if (out.screenType === "pill-shaped" && out.keyboardType === "T9") {
    out.keyboardType = "QWERTY";
  }
  return out;
}

function imeKeyboardLabel(type) {
  return type === "T9" ? "九键" : "全键";
}

function imeVibrateLabel(mode) {
  if (mode === "long") return "长振动";
  if (mode === "short") return "短振动";
  return "不振动";
}

function imeScreenLabel(type) {
  if (type === "auto") return "自动";
  if (type === "rect") return "方形";
  if (type === "pill-shaped") return "胶囊";
  return "圆形";
}

export default createPage({
  data: {
    showDeferredSections: false,

    // local settings
    transitionsEnabled: getCachedTransitionsEnabled(),
    isCapsule: false,

    // exec mode
    execMode: "async",
    execModeLabel: execModeLabel("async"),
    execModeSub: execModeSub("async"),

    // interconnect remote
    remoteEnabled: false,
    remoteToken: "",
    remoteSummary: buildRemoteSummary(false, ""),
    remoteStatusText: "未启用",

    // daemon settings
    saveHistory: true,
    daemonPollMs: 300,
    cmdBlacklist: [],
    blacklistSummary: "未启用",

    // app info
    appNameText: "",
    appPackageText: "",
    appVersionText: "",
    isCheckingUpdate: false,

    // modal
    showBlacklist: false,
    modalAnim: "",
    isSavingBlacklist: false,
    blacklistDraft: [],
    showIme: false,
    imeTitle: "",
    imeInput: "",
    imeMode: "",
    imeKeyboardType: DEFAULT_IME_SETTINGS.keyboardType,
    imeVibrateMode: DEFAULT_IME_SETTINGS.vibrateMode,
    imeScreenType: DEFAULT_IME_SETTINGS.screenType,
    imeMaxLength: DEFAULT_IME_SETTINGS.maxLength,
    imeKeyboardLabel: imeKeyboardLabel(DEFAULT_IME_SETTINGS.keyboardType),
    imeVibrateLabel: imeVibrateLabel(DEFAULT_IME_SETTINGS.vibrateMode),
    imeScreenLabel: imeScreenLabel(DEFAULT_IME_SETTINGS.screenType),
  },

  onInit() {
    this._onShowLoading = false;
    this._detectDevicePending = false;
    this._detectDeviceDone = false;
    this._daemonLoading = false;
    this._daemonLoadedOnce = false;
    this._appInfoLoadedOnce = false;
    this._remoteRefreshing = false;
    this._active = false;
    this._showToken = 0;
    this._postShowTimer = 0;
  },

  nextShowToken() {
    this._showToken += 1;
    return this._showToken;
  },

  isShowActive(token) {
    return !!this._active && token === this._showToken;
  },

  clearPostShowTimer() {
    if (this._postShowTimer) {
      clearTimeout(this._postShowTimer);
      this._postShowTimer = 0;
    }
  },

  schedulePostShowRefresh(token) {
    this.clearPostShowTimer();
    this._postShowTimer = setTimeout(() => {
      this._postShowTimer = 0;
      Promise.resolve()
        .then(async () => {
          if (!this.isShowActive(token)) return;
          if (!this._daemonLoadedOnce) {
            await this.loadDaemonSettings(token, { silent: true });
          }
          if (!this.isShowActive(token)) return;
          this.showDeferredSections = true;
          if (!this._appInfoLoadedOnce) {
            this.loadAppInfo(token);
          }
          if (!this.isShowActive(token)) return;
          this.applyCachedRemoteStatus(token);
          if (!this.isShowActive(token)) return;
          await waitMs(SETTINGS_CALL_GAP_MS);
          if (!this.isShowActive(token)) return;
        })
        .catch((e) => {
          console.log(`SettingPage: post-show refresh failed: ${e && e.message ? e.message : String(e)}`);
        });
    }, POST_SHOW_REFRESH_DELAY_MS);
  },

  async onShow() {
    if (this._onShowLoading) return;
    const showToken = this.nextShowToken();
    this._active = true;
    this._onShowLoading = true;
    this.showDeferredSections = false;
    try {
      await this.detectDevice(showToken);
      await this.loadLocalSettings(showToken);
      if (!this.isShowActive(showToken)) return;
      if (!this.transitionsEnabled) this.animClass = "page-static";
      this.applyCachedRemoteStatus(showToken);
      this.schedulePostShowRefresh(showToken);
    } catch (e) {
      console.log(`SettingPage: onShow failed: ${e && e.message ? e.message : String(e)}`);
    } finally {
      this._onShowLoading = false;
    }
  },

  onHide() {
    this._active = false;
    this._showToken += 1;
    this._onShowLoading = false;
    this.showDeferredSections = false;
    this.clearPostShowTimer();
  },

  onDestroy() {
    this._active = false;
    this._showToken += 1;
    this._onShowLoading = false;
    this.showDeferredSections = false;
    this.clearPostShowTimer();
  },

  detectDevice(showToken) {
    const token = typeof showToken === "number" ? showToken : null;
    if (this._detectDeviceDone) return Promise.resolve();
    if (this._detectDevicePending) return Promise.resolve();
    this._detectDevicePending = true;
    return new Promise((resolve) => {
      let done = false;
      const finish = () => {
        if (done) return;
        done = true;
        this._detectDevicePending = false;
        resolve();
      };
      const timeoutId = setTimeout(() => {
        console.log("SettingPage: detectDevice timeout");
        finish();
      }, DEVICE_INFO_TIMEOUT_MS);
      const safeFinish = () => {
        clearTimeout(timeoutId);
        finish();
      };
      try {
        device.getInfo({
          success: (ret) => {
            try {
              const info = ret && typeof ret === "object" ? ret : {};
              console.log(`SettingPage: detectDevice shape=${info.screenShape} w=${info.windowWidth}`);
              if (token == null || this.isShowActive(token)) {
                if (info.screenShape === "pill-shaped") {
                  this.isCapsule = true;
                } else {
                  const w = info.windowWidth || info.screenWidth;
                  this.isCapsule = !!(w && w < 280);
                }
                console.log(`SettingPage: isCapsule=${this.isCapsule}`);
                this._detectDeviceDone = true;
              }
            } catch (e) {
              console.log(`SettingPage: detectDevice parse failed: ${e && e.message ? e.message : String(e)}`);
            } finally {
              safeFinish();
            }
          },
          fail: (data, code) => {
            console.log(`SettingPage: detectDevice failed code=${code}`);
            safeFinish();
          }
        });
      } catch (e) {
        console.log(`SettingPage: detectDevice throw: ${e && e.message ? e.message : String(e)}`);
        safeFinish();
      }
    });
  },

  // 返回时加退出动画
  onBackPress() {
    if (this.showIme) {
      this.closeIme();
      return true;
    }
    return false;
  },

  async loadLocalSettings(showToken) {
    const token = typeof showToken === "number" ? showToken : null;
    const guarded = token != null;
    const active = () => !guarded || this.isShowActive(token);
    try {
      const local = await getLocalSettings();
      if (!active()) return;
      this.transitionsEnabled = !!(local && local.ui && local.ui.enableTransitions);

      const shell = (local && local.shell && typeof local.shell === "object") ? local.shell : {};
      const em = shell.execMode === "sync" ? "sync" : "async";
      this.execMode = em;
      this.execModeLabel = execModeLabel(em);
      this.execModeSub = execModeSub(em);

      const remote = (local && local.remote && typeof local.remote === "object") ? local.remote : {};
      this.remoteEnabled = remote.enabled === true;
      this.remoteToken = safeStr(remote.token).trim();
      this.remoteSummary = buildRemoteSummary(this.remoteEnabled, this.remoteToken);
      this.remoteStatusText = buildRemoteStatusText(getInterconnectState());

      const ime = normalizeImeSettings(local && local.ime);
      this.applyImeState(ime);
    } catch (_) {
      if (!active()) return;
      this.transitionsEnabled = true;
      this.execMode = "async";
      this.execModeLabel = execModeLabel("async");
      this.execModeSub = execModeSub("async");
      this.remoteEnabled = false;
      this.remoteToken = "";
      this.remoteSummary = buildRemoteSummary(false, "");
      this.remoteStatusText = "未启用";
      this.applyImeState(DEFAULT_IME_SETTINGS);
    }
  },

  loadAppInfo(showToken) {
    const token = typeof showToken === "number" ? showToken : null;
    if (token != null && !this.isShowActive(token)) return;
    const info = callAppGetInfo();
    this.appNameText = String(info.name || "—");
    this.appPackageText = String(info.packageName || "—");
    const vn = info.versionName || "";
    const vc = info.versionCode != null ? String(info.versionCode) : "";
    if (vn && vc) this.appVersionText = `${vn} (${vc})`;
    else if (vn) this.appVersionText = String(vn);
    else this.appVersionText = "—";
    this._appInfoLoadedOnce = true;
  },

  async loadDaemonSettings(showToken, options = {}) {
    const token = typeof showToken === "number" ? showToken : null;
    const guarded = token != null;
    const active = () => !guarded || this.isShowActive(token);
    const silent = !!(options && options.silent);
    if (this._daemonLoading) return;
    this._daemonLoading = true;
    try {
      const resp = await suIpc.management("get_settings", {}, { timeoutMs: 1400 });
      if (!active()) return;
      const data = resp && resp.ok ? resp.data : null;
      const saveHistory = data && typeof data.save_history === "boolean" ? data.save_history : true;
      const daemonPoll = data && data.daemon_poll_interval_ms != null ? data.daemon_poll_interval_ms : 300;
      const bl = data && Array.isArray(data.cmd_blacklist) ? data.cmd_blacklist : [];

      this.saveHistory = !!saveHistory;
      this.daemonPollMs = clampInt(daemonPoll, 50, 2000, 300);
      this.cmdBlacklist = uniqStrings(bl);
      this.blacklistSummary = buildSummary(this.cmdBlacklist);
      this._daemonLoadedOnce = true;
    } catch (e) {
      if (!active()) return;
      this.blacklistSummary = buildSummary(this.cmdBlacklist);
      if (!silent) {
        prompt.showToast({ message: "Daemon 未就绪", duration: 700 });
      }
    } finally {
      this._daemonLoading = false;
    }
  },

  applyCachedRemoteStatus(showToken) {
    const token = typeof showToken === "number" ? showToken : null;
    const guarded = token != null;
    const active = () => !guarded || this.isShowActive(token);
    if (!active()) return;
    const st = getInterconnectState();
    this.remoteStatusText = buildRemoteStatusText(st);
    if (this.remoteEnabled) {
      const nextToken = (st && st.token != null) ? safeStr(st.token).trim() : "";
      if (nextToken && nextToken !== this.remoteToken) {
        this.remoteToken = nextToken;
        this.remoteSummary = buildRemoteSummary(true, nextToken);
      }
    }
  },

  async applyDaemonSettings(patch) {
    const resp = await suIpc.management("set_settings", patch || {}, { timeoutMs: 1800 });
    if (!resp || resp.ok !== true) {
      throw new Error((resp && resp.message) || "set_settings failed");
    }
    const data = resp.data || {};
    if (typeof data.save_history === "boolean") this.saveHistory = !!data.save_history;
    if (data.daemon_poll_interval_ms != null) this.daemonPollMs = clampInt(data.daemon_poll_interval_ms, 50, 2000, this.daemonPollMs);
    if (Array.isArray(data.cmd_blacklist)) {
      this.cmdBlacklist = uniqStrings(data.cmd_blacklist);
      this.blacklistSummary = buildSummary(this.cmdBlacklist);
    }
  },

  async onToggleSaveHistory() {
    const next = !this.saveHistory;
    this.saveHistory = next;
    try {
      await this.applyDaemonSettings({ save_history: next });
      prompt.showToast({ message: next ? "已开启记录" : "已关闭记录", duration: 650 });
    } catch (e) {
      this.saveHistory = !next;
      prompt.showToast({ message: e && e.message ? e.message : "设置失败", duration: 900 });
    }
  },

  async onToggleTransitions() {
    const next = !this.transitionsEnabled;
    this.transitionsEnabled = next;
    if (!next) this.animClass = "page-static";
    try {
      await updateLocalSettings({ ui: { enableTransitions: next } });
      prompt.showToast({ message: next ? "动画已开启" : "动画已关闭", duration: 650 });
    } catch (e) {
      this.transitionsEnabled = !next;
      prompt.showToast({ message: e && e.message ? e.message : "保存失败", duration: 900 });
    }
  },

  async onToggleExecMode() {
    const next = this.execMode === "async" ? "sync" : "async";
    this.execMode = next;
    this.execModeLabel = execModeLabel(next);
    this.execModeSub = execModeSub(next);
    try {
      await updateLocalSettings({ shell: { execMode: next } });
      prompt.showToast({ message: next === "sync" ? "已切换为同步模式" : "已切换为异步模式", duration: 650 });
    } catch (e) {
      const prev = next === "sync" ? "async" : "sync";
      this.execMode = prev;
      this.execModeLabel = execModeLabel(prev);
      this.execModeSub = execModeSub(prev);
      prompt.showToast({ message: e && e.message ? e.message : "保存失败", duration: 900 });
    }
  },

  async refreshRemoteStatus(showToken) {
    const token = typeof showToken === "number" ? showToken : null;
    const guarded = token != null;
    const active = () => !guarded || this.isShowActive(token);
    if (this._remoteRefreshing) return;
    this._remoteRefreshing = true;
    try {
      await reloadInterconnectBridgeConfig();
    } catch (_) { }
    try {
      if (!active()) return;
      const st = getInterconnectState();
      this.remoteStatusText = buildRemoteStatusText(st);

      // Token may be generated by bridge on enable.
      if (this.remoteEnabled) {
        const token = (st && st.token != null) ? safeStr(st.token).trim() : "";
        if (token && token !== this.remoteToken) {
          this.remoteToken = token;
          this.remoteSummary = buildRemoteSummary(true, token);
        }
      }
    } finally {
      this._remoteRefreshing = false;
    }
  },

  async onToggleRemote() {
    const next = !this.remoteEnabled;
    this.remoteEnabled = next;
    this.remoteSummary = buildRemoteSummary(next, this.remoteToken);

    try {
      await setRemoteEnabled(next);
      await reloadInterconnectBridgeConfig();
      await this.loadLocalSettings();
      await this.refreshRemoteStatus();
      prompt.showToast({ message: next ? "已开启远程控制" : "已关闭远程控制", duration: 700 });
    } catch (e) {
      prompt.showToast({ message: e && e.message ? e.message : "设置失败", duration: 900 });
      await this.loadLocalSettings();
      await this.refreshRemoteStatus();
    }
  },

  async regenRemoteToken() {
    if (!this.remoteEnabled) {
      prompt.showToast({ message: "请先开启远程控制", duration: 700 });
      return;
    }
    try {
      await setRemoteToken("");
      await reloadInterconnectBridgeConfig();
      await this.loadLocalSettings();
      await this.refreshRemoteStatus();
      prompt.showToast({ message: "已生成新配对码", duration: 700 });
    } catch (e) {
      prompt.showToast({ message: e && e.message ? e.message : "生成失败", duration: 900 });
    }
  },

  applyImeState(ime) {
    const next = normalizeImeSettings(ime);
    this.imeKeyboardType = next.keyboardType;
    this.imeVibrateMode = next.vibrateMode;
    this.imeScreenType = next.screenType;
    this.imeMaxLength = next.maxLength;
    this.updateImeLabels();
  },

  updateImeLabels() {
    this.imeKeyboardLabel = imeKeyboardLabel(this.imeKeyboardType);
    this.imeVibrateLabel = imeVibrateLabel(this.imeVibrateMode);
    this.imeScreenLabel = imeScreenLabel(this.imeScreenType);
  },

  async saveImeSettings(patch) {
    const next = await updateLocalSettings({ ime: patch || {} });
    this.applyImeState(next && next.ime);
  },

  toggleImeKeyboard() {
    let next = this.imeKeyboardType === "QWERTY" ? "T9" : "QWERTY";
    if (this.imeScreenType === "pill-shaped" && next === "T9") {
      next = "QWERTY";
      prompt.showToast({ message: "胶囊屏仅支持全键", duration: 650 });
    }
    this.saveImeSettings({ keyboardType: next });
  },

  cycleImeVibrate() {
    const order = ["", "short", "long"];
    const idx = order.indexOf(this.imeVibrateMode);
    const next = order[(idx + 1 + order.length) % order.length];
    this.saveImeSettings({ vibrateMode: next });
  },

  cycleImeScreen() {
    const order = ["auto", "circle", "rect", "pill-shaped"];
    const idx = order.indexOf(this.imeScreenType);
    const next = order[(idx + 1 + order.length) % order.length];
    const patch = { screenType: next };
    if (next === "pill-shaped" && this.imeKeyboardType === "T9") {
      patch.keyboardType = "QWERTY";
      prompt.showToast({ message: "胶囊屏仅支持全键", duration: 650 });
    }
    this.saveImeSettings(patch);
  },

  decImeMaxLen() {
    const next = clampInt(this.imeMaxLength - 1, 1, 9, this.imeMaxLength);
    if (next === this.imeMaxLength) return;
    this.saveImeSettings({ maxLength: next });
  },

  incImeMaxLen() {
    const next = clampInt(this.imeMaxLength + 1, 1, 9, this.imeMaxLength);
    if (next === this.imeMaxLength) return;
    this.saveImeSettings({ maxLength: next });
  },

  async decDaemonPoll() {
    const next = clampInt(this.daemonPollMs - 50, 50, 2000, 300);
    if (next === this.daemonPollMs) return;
    const prev = this.daemonPollMs;
    this.daemonPollMs = next;
    try {
      await this.applyDaemonSettings({ daemon_poll_interval_ms: next });
    } catch (e) {
      this.daemonPollMs = prev;
      prompt.showToast({ message: e && e.message ? e.message : "设置失败", duration: 900 });
    }
  },

  async incDaemonPoll() {
    const next = clampInt(this.daemonPollMs + 50, 50, 2000, 300);
    if (next === this.daemonPollMs) return;
    const prev = this.daemonPollMs;
    this.daemonPollMs = next;
    try {
      await this.applyDaemonSettings({ daemon_poll_interval_ms: next });
    } catch (e) {
      this.daemonPollMs = prev;
      prompt.showToast({ message: e && e.message ? e.message : "设置失败", duration: 900 });
    }
  },

  async openBlacklist() {
    if (!this._daemonLoadedOnce && !this._daemonLoading) {
      await this.loadDaemonSettings(null, { silent: true });
    }
    this.blacklistDraft = uniqStrings(this.cmdBlacklist);
    this.modalAnim = "modal-enter";
    this.showBlacklist = true;
  },

  closeBlacklist() {
    if (this.showIme) this.closeIme();
    this.modalAnim = "modal-leave";
    setTimeout(() => {
      this.showBlacklist = false;
    }, 180);
  },

  openBlacklistIme() {
    this.openIme("blacklist", "", "添加黑名单");
  },

  removeBlacklistItem(value) {
    const v = String(value == null ? "" : value).trim();
    if (!v) return;
    const next = (Array.isArray(this.blacklistDraft) ? this.blacklistDraft : []).filter((x) => String(x) !== v);
    this.blacklistDraft = next;
  },

  openIme(mode, value, title) {
    this.imeMode = mode || "";
    this.imeInput = String(value == null ? "" : value);
    this.imeTitle = title || "输入";
    this.showIme = true;
  },

  closeIme() {
    this.showIme = false;
    this.imeInput = "";
    this.imeTitle = "";
    this.imeMode = "";
  },

  onImeComplete(e) {
    const detail = e && e.detail ? e.detail : {};
    const content = String(detail.content == null ? "" : detail.content);
    if (!content) return;
    this.imeInput = String(this.imeInput == null ? "" : this.imeInput) + content;
  },

  onImeDelete() {
    const cur = String(this.imeInput == null ? "" : this.imeInput);
    this.imeInput = cur.slice(0, -1);
  },

  confirmIme() {
    const mode = this.imeMode;
    const text = String(this.imeInput == null ? "" : this.imeInput);
    this.closeIme();
    if (mode !== "blacklist") return;

    const next = splitBlacklistInput(text);
    if (!next.length) return;
    this.blacklistDraft = uniqStrings([].concat(this.blacklistDraft || [], next));
  },


  async saveBlacklist() {
    if (this.isSavingBlacklist) return;
    this.isSavingBlacklist = true;
    try {
      await this.applyDaemonSettings({ cmd_blacklist: this.blacklistDraft });
      prompt.showToast({ message: "已保存", duration: 650 });
      this.closeBlacklist();
    } catch (e) {
      prompt.showToast({ message: e && e.message ? e.message : "保存失败", duration: 900 });
    } finally {
      this.isSavingBlacklist = false;
    }
  },

  async checkUpdate() {
    if (this.isCheckingUpdate) return;
    this.isCheckingUpdate = true;
    try {
      await new Promise((r) => setTimeout(r, 350));
      prompt.showToast({
        message: `当前版本：${this.appVersionText || "—"}`,
        duration: 1100,
      });
    } finally {
      this.isCheckingUpdate = false;
    }
  },
});
