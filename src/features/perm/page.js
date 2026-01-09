import prompt from "@system.prompt";
import app from "@system.app";
import file from "@system.file";
import suIpc from "../../services/su-daemon/index.js";
import { createPage } from "../../app/page.js";
import { formatHhMmFromUnixSec } from "../../shared/utils/time.js";

const DEFAULT_QUICKAPP_ABS_ROOT = "/data/files/";
const DEFAULT_ADMIN_FILES_DIR = "/data/files/com.lua.dev.template/";

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
      try {
        app.getInfo({
          success: (info) => resolve((info && (info.packageName || info.package)) || ""),
          fail: () => resolve(""),
        });
      } catch (_) {
        resolve("");
      }
    });
    this.selfAppId = pkg || "";
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

    for (let i = 0; i < appIds.length; i++) {
      const appId = appIds[i];
      const iconFile = appId && iconMap[appId] ? String(iconMap[appId]) : "";
      if (!appId || !iconFile) continue;
      const uri = `internal://files/perm_icons/${appId}/${iconFile}`;
      const meta = await fileGetMeta(uri, 800);
      if (meta && meta.uri) out[appId] = String(meta.uri);
    }

    return out;
  },

  async refresh() {
    if (this.isLoading) return;
    this.isLoading = true;
    try {
      const selfId = await this.getSelfAppId();

      const [env, scan, allowlist, policies, logs] = await Promise.all([
        suIpc.getEnv().catch(() => ({})),
        suIpc.scanAppsInfo(),
        suIpc.getAllowlist(),
        suIpc.getPolicies(),
        suIpc.getLogs(),
      ]);

      const root = env && (env.quickapp_root || env.quickapp_base);
      const adminDir = env && env.admin_files_dir;
      this.quickappAbsRoot = normalizeAbsBase(root);
      this.adminFilesDirAbs = normalizeAbsBase(
        adminDir || (selfId ? `${this.quickappAbsRoot}${selfId}` : DEFAULT_ADMIN_FILES_DIR)
      );

      const apps = scan && Array.isArray(scan.apps) ? scan.apps : [];
      const remoteMeta = scan && scan.meta ? scan.meta : {};
      const meta = this.normalizeRemoteMeta(remoteMeta);

      this.allowlist = Array.isArray(allowlist) ? allowlist : [];
      this.policies = policies || {};
      this.stats = logs && logs.stats ? logs.stats : {};
      this.appMeta = meta || {};

      const appIds = (Array.isArray(apps) ? apps : []).filter((id) => id && id !== selfId);
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
    } catch (e) {
      prompt.showToast({
        message: e && e.message ? e.message : "加载失败",
        duration: 900,
      });
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

      prompt.showToast({
        message: enabled ? "已授权" : "已取消授权",
        duration: 700,
      });

      await this.refresh();
    } catch (e) {
      prompt.showToast({
        message: e && e.message ? e.message : "操作失败",
        duration: 900,
      });
      await this.refresh();
    } finally {
      this.isUpdating = false;
    }
  },
});
