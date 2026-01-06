export function safeTrim(s) {
  return (typeof s === "string" ? s : "").trim();
}

export function formatBytes(n) {
  const num = typeof n === "number" ? n : parseFloat(String(n || ""));
  if (!isFinite(num) || num < 0) return "—";
  if (num < 1024) return `${Math.round(num)}B`;
  const kb = num / 1024;
  if (kb < 1024) return `${kb.toFixed(1)}KB`;
  const mb = kb / 1024;
  if (mb < 1024) return `${mb.toFixed(1)}MB`;
  const gb = mb / 1024;
  return `${gb.toFixed(1)}GB`;
}

export function pickFirstNonEmpty(...values) {
  for (let i = 0; i < values.length; i++) {
    const v = values[i];
    if (typeof v === "string" && v.trim()) return v.trim();
  }
  return "";
}

export function extractFirstNumber(text) {
  const m = safeTrim(text).match(/(\d+)/);
  return m ? parseInt(m[1], 10) : null;
}

export function clamp(n, min, max) {
  const x = typeof n === "number" ? n : parseFloat(String(n || ""));
  if (!isFinite(x)) return min;
  return Math.min(max, Math.max(min, x));
}

export function toPercent01(v) {
  const x = typeof v === "number" ? v : parseFloat(String(v || ""));
  if (!isFinite(x)) return 0;
  return clamp(Math.round(x * 100), 0, 100);
}

export function toPercent255(v) {
  const x = typeof v === "number" ? v : parseFloat(String(v || ""));
  if (!isFinite(x)) return 0;
  return clamp(Math.round((x / 255) * 100), 0, 100);
}

export function mapNetworkType(type) {
  const t = String(type || "").toLowerCase();
  if (t === "wifi") return "Wi-Fi";
  if (t === "2g") return "2G";
  if (t === "3g") return "3G";
  if (t === "4g") return "4G";
  if (t === "5g") return "5G";
  if (t === "bluetooth") return "蓝牙";
  if (t === "none") return "无网络";
  if (!t) return "—";
  return t.toUpperCase();
}

export function mapAppSourceType(type) {
  const t = String(type || "").toLowerCase();
  if (!t) return "";
  if (t === "shortcut") return "快捷方式";
  if (t === "push") return "推送";
  if (t === "url") return "URL";
  if (t === "barcode") return "二维码";
  if (t === "nfc") return "NFC";
  if (t === "bluetooth") return "蓝牙";
  if (t === "other") return "其他";
  return t;
}

export function mapBrightnessMode(mode) {
  if (mode === 1 || mode === "1") return "自动";
  if (mode === 0 || mode === "0") return "手动";
  return "—";
}

export function radToDeg(rad) {
  const x = typeof rad === "number" ? rad : parseFloat(String(rad || ""));
  if (!isFinite(x)) return null;
  return (x * 180) / Math.PI;
}

export function compassFromDeg(deg) {
  if (!isFinite(deg)) return "";
  const d = ((deg % 360) + 360) % 360;
  const dirs = ["北", "东北", "东", "东南", "南", "西南", "西", "西北"];
  const idx = Math.round(d / 45) % 8;
  return dirs[idx] || "";
}

