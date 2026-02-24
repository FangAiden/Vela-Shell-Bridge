import prompt from "@system.prompt";
import app from "@system.app";
import file from "@system.file";
import suIpc from "../../services/su-daemon/index.js";
import { createPage } from "../../app/page.js";
import { formatHhMmFromUnixSec } from "../../shared/utils/time.js";

const DEFAULT_QUICKAPP_ABS_ROOT = "/data/files/";
const DEFAULT_ADMIN_APP_ID = "com.vela.su.aigik";
const DEFAULT_ADMIN_FILES_DIR = `/data/files/${DEFAULT_ADMIN_APP_ID}/`;

function setHint(vm, message) {
  if (vm && typeof vm === "object") {
    vm.scanHint = String(message || "");
  }
}

function withTimeout(promise, timeoutMs, timeoutMessage) {
  return new Promise((resolve, reject) => {
    let done = false;
    const t = setTimeout(() => {
      if (done) return;
      done = true;
      reject(new Error(timeoutMessage || `Timeout ${timeoutMs}ms`));
    }, timeoutMs);
    Promise.resolve(promise)
      .then((ret) => {
        if (done) return;
        done = true;
        clearTimeout(t);
        resolve(ret);
      })
      .catch((err) => {
        if (done) return;
        done = true;
        clearTimeout(t);
        reject(err);
      });
  });
}

function notify(vm, message, duration = 1000) {
  const msg = String(message || "");
  setHint(vm, msg);
  try {
    prompt.showToast({
      message: msg,
      duration,
      success: () => {},
      fail: () => {},
      complete: () => {},
    });
  } catch (_) {}
}

function formatScanError(err) {
  const raw = err && err.message ? String(err.message) : "";
  const s = raw.toLowerCase();
  if (s.includes("timeout")) return "扫描超时，请先点表盘 Scan 再重试";
  if (s.includes("no_permission")) return "扫描失败：守护权限不足";
  if (s.includes("write failed") || s.includes("read failed")) return "扫描失败：IPC 文件异常";
  if (raw) return `扫描失败：${raw}`;
  return "扫描失败";
}

function normalizeAbsBase(p) {
  const s = String(p == null ? "" : p).trim();
  if (!s) return DEFAULT_QUICKAPP_ABS_ROOT;
  return s.endsWith("/") ? s : `${s}/`;
}

function shQuote(s) {
  return `"${String(s == null ? "" : s).replace(/"/g, '\\"')}"`;
}

function fileGetMeta(uri, timeoutMs = 800) {
  return new Promise((resolve) => {
    let done = false;
    const t = setTimeout(() => {
      if (done) return;
      done = true;
      resolve(null);
    }, timeoutMs);

    try {
      file.get({
        uri,
        recursive: false,
        success: (data) => {
          if (done) return;
          done = true;
          clearTimeout(t);
          resolve(data || null);
        },
        fail: () => {
          if (done) return;
          done = true;
          clearTimeout(t);
          resolve(null);
        },
        complete: () => {},
      });
    } catch (_) {
      if (done) return;
      done = true;
      clearTimeout(t);
      resolve(null);
    }
  });
}

function parseIcon(raw) {
  if (typeof raw !== "string") return null;
  let s = raw.trim();
  if (!s) return null;

  if (s.startsWith("internal://files/")) {
    s = s.slice("internal://files/".length);
  }

  if (s.startsWith("/")) {
    const isSystemAbs =
      s.startsWith("/data/") ||
      s.startsWith("/tmp/") ||
      s.startsWith("/proc/") ||
      s.startsWith("/dev/") ||
      s.startsWith("/system/");
    if (isSystemAbs) {
      const fileName = s.split("/").pop();
      if (!fileName) return null;
      return { abs: s, rel: "", fileName };
    }
    s = s.replace(/^\/+/, "");
  }

  s = s.replace(/^\/+/, "");
  if (!s || s.includes("..")) return null;
  const fileName = s.split("/").pop();
  if (!fileName) return null;
  return { abs: "", rel: s, fileName };
}

export default createPage({
  data: {
    permList: [],
    allowlist: [],
    policies: {},
    stats: {},
    appMeta: {},
    selfAppId: "",
    quickappAbsRoot: DEFAULT_QUICKAPP_ABS_ROOT,
    adminFilesDirAbs: DEFAULT_ADMIN_FILES_DIR,
    scanHint: "等待扫描...",
    isLoading: false,
    isUpdating: false,
  },

  normalizeRemoteMeta(rawMeta) {
    const out = {};
    const m = rawMeta && typeof rawMeta === "object" ? rawMeta : {};
    Object.keys(m).forEach((appId) => {
      const it = m[appId] && typeof m[appId] === "object" ? m[appId] : {};
      const name = it && it.name ? String(it.name) : "";
      const iconRaw = it && it.icon ? String(it.icon) : "";
      out[appId] = { name, icon: parseIcon(iconRaw) };
    });
    return out;
  },

  async onShow() {
    if (Array.isArray(this.permList) && this.permList.length) {
      this.scanHint = `已加载 ${this.permList.length} 个应用，点扫描可刷新`;
      return;
    }
    this.scanHint = "点击扫描按钮开始";
  },

  async onClickScan() {
    if (this.isLoading) return;
    await this.refresh();
  },

  getPolicyFor(appId) {
    const info = this.policies && this.policies[appId];
    const p = info && info.policy;
    if (p === "allow" || p === "deny" || p === "ask" || p === "allow_once") return p;
    return "ask";
  },

  async getSelfAppId() {
    if (this.selfAppId) return this.selfAppId;
    const pkg = await new Promise((resolve) => {
      let done = false;
      const finish = (v) => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        resolve(v || "");
      };
      const timer = setTimeout(() => {
        finish(DEFAULT_ADMIN_APP_ID);
      }, 900);
      try {
        app.getInfo({
          success: (info) => finish((info && (info.packageName || info.package)) || DEFAULT_ADMIN_APP_ID),
          fail: () => finish(DEFAULT_ADMIN_APP_ID),
        });
      } catch (_) {
        finish(DEFAULT_ADMIN_APP_ID);
      }
    });
    this.selfAppId = pkg || DEFAULT_ADMIN_APP_ID;
    return this.selfAppId;
  },

  async tryLoadAppsMeta() {
    try {
      const res = await suIpc.exec("cat /data/apps.json", { sync: true, timeoutMs: 1500 });
      if (!res || res.exitCode !== 0 || !res.output) return {};
      const obj = JSON.parse(res.output);
      const list = obj && obj.InstalledApps;
      if (!Array.isArray(list)) return {};

      const meta = {};
      list.forEach((it) => {
        const id = it && it.package;
        if (!id) return;
        const names = it.names;
        const name =
          Array.isArray(names) && names[0] && names[0].value ? String(names[0].value) : "";
        const icon = parseIcon(it && it.icon);
        meta[id] = { name, icon };
      });
      return meta;
    } catch (_) {
      return {};
    }
  },

  async prepareIcons(appIds, meta, selfId, quickappAbsRoot, adminFilesDirAbs) {
    if (!Array.isArray(appIds) || !appIds.length) return {};

    const rootAbs = normalizeAbsBase(quickappAbsRoot);
    const adminAbs = normalizeAbsBase(adminFilesDirAbs);
    const baseDestAbs = `${adminAbs}perm_icons`;
    const lines = [`mkdir -p ${shQuote(baseDestAbs)}`];

    const iconMap = {};
    for (let i = 0; i < appIds.length; i++) {
      const appId = appIds[i];
      if (!appId) continue;
      const m = meta && meta[appId] ? meta[appId] : null;
      const icon = m && m.icon ? m.icon : null;
      if (!icon || !icon.fileName) continue;

      iconMap[appId] = icon.fileName;
      const srcAbs = icon.abs ? icon.abs : `${rootAbs}${appId}/${icon.rel}`;

      const destDirAbs = `${baseDestAbs}/${appId}`;
      const destAbs = `${destDirAbs}/${icon.fileName}`;

      lines.push(`mkdir -p ${shQuote(destDirAbs)}`);
      lines.push(`cp ${shQuote(srcAbs)} ${shQuote(destAbs)}`);
    }

    if (lines.length <= 1) return iconMap;
    try {
      await suIpc.exec(lines.join("\n"), { sync: true, timeoutMs: 8000 });
    } catch (_) {}
    return iconMap;
  },

  async resolveIconUris(appIds, iconMap) {
    const out = {};
    if (!Array.isArray(appIds) || !appIds.length) return out;
    if (!iconMap || typeof iconMap !== "object") return out;
    const tasks = appIds.map(async (appId) => {
      const iconFile = appId && iconMap[appId] ? String(iconMap[appId]) : "";
      if (!appId || !iconFile) return;
      const uri = `internal://files/perm_icons/${appId}/${iconFile}`;
      const meta = await fileGetMeta(uri, 800);
      if (meta && meta.uri) out[appId] = String(meta.uri);
    });
    await Promise.all(tasks);

    return out;
  },

  async refresh() {
    if (this.isLoading) return;
    this.isLoading = true;
    try {
      setHint(this, "读取应用信息...");
      const selfId = await this.getSelfAppId();

      setHint(this, "读取权限配置...");
      const [env, allowlist, policies, logs] = await Promise.all([
        withTimeout(suIpc.getEnv().catch(() => ({})), 2200, "读取环境超时").catch(() => ({})),
        withTimeout(suIpc.getAllowlist(), 2200, "读取白名单超时").catch(() => []),
        withTimeout(suIpc.getPolicies(), 2200, "读取策略超时").catch(() => ({})),
        withTimeout(suIpc.getLogs(), 2200, "读取日志超时").catch(() => ({})),
      ]);
      let scan = { apps: [], meta: {} };
      try {
        setHint(this, "扫描应用列表...");
        scan = await withTimeout(suIpc.scanAppsInfo(), 7000, "扫描超时");
      } catch (scanErr) {
        this.permList = [];
        notify(this, formatScanError(scanErr), 1200);
        return;
      }

      const root = env && (env.quickapp_root || env.quickapp_base);
      const adminDir = env && env.admin_files_dir;
      const adminAppId = env && env.admin_app_id ? String(env.admin_app_id) : "";
      const effectiveAdminId = selfId || adminAppId || DEFAULT_ADMIN_APP_ID;
      this.quickappAbsRoot = normalizeAbsBase(root);
      this.adminFilesDirAbs = normalizeAbsBase(
        adminDir || `${this.quickappAbsRoot}${effectiveAdminId}`
      );

      const apps = scan && Array.isArray(scan.apps) ? scan.apps : [];
      const remoteMeta = scan && scan.meta ? scan.meta : {};
      const meta = this.normalizeRemoteMeta(remoteMeta);

      this.allowlist = Array.isArray(allowlist) ? allowlist : [];
      this.policies = policies || {};
      this.stats = logs && logs.stats ? logs.stats : {};
      this.appMeta = meta || {};

      const rawAppIds = Array.isArray(apps) ? apps : [];
      const appIds = rawAppIds.filter((id) => id && id !== selfId);
      if (!appIds.length) {
        this.permList = [];
        if (!rawAppIds.length) {
          notify(this, "扫描完成：未发现应用，请先点表盘 Scan", 1200);
        } else {
          notify(this, "扫描完成：仅发现授权管理自身包", 1000);
        }
        return;
      }
      setHint(this, "应用已扫描，加载图标...");
      const iconMap = await this.prepareIcons(
        appIds,
        this.appMeta,
        selfId,
        this.quickappAbsRoot,
        this.adminFilesDirAbs
      );
      const iconUris = await this.resolveIconUris(appIds, iconMap);

      const allowSet = new Set(this.allowlist || []);

      const list = appIds
        .map((appId) => {
          const st = this.stats && this.stats[appId] ? this.stats[appId] : {};
          const count = st && st.count != null ? String(st.count) : "0";
          const lastTs = st && st.last_ts != null ? Number(st.last_ts) : 0;
          const policy = this.getPolicyFor(appId);
          const isAllowed = allowSet.has(appId) && policy === "allow";
          const m = this.appMeta && this.appMeta[appId] ? this.appMeta[appId] : {};
          const title = m && m.name ? m.name : appId;
          const image = iconUris && iconUris[appId] ? iconUris[appId] : "/resources/image/perm.png";

          return {
            title,
            image,
            count,
            time: formatHhMmFromUnixSec(lastTs),
            index: appId,
            checked: isAllowed,
          };
        })
        .sort((a, b) => {
          if (a.checked !== b.checked) return a.checked ? -1 : 1;
          const ca = parseInt(a.count, 10) || 0;
          const cb = parseInt(b.count, 10) || 0;
          if (ca !== cb) return cb - ca;
          return String(a.index).localeCompare(String(b.index));
        });

      this.permList = list;
      notify(this, `扫描完成：${list.length} 个应用`, 900);
    } catch (e) {
      notify(this, e && e.message ? e.message : "加载失败", 900);
    } finally {
      this.isLoading = false;
    }
  },

  async onSwitchChange(evt) {
    if (this.isUpdating || this.isLoading) return;
    const appId = evt && evt.detail ? evt.detail.index : "";
    const enabled = !!(evt && evt.detail && evt.detail.switchValue);
    if (!appId) return;

    this.isUpdating = true;
    const prevAllow = Array.isArray(this.allowlist) ? this.allowlist.slice() : [];
    const prevPolicies = this.policies && typeof this.policies === "object"
      ? Object.assign({}, this.policies)
      : {};
    const prevList = Array.isArray(this.permList)
      ? this.permList.map((it) => (it && typeof it === "object" ? Object.assign({}, it) : it))
      : [];

    const sortList = (list) =>
      list.sort((a, b) => {
        if (!!a.checked !== !!b.checked) return a.checked ? -1 : 1;
        const ca = parseInt(a && a.count, 10) || 0;
        const cb = parseInt(b && b.count, 10) || 0;
        if (ca !== cb) return cb - ca;
        return String(a && a.index).localeCompare(String(b && b.index));
      });

    const applyLocalSwitch = (checked) => {
      const allowSet = new Set(Array.isArray(this.allowlist) ? this.allowlist : []);
      if (checked) allowSet.add(appId);
      else allowSet.delete(appId);
      this.allowlist = Array.from(allowSet);

      const nextPolicies =
        this.policies && typeof this.policies === "object" ? Object.assign({}, this.policies) : {};
      nextPolicies[appId] = Object.assign({}, nextPolicies[appId] || {}, {
        policy: checked ? "allow" : "deny",
      });
      this.policies = nextPolicies;

      const nextList = Array.isArray(this.permList)
        ? this.permList.map((it) => {
            if (!it || typeof it !== "object") return it;
            if (String(it.index) !== String(appId)) return it;
            return Object.assign({}, it, { checked: !!checked });
          })
        : [];
      this.permList = sortList(nextList);
    };

    try {
      const currentAllow = Array.isArray(this.allowlist) ? this.allowlist.slice() : [];
      const allowSet = new Set(currentAllow);

      if (enabled) {
        allowSet.add(appId);
        await suIpc.setAllowlist(Array.from(allowSet));
        await suIpc.setPolicy(appId, "allow");
      } else {
        await suIpc.setPolicy(appId, "deny");
        allowSet.delete(appId);
        await suIpc.setAllowlist(Array.from(allowSet));
      }

      applyLocalSwitch(enabled);
      notify(this, enabled ? "已授权" : "已取消授权", 700);
    } catch (e) {
      this.allowlist = prevAllow;
      this.policies = prevPolicies;
      this.permList = prevList;
      notify(this, e && e.message ? e.message : "操作失败", 900);
    } finally {
      this.isUpdating = false;
    }
  },
});
