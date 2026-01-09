import suIpc from "../../services/su-daemon/index.js";
import { clamp, extractFirstNumber, formatBytes, safeTrim } from "./about-utils.js";
import { getJson, setJson } from "./about-cache.js";

const suExec = suIpc.exec;

const CACHE_VERSION = 1;
const CACHE_KEY_PREFIX = `vela.about.shell.cache.v${CACHE_VERSION}:`;

function getDeviceKey(ctx) {
  const id = safeTrim(ctx && ctx.deviceId);
  if (id) return id;
  const serial = safeTrim(ctx && ctx.serial);
  if (serial) return serial;
  const model = safeTrim(ctx && ctx.model);
  if (model) return model;
  return "UNKNOWN";
}

function makeCacheKey(deviceKey) {
  const k = safeTrim(deviceKey) || "UNKNOWN";
  return `${CACHE_KEY_PREFIX}${k}`;
}

function isValidCache(obj) {
  return !!(obj && typeof obj === "object" && obj.v === CACHE_VERSION && obj.snapshot && typeof obj.snapshot === "object");
}

async function loadCache(deviceKey) {
  try {
    const obj = await getJson(makeCacheKey(deviceKey));
    return isValidCache(obj) ? obj : null;
  } catch (_) {
    return null;
  }
}

async function saveCache(deviceKey, snapshot) {
  const key = makeCacheKey(deviceKey);
  const payload = {
    v: CACHE_VERSION,
    deviceKey: safeTrim(deviceKey) || "UNKNOWN",
    ts: Date.now(),
    snapshot
  };
  try {
    await setJson(key, payload);
  } catch (_) {}
}

function applySnapshot(ctx, snapshot) {
  if (!ctx || !snapshot || typeof snapshot !== "object") return;
  const s = snapshot.static || {};
  const d = snapshot.dynamic || {};

  if (s.firmware != null) ctx.firmware = String(s.firmware);
  if (s.kernelText != null) ctx.kernelText = String(s.kernelText);
  if (s.mountText != null) ctx.mountText = String(s.mountText);
  if (s.mountRawText != null) ctx.mountRawText = String(s.mountRawText);
  if (s.cpuModelText != null) ctx.cpuModelText = String(s.cpuModelText);
  if (s.cpuMetaText != null) ctx.cpuMetaText = String(s.cpuMetaText);
  if (s.cpuInfoRawText != null) ctx.cpuInfoRawText = String(s.cpuInfoRawText);
  if (Array.isArray(s.shellCaps)) ctx.shellCaps = s.shellCaps;
  if (s.shellCapsText != null) ctx.shellCapsText = String(s.shellCapsText);

  if (d.uptimeText != null) ctx.uptimeText = String(d.uptimeText);
  if (d.ipText != null) ctx.ipText = String(d.ipText);
  if (d.ipRawText != null) ctx.ipRawText = String(d.ipRawText);
  if (d.processText != null) ctx.processText = String(d.processText);
  if (d.memUsedText != null) ctx.memUsedText = String(d.memUsedText);
  if (d.memTotalText != null) ctx.memTotalText = String(d.memTotalText);
  if (d.memSubText != null) ctx.memSubText = String(d.memSubText);
  if (typeof d.memUsedPercent === "number") ctx.memUsedPercent = d.memUsedPercent;
  if (d.dataUsedText != null) ctx.dataUsedText = String(d.dataUsedText);
  if (d.dataTotalText != null) ctx.dataTotalText = String(d.dataTotalText);
  if (d.dataSubText != null) ctx.dataSubText = String(d.dataSubText);
  if (typeof d.dataUsedPercent === "number") ctx.dataUsedPercent = d.dataUsedPercent;
}

function buildSnapshot(ctx, staticOk, dynamicOk) {
  return {
    staticOk: !!staticOk,
    dynamicOk: !!dynamicOk,
    static: {
      firmware: ctx.firmware,
      kernelText: ctx.kernelText,
      mountText: ctx.mountText,
      mountRawText: ctx.mountRawText,
      cpuModelText: ctx.cpuModelText,
      cpuMetaText: ctx.cpuMetaText,
      cpuInfoRawText: ctx.cpuInfoRawText,
      shellCaps: ctx.shellCaps,
      shellCapsText: ctx.shellCapsText
    },
    dynamic: {
      uptimeText: ctx.uptimeText,
      ipText: ctx.ipText,
      ipRawText: ctx.ipRawText,
      processText: ctx.processText,
      memUsedText: ctx.memUsedText,
      memTotalText: ctx.memTotalText,
      memUsedPercent: ctx.memUsedPercent,
      memSubText: ctx.memSubText,
      dataUsedText: ctx.dataUsedText,
      dataTotalText: ctx.dataTotalText,
      dataUsedPercent: ctx.dataUsedPercent,
      dataSubText: ctx.dataSubText
    }
  };
}

function formatMountSummary(text) {
  const lines = safeTrim(text).split(/\r?\n/).map((s) => s.trim()).filter(Boolean);
  const mapped = lines.map((l) => {
    const m = l.match(/^(\S+)\s+type\s+(\S+)/i);
    if (m) return `${m[1]} (${m[2]})`;
    return l;
  });
  const maxLines = 6;
  if (mapped.length > maxLines) {
    return mapped
      .slice(0, maxLines)
      .concat([`… (+${mapped.length - maxLines})`])
      .join("\n");
  }
  return mapped.join("\n");
}

function formatIfconfigSummary(text) {
  const lines = safeTrim(text).split(/\r?\n/);
  const ifaces = [];
  let cur = null;

  const pushCur = () => {
    if (!cur) return;
    ifaces.push(cur);
    cur = null;
  };

  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i] || "";
    const isHeader = raw && raw[0] !== " " && raw[0] !== "\t" && /\bLink encap\b/.test(raw);
    if (isHeader) {
      pushCur();
      const name = (raw.match(/^(\S+)/) || [])[1] || "";
      cur = { name, ipv4: "", mac: "" };
      const mac = (raw.match(/\bHWaddr\s+([0-9a-f:]+)/i) || [])[1] || "";
      if (mac) cur.mac = mac.toLowerCase();
      continue;
    }

    if (!cur) continue;
    const ip = (raw.match(/\binet addr:([0-9.]+)/i) || [])[1] || "";
    if (ip) cur.ipv4 = ip;
  }
  pushCur();

  if (!ifaces.length) return "";

  const order = ["wlan0", "eth0", "en0", "lo"];
  ifaces.sort((a, b) => {
    const ai = order.indexOf(a.name);
    const bi = order.indexOf(b.name);
    if (ai === -1 && bi === -1) return a.name.localeCompare(b.name);
    if (ai === -1) return 1;
    if (bi === -1) return -1;
    return ai - bi;
  });

  const max = 3;
  const show = ifaces.slice(0, max);
  const rows = show.map((it) => {
    const parts = [];
    if (it.ipv4) parts.push(it.ipv4);
    if (it.mac) parts.push(it.mac);
    return `${it.name}: ${parts.join("  ") || "—"}`;
  });

  if (ifaces.length > max) rows.push(`… (+${ifaces.length - max})`);
  return rows.join("\n");
}

function countPsTasks(text) {
  const lines = safeTrim(text).split(/\r?\n/).map((s) => s.trim()).filter(Boolean);
  if (lines.length <= 1) return null;
  return Math.max(0, lines.length - 1);
}

async function fetchStaticInfo(ctx, run) {
  let ok = false;

  try {
    const verRaw = await run("cat /proc/version", 2500);
    if (verRaw) {
      const parts = verRaw.split(/\s+/);
      if (parts.length >= 8 && parts[0].toLowerCase() === "nuttx" && parts[1].toLowerCase() === "version") {
        const v = parts[2];
        const build = parts.slice(4, 8).join(" ");
        const board = parts.slice(8).join(" ");
        ctx.firmware = board ? `NuttX ${v} (${build}) ${board}` : `NuttX ${v} (${build})`;
      } else {
        ctx.firmware = verRaw;
      }
      ok = true;
    }
  } catch (_) {}

  try {
    const unameRaw = await run("uname -a", 2000);
    if (unameRaw) {
      ctx.kernelText = unameRaw;
      ok = true;
    }
  } catch (_) {}

  try {
    const cpuRaw = await run("cat /proc/cpuinfo", 2500);
    if (cpuRaw) {
      ctx.cpuInfoRawText = cpuRaw;
      const model = (cpuRaw.match(/model name\s*:\s*(.+)/i) || [])[1] || "";
      const arch = (cpuRaw.match(/CPU architecture\s*:\s*(.+)/i) || [])[1] || "";
      const cores = (cpuRaw.match(/^processor\s*:/gim) || []).length || 0;
      const cpuMhz = safeTrim((cpuRaw.match(/cpu MHz\s*:\s*(.+)/i) || [])[1] || "");
      const title = safeTrim(model) || "—";
      const suffix = [];
      if (cores) suffix.push(`${cores}核`);
      if (arch) suffix.push(`arch ${safeTrim(arch)}`);
      if (cpuMhz && cpuMhz !== "0.000") suffix.push(`${cpuMhz} MHz`);
      ctx.cpuModelText = title;
      ctx.cpuMetaText = suffix.join(" · ");
      ok = true;
    }
  } catch (_) {}

  try {
    const mountRaw = await run("mount", 2500);
    if (mountRaw) {
      ctx.mountRawText = mountRaw;
      ctx.mountText = formatMountSummary(mountRaw);
      ok = true;
    }
  } catch (_) {}

  // Shell 能力（只展示结论，不展示探测日志）
  let supportsDollarDollar = false;
  try {
    const dd = await run("echo __PPID__; echo $$", 1200);
    const ddLines = safeTrim(dd).split(/\r?\n/).map((s) => s.trim()).filter(Boolean);
    const ddIdx = ddLines.indexOf("__PPID__");
    const ddVal = ddIdx >= 0 && ddIdx + 1 < ddLines.length ? ddLines[ddIdx + 1] : "";
    supportsDollarDollar = !!extractFirstNumber(ddVal);
  } catch (_) {
    supportsDollarDollar = false;
  }

  let supportsBg = false;
  try {
    const bgOut = await run("sleep 1 &; echo __AFTER__", 1500);
    supportsBg = safeTrim(bgOut).indexOf("__AFTER__") >= 0;
  } catch (_) {
    supportsBg = false;
  }

  let supportsDollarBang = false;
  try {
    const bangOut = await run("sleep 1 &; echo __PID__; echo $!", 1500);
    const bangLines = safeTrim(bangOut).split(/\r?\n/).map((s) => s.trim()).filter(Boolean);
    const pidIdx = bangLines.indexOf("__PID__");
    const pidVal = pidIdx >= 0 && pidIdx + 1 < bangLines.length ? bangLines[pidIdx + 1] : "";
    supportsDollarBang = !!extractFirstNumber(pidVal);
  } catch (_) {
    supportsDollarBang = false;
  }

  let supportsRedirect = false;
  try {
    await run("echo PROBE_TXT > /tmp/__vela_probe.txt", 1500);
    const r = await run("cat /tmp/__vela_probe.txt", 1500);
    supportsRedirect = safeTrim(r).indexOf("PROBE_TXT") >= 0;
  } catch (_) {
    supportsRedirect = false;
  }
  try {
    await run("rm /tmp/__vela_probe.txt", 1500);
  } catch (_) {}

  let supportsPipe = false;
  try {
    const out = await run("echo __PIPE__ | cat", 1500);
    const lines = safeTrim(out).split(/\r?\n/).map((s) => s.trim()).filter(Boolean);
    supportsPipe = lines.indexOf("__PIPE__") >= 0 && !lines.some((l) => l.indexOf("|") >= 0);
  } catch (_) {
    supportsPipe = false;
  }

  let supportsAndAnd = false;
  try {
    const out = await run("echo __A__ && echo __B__", 1500);
    const lines = safeTrim(out).split(/\r?\n/).map((s) => s.trim()).filter(Boolean);
    supportsAndAnd =
      lines.indexOf("__A__") >= 0 && lines.indexOf("__B__") >= 0 && !lines.some((l) => l.indexOf("&&") >= 0);
  } catch (_) {
    supportsAndAnd = false;
  }

  let supportsCmdSub = false;
  try {
    const out = await run("echo __SUB_START__ $(echo __SUB_INNER__) __SUB_END__", 1500);
    const flat = safeTrim(out);
    supportsCmdSub =
      flat.indexOf("__SUB_START__") >= 0
      && flat.indexOf("__SUB_INNER__") >= 0
      && flat.indexOf("__SUB_END__") >= 0
      && flat.indexOf(")") < 0
      && flat.indexOf("$(") < 0;
  } catch (_) {
    supportsCmdSub = false;
  }

  const caps = [
    { key: "bg", name: "后台(&)", ok: supportsBg },
    { key: "bang", name: "$!", ok: supportsDollarBang },
    { key: "dd", name: "$$", ok: supportsDollarDollar },
    { key: "redir", name: "重定向(>)", ok: supportsRedirect },
    { key: "pipe", name: "管道(|)", ok: supportsPipe },
    { key: "andand", name: "条件(&&)", ok: supportsAndAnd },
    { key: "sub", name: "命令替换($(…))", ok: supportsCmdSub }
  ];
  ctx.shellCaps = caps;
  ctx.shellCapsText = caps.map((c) => `${c.name}:${c.ok ? "支持" : "不支持"}`).join("  ");
  ok = true;

  return ok;
}

async function fetchDynamicInfo(ctx, run) {
  let ok = false;

  try {
    const uptimeRaw = await run("uptime", 2500);
    const upm = safeTrim(uptimeRaw).match(/\bup\s+([^,]+)/);
    ctx.uptimeText = upm ? upm[1].trim() : uptimeRaw || "—";
    ok = true;
  } catch (_) {}

  try {
    const ifcfgRaw = await run("ifconfig", 3500);
    if (ifcfgRaw) {
      ctx.ipRawText = ifcfgRaw;
      ctx.ipText = formatIfconfigSummary(ifcfgRaw);
      ok = true;
    }
  } catch (_) {}

  try {
    const psRaw = await run("ps", 3500);
    const n = countPsTasks(psRaw);
    if (n != null) {
      ctx.processText = `${n} 个任务`;
      ok = true;
    }
  } catch (_) {}

  try {
    const memRaw = await run("cat /proc/meminfo", 2500);
    if (memRaw) {
      const lines = memRaw.split(/\r?\n/).map((s) => s.trim()).filter(Boolean);
      const dataLine = lines.length >= 2 ? lines[1] : "";
      const cols = dataLine.split(/\s+/);
      const total = parseFloat(cols[0]);
      let used = parseFloat(cols[1]);
      let free = parseFloat(cols[2]);
      if (isFinite(total) && total > 0) {
        if (!isFinite(used) && isFinite(free)) used = Math.max(0, total - free);
        if (!isFinite(free) && isFinite(used)) free = Math.max(0, total - used);

        const usedPct = isFinite(used) ? clamp(Math.round((used / total) * 100), 0, 100) : 0;
        const freePct = clamp(100 - usedPct, 0, 100);

        ctx.memTotalText = formatBytes(total);
        ctx.memUsedText = isFinite(used) ? formatBytes(used) : "—";
        ctx.memUsedPercent = usedPct;
        ctx.memSubText = isFinite(free) ? `可用 ${formatBytes(free)} (${freePct}%)` : "";
        ok = true;
      }
    }
  } catch (_) {}

  try {
    const dfRaw = await run("df", 2500);
    if (dfRaw) {
      const line = dfRaw.split(/\r?\n/).find((l) => /\s\/data\s*$/.test(l));
      if (line) {
        const parts = line.trim().split(/\s+/);
        const bs = parseFloat(parts[0]);
        const blocks = parseFloat(parts[1]);
        const usedBlocks = parseFloat(parts[2]);
        const availBlocks = parseFloat(parts[3]);
        if (isFinite(bs) && isFinite(blocks) && bs > 0 && blocks > 0) {
          const total = bs * blocks;
          let used = isFinite(usedBlocks) ? bs * usedBlocks : NaN;
          let avail = isFinite(availBlocks) ? bs * availBlocks : NaN;
          if (!isFinite(used) && isFinite(avail)) used = Math.max(0, total - avail);
          if (!isFinite(avail) && isFinite(used)) avail = Math.max(0, total - used);

          const usedPct = isFinite(used) ? clamp(Math.round((used / total) * 100), 0, 100) : 0;

          ctx.dataTotalText = formatBytes(total);
          ctx.dataUsedText = isFinite(used) ? formatBytes(used) : "—";
          ctx.dataUsedPercent = usedPct;
          ctx.dataSubText = isFinite(avail) ? `可用 ${formatBytes(avail)}` : "";
          ok = true;
        }
      }
    }
  } catch (_) {}

  return ok;
}

export async function refreshHardwareInfo(options) {
  const mode = (options && typeof options === "object" && options.mode) ? String(options.mode) : "full";
  if (this.isRefreshingShell) return;
  this.isRefreshingShell = true;
  const keepY = this.currentScrollY || 0;
  this.suStatus = "checking";
  this.suError = "";
  this.updateSuText();

  const run = async (cmd, timeoutMs) => {
    const r = await suExec(cmd, { sync: true, timeoutMs: timeoutMs || 2500 });
    return safeTrim(r && r.output);
  };

  const deviceKey = getDeviceKey(this);
  let cached = null;
  let cachedSnapshot = null;
  if (mode === "enter") {
    cached = await loadCache(deviceKey);
    if (cached && cached.snapshot) {
      cachedSnapshot = cached.snapshot;
      applySnapshot(this, cachedSnapshot);
    }
  }

  try {
    try {
      await run("echo __SU_OK__", 1200);
    } catch (e) {
      this.suStatus = "down";
      this.suError = e && e.message ? e.message : String(e);
      return;
    }

    const hasCachedStatic = !!(cachedSnapshot && cachedSnapshot.staticOk);
    let staticOk = hasCachedStatic;
    let dynamicOk = false;

    if (mode !== "enter" || !hasCachedStatic) {
      staticOk = await fetchStaticInfo(this, run);
    }

    dynamicOk = await fetchDynamicInfo(this, run);

    if (mode !== "enter" || !hasCachedStatic) {
      const snapshot = buildSnapshot(this, staticOk, dynamicOk);
      await saveCache(deviceKey, snapshot);
    }

    this.suStatus = "up";
  } catch (e) {
    this.suStatus = "down";
    this.suError = e && e.message ? e.message : String(e);
  } finally {
    this.updateSuText();
    this.isRefreshingShell = false;
    setTimeout(() => {
      try {
        this.restoreScroll(keepY);
      } catch (_) {}
    }, 0);
  }
}
