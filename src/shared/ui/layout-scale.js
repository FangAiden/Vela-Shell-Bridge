const SCALE_BY_BUCKET = {
  r336: 0.9,
  r390: 0.96,
  r432: 1.0,
  c466: 0.97,
  c480: 1.0,
  p192: 0.9,
  p212: 1.0,
};

const BASE_LAYOUT_TOKENS = {
  fontBase: 14,
  cardRadius: 16,
  rowHeight: 44,
  gap: 10,
  iconSize: 40,
  modalWidth: 0.8,
  modalHeight: 0.62,
  bottomBlank: 100,
};

function clampScale(v) {
  const n = Number(v);
  if (!isFinite(n)) return 1;
  if (n < 0.8) return 0.8;
  if (n > 1.2) return 1.2;
  return n;
}

function roundBy(n) {
  return Math.max(1, Math.round(n));
}

export function getScaleByBucket(bucketKey) {
  return clampScale(SCALE_BY_BUCKET[String(bucketKey || "")] || 1);
}

export function buildLayoutTokens(bucketKey, baseTokens) {
  const base = Object.assign({}, BASE_LAYOUT_TOKENS, baseTokens || {});
  const scale = getScaleByBucket(bucketKey);
  return {
    scale,
    fontBase: roundBy(base.fontBase * scale),
    cardRadius: roundBy(base.cardRadius * scale),
    rowHeight: roundBy(base.rowHeight * scale),
    gap: roundBy(base.gap * scale),
    iconSize: roundBy(base.iconSize * scale),
    modalWidth: base.modalWidth,
    modalHeight: base.modalHeight,
    bottomBlank: roundBy(base.bottomBlank * scale),
  };
}

export { SCALE_BY_BUCKET, BASE_LAYOUT_TOKENS };
