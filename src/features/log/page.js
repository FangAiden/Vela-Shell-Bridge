import prompt from "@system.prompt";
import suIpc from "../../services/su-daemon/index.js";
import { createPage } from "../../app/page.js";
import { formatHhMm } from "../../shared/utils/time.js";
import { firstLine, oneLine } from "../../shared/utils/text.js";

export default createPage({
  data: {
    apps: [],
    appCount: 0,
    totalCount: 0,
    allEntries: [],
    stats: {},

    isAppView: true,
    isEntryView: false,
    selectedAppId: "",

    headerTitle: "日志",
    headerSubText: "",

    entries: [],
    summaryText: "",
    lastRefreshText: "",
    isLoading: false,
    isClearing: false,

    showDetail: false,
    detailTitle: "",
    detailContent: "",
    detailAnim: "",
  },

  onShow() {
    this.selectedAppId = "";
    this.isAppView = true;
    this.isEntryView = false;
    this.applyView();

    this.refreshLogs();
  },

  onBackPress() {
    if (this.showDetail) {
      this.closeDetail();
      return true;
    }
    if (this.isEntryView) {
      this.backToApps();
      return true;
    }
    return false;
  },

  applyView() {
    const apps = Array.isArray(this.apps) ? this.apps : [];
    const allEntries = Array.isArray(this.allEntries) ? this.allEntries : [];
    const stats = (this.stats && typeof this.stats === "object") ? this.stats : {};

    if (this.isEntryView && this.selectedAppId) {
      const appId = String(this.selectedAppId || "");
      const appInfo = (stats[appId] && typeof stats[appId] === "object") ? stats[appId] : {};
      const count = typeof appInfo.count === "number" ? appInfo.count : parseInt(appInfo.count, 10) || 0;

      const entries = allEntries.filter((e) => e && e.appId === appId);
      this.entries = entries;

      this.headerTitle = appId;
      this.headerSubText = `共 ${entries.length} 条`;
      this.summaryText = `请求 ${count} 次 · 记录 ${entries.length} 条`;
      return;
    }

    this.entries = [];
    this.headerTitle = "日志";
    this.headerSubText = this.lastRefreshText ? `更新 ${this.lastRefreshText}` : "";

    const appCount = typeof this.appCount === "number" ? this.appCount : apps.length;
    const totalCount = typeof this.totalCount === "number" ? this.totalCount : 0;
    const execCount = allEntries.length;
    this.summaryText =
      (appCount || totalCount || execCount)
        ? `应用 ${appCount} · 累计 ${totalCount} 次 · 记录 ${execCount} 条`
        : "";
  },

  openApp(appId) {
    const id = String(appId || "");
    if (!id) return;
    this.selectedAppId = id;
    this.isAppView = false;
    this.isEntryView = true;
    this.applyView();
  },

  backToApps() {
    this.selectedAppId = "";
    this.isAppView = true;
    this.isEntryView = false;
    this.applyView();
  },

  async refreshLogs() {
    if (this.isLoading) return;
    this.isLoading = true;

    try {
      const data = await suIpc.getLogs({ timeoutMs: 2200 });
      const stats = (data && data.stats && typeof data.stats === "object") ? data.stats : {};
      const rawExec = (data && Array.isArray(data.exec)) ? data.exec : [];

      const appCount = Object.keys(stats).length;
      const totalCount = Object.keys(stats).reduce((sum, k) => {
        const it = stats[k] && typeof stats[k] === "object" ? stats[k] : {};
        const n = typeof it.count === "number" ? it.count : parseInt(it.count, 10) || 0;
        return sum + n;
      }, 0);

      const apps = Object.keys(stats).map((appId) => {
        const it = stats[appId] && typeof stats[appId] === "object" ? stats[appId] : {};
        const count = typeof it.count === "number" ? it.count : parseInt(it.count, 10) || 0;
        const lastTsSec =
          (typeof it.last_ts === "number") ? it.last_ts
            : (it.last_ts != null) ? parseInt(it.last_ts, 10) || 0
              : 0;
        const lastText = lastTsSec > 0 ? `最近：${formatHhMm(lastTsSec * 1000)}` : "";
        return { appId: String(appId), count, lastTsSec, lastText };
      }).sort((a, b) => {
        if (b.lastTsSec !== a.lastTsSec) return b.lastTsSec - a.lastTsSec;
        if (b.count !== a.count) return b.count - a.count;
        return a.appId.localeCompare(b.appId);
      });

      const entries = rawExec.map((it) => {
        const id = (it && it.id != null) ? String(it.id) : String(Math.random());
        const appId = it && it.app_id != null ? String(it.app_id) : "";
        const cmd = oneLine(it && it.cmd);
        const state = it && it.state != null ? String(it.state) : "";
        const tsSec = it && typeof it.ts === "number" ? it.ts : parseInt(it && it.ts, 10) || 0;
        const timeText = tsSec > 0 ? formatHhMm(tsSec * 1000) : "";
        const exitCode =
          (it && typeof it.exit_code === "number") ? it.exit_code
            : (it && it.exit_code != null) ? parseInt(it.exit_code, 10)
              : null;
        const success = (it && it.success === true) || (exitCode === 0);

        const output = (it && it.output != null) ? String(it.output) : "";
        const message = (it && it.message != null) ? String(it.message) : "";
        const errMsg = (it && it.error && it.error.message != null) ? String(it.error.message) : "";
        const outBrief = firstLine(output || errMsg || message);

        let badgeText = "—";
        let badgeClass = "badge-muted";
        let badgeTextClass = "badge-text-muted";
        if (state === "running") {
          badgeText = "RUN";
          badgeClass = "badge-run";
          badgeTextClass = "badge-text-run";
        } else if (state === "kill") {
          badgeText = "KILL";
          badgeClass = "badge-warn";
          badgeTextClass = "badge-text-warn";
        } else if (state === "denied") {
          badgeText = "DENY";
          badgeClass = "badge-err";
          badgeTextClass = "badge-text-err";
        } else if (state === "done") {
          const codeText = (exitCode == null || !isFinite(exitCode)) ? "?" : String(exitCode);
          badgeText = codeText;
          badgeClass = success ? "badge-ok" : "badge-err";
          badgeTextClass = success ? "badge-text-ok" : "badge-text-err";
        } else {
          badgeText = "ERR";
          badgeClass = "badge-err";
          badgeTextClass = "badge-text-err";
        }

        const appText = timeText ? `${appId} · ${timeText}` : (appId || "—");

        return {
          id,
          appId,
          cmd,
          cmdText: cmd || "—",
          appText,
          outBrief,
          badgeText,
          badgeClass,
          badgeTextClass,
          state,
          exitCode,
          success,
          output,
          message: errMsg || message,
          timeText,
        };
      });

      this.apps = apps;
      this.appCount = appCount;
      this.totalCount = totalCount;
      this.stats = stats;
      this.allEntries = entries;

      this.lastRefreshText = formatHhMm(Date.now());
      this.applyView();
    } catch (e) {
      prompt.showToast({
        message: `刷新失败：${e && e.message ? e.message : "unknown"}`,
        duration: 900
      });
    } finally {
      this.isLoading = false;
    }
  },

  async clearLogs() {
    if (this.isClearing) return;
    this.isClearing = true;

    try {
      await suIpc.clearLogs({ timeoutMs: 1800 });
      this.apps = [];
      this.appCount = 0;
      this.totalCount = 0;
      this.stats = {};
      this.allEntries = [];
      this.entries = [];
      this.lastRefreshText = formatHhMm(Date.now());
      this.selectedAppId = "";
      this.isAppView = true;
      this.isEntryView = false;
      this.applyView();
      prompt.showToast({ message: "已清空", duration: 700 });
    } catch (e) {
      prompt.showToast({
        message: `清空失败：${e && e.message ? e.message : "unknown"}`,
        duration: 900
      });
    } finally {
      this.isClearing = false;
    }
  },

  openDetail(entryId) {
    try {
      const id = String(entryId || "");
      const hit = (this.entries || []).find((it) => it && it.id === id) || null;
      if (!hit) return;

      const state = hit.state || "—";
      const exitText =
        hit.exitCode == null || !isFinite(hit.exitCode)
          ? "—"
          : String(hit.exitCode);
      const out = hit.output || hit.message || "—";

      this.detailTitle = hit.cmdText || hit.cmd || "详情";
      this.detailContent =
        `应用：${hit.appId || "—"}\n` +
        `时间：${hit.timeText || "—"}\n` +
        `状态：${state}\n` +
        `退出码：${exitText}\n` +
        `\n命令:\n${hit.cmd || "—"}\n` +
        `\n结果:\n${out}`;

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
});
