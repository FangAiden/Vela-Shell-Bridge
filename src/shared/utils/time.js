export function pad2(n) {
  const s = String(n == null ? "" : n);
  return s.length >= 2 ? s : `0${s}`;
}

export function formatHhMm(tsMs) {
  try {
    const d = new Date(tsMs);
    return `${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
  } catch (_) {
    return "";
  }
}

export function formatHhMmFromUnixSec(tsSec) {
  const n = Number(tsSec);
  if (!n || !isFinite(n)) return "--:--";
  const text = formatHhMm(n * 1000);
  return text || "--:--";
}
