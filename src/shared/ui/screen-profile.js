const SCREEN_BUCKETS = {
  rect: [
    { key: "r336", width: 336, height: 480 },
    { key: "r390", width: 390, height: 450 },
    { key: "r432", width: 432, height: 514 },
  ],
  circle: [
    { key: "c466", width: 466, height: 466 },
    { key: "c480", width: 480, height: 480 },
  ],
  "pill-shaped": [
    { key: "p192", width: 192, height: 490 },
    { key: "p212", width: 212, height: 520 },
  ],
};

function toFiniteNumber(v, fallback = 0) {
  const n = Number(v);
  return isFinite(n) && n > 0 ? n : fallback;
}

export function normalizeShape(shapeString) {
  const s = String(shapeString == null ? "" : shapeString).toLowerCase();
  if (s === "pill-shaped" || s === "pill" || s === "capsule") return "pill-shaped";
  if (s === "rect" || s === "rectangle" || s === "square") return "rect";
  if (s === "circle" || s === "round") return "circle";
  return "";
}

function inferShapeBySize(width, height) {
  const w = toFiniteNumber(width, 0);
  const h = toFiniteNumber(height, 0);
  if (!w || !h) return "circle";

  const ratio = h / w;
  if (ratio >= 1.9 && w <= 260) return "pill-shaped";
  if (Math.abs(ratio - 1) <= 0.18) return "circle";
  return "rect";
}

function pickNearest(list, width, height) {
  if (!Array.isArray(list) || !list.length) return "";
  const w = toFiniteNumber(width, list[0].width);
  const h = toFiniteNumber(height, list[0].height);
  let best = list[0];
  let bestScore = Number.MAX_SAFE_INTEGER;

  list.forEach((it) => {
    const dw = Math.abs(it.width - w);
    const dh = Math.abs(it.height - h);
    const score = dw * dw + dh * dh;
    if (score < bestScore) {
      bestScore = score;
      best = it;
    }
  });

  return best.key;
}

export function pickNearestBucket(shape, width, height) {
  const normalizedShape = normalizeShape(shape) || inferShapeBySize(width, height);
  const candidates = SCREEN_BUCKETS[normalizedShape] || SCREEN_BUCKETS.circle;
  return pickNearest(candidates, width, height);
}

export function detectScreenProfile(deviceInfo) {
  const info = deviceInfo && typeof deviceInfo === "object" ? deviceInfo : {};
  const width = toFiniteNumber(info.windowWidth || info.screenWidth, 0);
  const height = toFiniteNumber(info.windowHeight || info.screenHeight, 0);
  const shape = normalizeShape(info.screenShape) || inferShapeBySize(width, height);
  const bucketKey = pickNearestBucket(shape, width, height);

  return {
    shape,
    width,
    height,
    bucketKey,
  };
}

export function getBucketDefaults(shape) {
  const normalizedShape = normalizeShape(shape) || "circle";
  const list = SCREEN_BUCKETS[normalizedShape] || SCREEN_BUCKETS.circle;
  return list[0] ? list[0].key : "c480";
}

export { SCREEN_BUCKETS };
