export function oneLine(s) {
  try {
    return String(s == null ? "" : s).replace(/\s+/g, " ").trim();
  } catch (_) {
    return "";
  }
}

export function firstLine(s) {
  const t = String(s == null ? "" : s);
  const lines = t.split(/\r?\n/).map((x) => x.trim()).filter(Boolean);
  return lines.length ? lines[0] : "";
}
