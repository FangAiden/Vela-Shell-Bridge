import prompt from "@system.prompt";
import suIpc from "../../services/su-daemon/index.js";
import { createPage } from "../../app/page.js";

function shellEscape(text) {
  const s = String(text == null ? "" : text);
  if (!s) return "''";
  return `'${s.replace(/'/g, "'\\''")}'`;
}

function normalizePath(p) {
  let s = String(p == null ? "" : p).trim();
  if (!s) return "/";
  if (!s.startsWith("/")) s = `/${s}`;
  s = s.replace(/\/+/g, "/");
  if (s.length > 1) s = s.replace(/\/+$/, "");
  return s;
}

function joinPath(base, name) {
  const b = normalizePath(base);
  if (b === "/") return `/${name}`;
  return `${b}/${name}`;
}

function formatSize(bytes) {
  const n = Number(bytes);
  if (!isFinite(n) || n < 0) return "—";
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  if (n < 1024 * 1024 * 1024) return `${(n / (1024 * 1024)).toFixed(1)} MB`;
  return `${(n / (1024 * 1024 * 1024)).toFixed(1)} GB`;
}

/**
 * Check if a path is a protected system path that should not be deleted.
 */
function isProtectedPath(path) {
  const normalized = normalizePath(path);
  const protectedPaths = [
    "/",
    "/data",
    "/data/quickapp",
    "/data/files",
    "/system",
    "/etc",
    "/proc",
    "/tmp",
    "/resource",
  ];
  return protectedPaths.includes(normalized);
}

function parseLsOutput(raw, basePath) {
  const lines = String(raw == null ? "" : raw)
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);

  const out = [];
  lines.forEach((line) => {
    if (line.startsWith("total")) return;
    if (line.endsWith(":")) return;

    const parts = line.split(/\s+/);
    let perm = "";
    let size = NaN;
    let namePart = "";

    if (parts.length >= 9 && /^[dl-]/.test(parts[0])) {
      perm = parts[0] || "";
      size = parseInt(parts[4], 10);
      namePart = parts.slice(8).join(" ") || parts[parts.length - 1] || "";
    } else if (parts.length >= 3 && /^[dl-]/.test(parts[0])) {
      perm = parts[0] || "";
      size = parseInt(parts[1], 10);
      namePart = parts.slice(2).join(" ") || parts[parts.length - 1] || "";
    } else {
      namePart = line;
      perm = namePart.endsWith("/") ? "d" : "-";
    }

    if (!namePart || namePart === "." || namePart === "..") return;
    let name = namePart;
    if (name.includes(" -> ")) name = name.split(" -> ")[0];
    if (name.endsWith("/")) name = name.slice(0, -1);
    if (!name) return;

    const isDir = perm[0] === "d" || namePart.endsWith("/");
    const isLink = perm[0] === "l";
    out.push({
      title: name,
      image: isDir ? "/resources/image/folder.png" : "/resources/image/file.png",
      type: isDir ? "目录" : isLink ? "链接" : "文件",
      info: isFinite(size) ? formatSize(size) : "—",
      index: "0",
      fullPath: joinPath(basePath, name),
      isDir,
    });
  });

  out.sort((a, b) => {
    if (a.isDir !== b.isDir) return a.isDir ? -1 : 1;
    return a.title.localeCompare(b.title);
  });
  out.forEach((item, idx) => {
    item.index = String(idx);
  });
  return out;
}

function findEntry(list, index, title) {
  const idx = String(index == null ? "" : index);
  if (idx !== "") {
    const hit = (Array.isArray(list) ? list : []).find((it) => String(it.index) === idx);
    if (hit) return hit;
  }
  const name = String(title == null ? "" : title);
  return (Array.isArray(list) ? list : []).find((it) => it && it.title === name) || null;
}

export default createPage({
  data: {
    currentPath: "/data/quickapp",
    fileList: [],
    clipboard: null,
    clipboardMode: "",
    isBusy: false,

    showIme: false,
    imeMode: "",
    imeTitle: "",
    imeInput: "",
    imeTarget: null,
    imeKeyboardType: "QWERTY",
    imeVibrateMode: "short",
    imeScreenType: "auto",
    imeMaxLength: 5,

    sticky: false,
    headerHeight: 140,

    showMenu: false,
    menuTarget: null,
    menuTargetEntry: null,

    showConfirm: false,
    showDetail: false,
    detailEntry: null,
    detailAnim: "",

    menuAnim: "",
    confirmAnim: "",
  },

  onShow() {
    this.refreshList(this.currentPath);
  },

  onBackPress() {
    if (this.showIme) {
      this.closeIme();
      return true;
    }
    if (this.showDetail) {
      this.closeDetail();
      return true;
    }
    if (this.showConfirm) {
      this.cancelDelete();
      return true;
    }
    if (this.showMenu) {
      this.closeMenu();
      return true;
    }

    return false;
  },

  onScroll(e) {
    const y = e.scrollY || 0;
    const shouldSticky = y >= this.headerHeight;
    if (shouldSticky !== this.sticky) {
      this.sticky = shouldSticky;
    }
  },

  onButtonClick(evt) {
    const hit = findEntry(this.fileList, evt.detail.index, evt.detail.title);
    if (!hit) return;
    if (hit.isDir) {
      this.refreshList(hit.fullPath);
    } else {
      this.openDetail(hit);
    }
  },

  previous() {
    const cur = normalizePath(this.currentPath);
    if (cur === "/") {
      prompt.showToast({ message: "已是根目录", duration: 600 });
      return;
    }
    const trimmed = cur.replace(/\/+$/, "");
    const lastIdx = trimmed.lastIndexOf("/");
    const parent = lastIdx <= 0 ? "/" : trimmed.slice(0, lastIdx);
    this.refreshList(parent);
  },

  navigate() {
    this.openIme("path", this.currentPath, null, "输入路径");
  },

  openIme(mode, value, target, title) {
    this.imeMode = mode || "";
    this.imeInput = String(value == null ? "" : value);
    this.imeTarget = target || null;
    this.imeTitle = title || "输入";
    this.showIme = true;
  },

  closeIme() {
    this.showIme = false;
    this.imeMode = "";
    this.imeTitle = "";
    this.imeInput = "";
    this.imeTarget = null;
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
    const text = String(this.imeInput == null ? "" : this.imeInput);
    const trimmed = text.trim();
    const mode = this.imeMode;
    const target = this.imeTarget;
    this.closeIme();
    if (!trimmed) return;

    if (mode === "path") {
      this.refreshList(trimmed);
    } else if (mode === "rename" && target) {
      this.doRename(target, trimmed);
    }
  },

  async refreshList(path) {
    if (this.isBusy) return;
    this.isBusy = true;
    const nextPath = normalizePath(path || this.currentPath);
    try {
      const res = await suIpc.exec(`ls -l ${shellEscape(nextPath)}`, { sync: true, timeoutMs: 4000 });
      const output = res && res.output != null ? String(res.output) : "";
      let list = parseLsOutput(output, nextPath);

      if (!list.length) {
        const res2 = await suIpc.exec(`ls ${shellEscape(nextPath)}`, { sync: true, timeoutMs: 3500 });
        const output2 = res2 && res2.output != null ? String(res2.output) : "";
        list = parseLsOutput(output2, nextPath);
      }

      this.fileList = list;
      this.currentPath = nextPath;
    } catch (e) {
      prompt.showToast({
        message: `读取失败：${e && e.message ? e.message : "unknown"}`,
        duration: 900,
      });
    } finally {
      this.isBusy = false;
    }
  },

  async runShell(cmd, okMessage) {
    if (this.isBusy) return false;
    this.isBusy = true;
    try {
      await suIpc.exec(cmd, { sync: true, timeoutMs: 6000 });
      if (okMessage) {
        prompt.showToast({ message: okMessage, duration: 700 });
      }
      return true;
    } catch (e) {
      prompt.showToast({
        message: e && e.message ? e.message : "执行失败",
        duration: 900,
      });
      return false;
    } finally {
      this.isBusy = false;
    }
  },

  doRename(entry, nextName) {
    const name = String(nextName == null ? "" : nextName).trim();
    if (!entry || !name) return;
    if (name.includes("/")) {
      prompt.showToast({ message: "名称不能包含 /", duration: 700 });
      return;
    }
    if (name === entry.title) return;
    const destPath = joinPath(this.currentPath, name);
    const cmd = `mv ${shellEscape(entry.fullPath)} ${shellEscape(destPath)}`;
    this.runShell(cmd, `已重命名为：${name}`).then((ok) => {
      if (ok) this.refreshList(this.currentPath);
    });
  },

  onLongPress(evt) {
    const hit = findEntry(this.fileList, evt.detail.index, evt.detail.title);
    if (!hit) return;
    this.menuTargetEntry = hit;
    this.menuTarget = hit.title;
    this.showMenu = true;

    this.menuAnim = "";
    setTimeout(() => {
      this.menuAnim = "modal-enter";
    }, 0);
  },

  closeMenu() {
    this.menuAnim = "modal-leave";
    setTimeout(() => {
      this.showMenu = false;
      this.menuTarget = null;
      this.menuTargetEntry = null;
    }, 180);
  },

  copyTarget() {
    const entry = this.menuTargetEntry;
    if (entry) {
      this.clipboard = entry;
      this.clipboardMode = "copy";
      prompt.showToast({ message: `已复制：${entry.title}`, duration: 700 });
    }
    this.closeMenu();
  },

  pasteTarget() {
    const entry = this.clipboard;
    if (!entry || !entry.fullPath) {
      prompt.showToast({ message: "剪贴板为空", duration: 650 });
      this.closeMenu();
      return;
    }
    const target = this.menuTargetEntry;
    const destDir = target && target.isDir ? target.fullPath : this.currentPath;
    const dest = joinPath(destDir, entry.title);
    if (dest === entry.fullPath) {
      prompt.showToast({ message: "已在当前目录", duration: 650 });
      this.closeMenu();
      return;
    }
    const isDir = !!entry.isDir;
    const cmd =
      this.clipboardMode === "cut"
        ? `mv ${shellEscape(entry.fullPath)} ${shellEscape(dest)}`
        : isDir
          ? `cp -r ${shellEscape(entry.fullPath)} ${shellEscape(dest)}`
          : `cp ${shellEscape(entry.fullPath)} ${shellEscape(dest)}`;
    this.runShell(cmd, `已粘贴到：${destDir}`).then((ok) => {
      if (ok && this.clipboardMode === "cut") {
        this.clipboard = null;
        this.clipboardMode = "";
      }
      if (ok) this.refreshList(this.currentPath);
    });
    this.closeMenu();
  },

  cutTarget() {
    const entry = this.menuTargetEntry;
    if (entry) {
      this.clipboard = entry;
      this.clipboardMode = "cut";
      prompt.showToast({ message: `已剪切：${entry.title}`, duration: 700 });
    }
    this.closeMenu();
  },

  renameTarget() {
    const entry = this.menuTargetEntry;
    if (entry) {
      this.openIme("rename", entry.title, entry, "重命名");
    }
    this.closeMenu();
  },

  deleteTarget() {
    if (!this.menuTargetEntry) return;

    this.showConfirm = true;
    this.confirmAnim = "";
    setTimeout(() => {
      this.confirmAnim = "modal-enter";
    }, 0);
  },

  confirmDelete() {
    const entry = this.menuTargetEntry;
    if (!entry) return;

    // Protect critical system paths from accidental deletion
    if (isProtectedPath(entry.fullPath)) {
      prompt.showToast({ message: "无法删除系统关键路径", duration: 1200 });
      this.confirmAnim = "modal-leave";
      setTimeout(() => {
        this.showConfirm = false;
      }, 180);
      this.closeMenu();
      return;
    }

    const cmd = `rm -rf ${shellEscape(entry.fullPath)}`;
    this.runShell(cmd, `已删除：${entry.title}`).then((ok) => {
      if (ok) this.refreshList(this.currentPath);
    });

    this.confirmAnim = "modal-leave";
    setTimeout(() => {
      this.showConfirm = false;
    }, 180);
    this.closeMenu();
  },

  cancelDelete() {
    this.confirmAnim = "modal-leave";
    setTimeout(() => {
      this.showConfirm = false;
    }, 180);
    this.closeMenu();
  },

  detailTarget() {
    const entry = this.menuTargetEntry;
    if (entry) {
      this.openDetail(entry);
    }
    this.closeMenu();
  },

  openDetail(entry) {
    this.detailEntry = entry || null;
    this.showDetail = true;
    this.detailAnim = "";
    setTimeout(() => {
      this.detailAnim = "modal-enter";
    }, 0);
  },

  closeDetail() {
    this.detailAnim = "modal-leave";
    setTimeout(() => {
      this.showDetail = false;
      this.detailEntry = null;
    }, 180);
  },
}, {
  transitions() {
    return {
      onLoaded: (local) => {
        const ime = local && local.ime ? local.ime : {};
        this.imeKeyboardType = ime.keyboardType || "QWERTY";
        this.imeVibrateMode = ime.vibrateMode != null ? ime.vibrateMode : "short";
        this.imeScreenType = ime.screenType || "auto";
        this.imeMaxLength = ime.maxLength != null ? ime.maxLength : 5;
      },
    };
  },
});
