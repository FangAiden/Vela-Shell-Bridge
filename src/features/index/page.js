import router from "@system.router";
import prompt from "@system.prompt";
import device from "@system.device";
import suExec from "../../services/su-daemon/index.js";
import { createPage } from "../../app/page.js";
import { detectScreenProfile, getBucketDefaults } from "../../shared/ui/screen-profile.js";
import { getScaleByBucket } from "../../shared/ui/layout-scale.js";

const DEFAULT_BG_SIZE = { width: 480, height: 480 };
const BUCKET_BG_SIZE = {
  r336: { width: 336, height: 480 },
  r390: { width: 390, height: 450 },
  r432: { width: 432, height: 514 },
  c466: { width: 466, height: 466 },
  c480: { width: 480, height: 480 },
  p192: { width: 192, height: 490 },
  p212: { width: 212, height: 520 },
};
const SNAP_SETTLE_MS = 90;
const SNAP_MAX_STEP = 1;
const SNAP_THRESHOLD_PX = 2;
const SNAP_PROGRAMMATIC_MS = 180;
const SWIPE_CLICK_GUARD_MS = 120;
const BG_PREVIEW_SAMPLE_MS = 12;
const BG_PREVIEW_MIN_MS = 220;

function toPositiveInt(v, fallback = 0) {
  const n = Math.round(Number(v));
  return isFinite(n) && n > 0 ? n : fallback;
}

function resolveBgSize(profile, bucketKey) {
  const p = profile && typeof profile === "object" ? profile : {};
  const width = toPositiveInt(p.width, 0);
  const height = toPositiveInt(p.height, 0);
  if (width > 0 && height > 0) {
    return { width, height };
  }
  const bucket = BUCKET_BG_SIZE[bucketKey];
  if (bucket) return { width: bucket.width, height: bucket.height };
  return DEFAULT_BG_SIZE;
}

export default createPage({
  data: {
    bgList: [
      { id: "blue", src: "/resources/image/glow/blue.png" },
      { id: "red", src: "/resources/image/glow/red.png" },
      { id: "green", src: "/resources/image/glow/green.png" },
      { id: "orange", src: "/resources/image/glow/orange.png" },
      { id: "cyan", src: "/resources/image/glow/cyan.png" },
      { id: "purple", src: "/resources/image/glow/purple.png" },
      { id: "white", src: "/resources/image/glow/white.png" },
    ],

    cards: [
      {
        id: "perm",
        title: "授权管理",
        subtitle: "管理应用执行权限",
        image: "/resources/image/perm.png",
      },
      {
        id: "file",
        title: "文件管理",
        subtitle: "管理系统文件",
        image: "/resources/image/file_manager.png",
      },
      {
        id: "shell",
        title: "终端",
        subtitle: "执行 Shell 命令",
        image: "/resources/image/shell.png",
      },
      {
        id: "setting",
        title: "设置",
        subtitle: "应用设置",
        image: "/resources/image/setting.png",
      },
      {
        id: "log",
        title: "日志",
        subtitle: "查看应用日志",
        image: "/resources/image/log.png",
      },
      {
        id: "about",
        title: "关于设备",
        subtitle: "查看设备信息",
        image: "/resources/image/about.png",
      },
      {
        id: "saver",
        title: "息屏挂机",
        subtitle: "防止设备烧屏",
        image: "/resources/image/saver.png",
      },
    ],

    pageWidth: 0,
    bgOpacity: [],
    currentScrollPos: 0,
    screenShape: "circle",
    screenBucket: "c480",
    screenScale: 1,
    bgWidthPx: DEFAULT_BG_SIZE.width,
    bgHeightPx: DEFAULT_BG_SIZE.height,
    pillBaseCardHeight: 380,
    pillBaseGap: 40,
  },

  onInit() {
    this.bgOpacity = this.bgList.map((_, idx) => (idx === 0 ? 1 : 0));
    this.currentScrollPos = 0;
    this._bgPreviewActive = false;
    this._bgPreviewFromPos = 0;
    this._bgPreviewToPos = 0;
    this._bgPreviewPos = 0;
    this._bgPreviewStartTs = 0;
    this._bgPreviewDurationMs = SNAP_PROGRAMMATIC_MS;
    this._suppressCardClickUntil = 0;
    this.detectDeviceProfile();
  },

  onShow() {
    this.isLeaving = false;
    this.stopBgSwipePreview();
    this.resetSnapState();
    this._suppressCardClickUntil = 0;
    const scrollEl = this.$element("funcScroll");
    if (!scrollEl || typeof scrollEl.getScrollRect !== "function") {
      this.pageWidth = 0;
      this.updateBgOpacityByScroll(this.currentScrollPos);
      return;
    }
    scrollEl.getScrollRect({
      success: ({ width }) => {
        if (this.cards.length > 0) {
          this.pageWidth = width / this.cards.length;
          this.updateBgOpacityByScroll(this.currentScrollPos);
        }
      },
      fail: () => {
        this.pageWidth = 0;
        this.updateBgOpacityByScroll(this.currentScrollPos);
      },
    });
  },

  onHide() {
    this.stopBgSwipePreview();
    this.clearSnapTimer();
  },

  onDestroy() {
    this.stopBgSwipePreview();
    this.clearSnapTimer();
  },

  detectDeviceProfile() {
    device.getInfo({
      success: (ret) => {
        const profile = detectScreenProfile(ret);
        this.applyScreenProfile(profile);
      },
      fail: () => {
        this.applyScreenProfile({
          shape: "circle",
          bucketKey: getBucketDefaults("circle"),
          width: 0,
          height: 0,
        });
      },
    });
  },

  applyScreenProfile(profile) {
    const p = profile && typeof profile === "object" ? profile : {};
    const shape = p.shape || "circle";
    const bucket = p.bucketKey || getBucketDefaults(shape);
    const bgSize = resolveBgSize(p, bucket);
    this.screenShape = shape;
    this.screenBucket = bucket;
    this.screenScale = getScaleByBucket(bucket);
    this.bgWidthPx = bgSize.width;
    this.bgHeightPx = bgSize.height;
  },

  getPillPageStep() {
    const cardHeight = Math.max(300, Math.round(this.pillBaseCardHeight * this.screenScale));
    const gap = Math.max(24, Math.round(this.pillBaseGap * this.screenScale));
    return cardHeight + gap;
  },

  clampScrollPos(pos) {
    const pageSize = this.getSnapPageSize();
    if (!pageSize || pageSize <= 0) return 0;
    const maxOffset = this.getSnapMaxIndex() * pageSize;
    let out = Number(pos);
    if (!isFinite(out)) out = 0;
    if (out < 0) out = 0;
    if (out > maxOffset) out = maxOffset;
    return out;
  },

  applyScrollPos(pos, behavior) {
    const next = this.clampScrollPos(pos);
    const mode = behavior || "instant";
    if (mode === "instant") {
      this.currentScrollPos = next;
      this.updateBgOpacityByScroll(next);
    }
    this.scrollToSnapOffset(next, mode, mode !== "instant");
  },

  clearSnapTimer() {
    if (this._snapTimer) {
      clearTimeout(this._snapTimer);
      this._snapTimer = 0;
    }
  },

  resetSnapState() {
    this.clearSnapTimer();
    this._snapProgrammaticUntil = 0;
    this._snapGestureActive = false;
    this._snapStartIndex = this.getSnapIndexByScroll(this.currentScrollPos);
  },

  getSnapPageSize() {
    return this.getBgPageSize();
  },

  getSnapMaxIndex() {
    const count = Array.isArray(this.cards) ? this.cards.length : 0;
    return Math.max(0, count - 1);
  },

  clampSnapIndex(index) {
    let idx = Math.round(Number(index));
    if (!isFinite(idx)) idx = 0;
    if (idx < 0) idx = 0;
    const maxIndex = this.getSnapMaxIndex();
    if (idx > maxIndex) idx = maxIndex;
    return idx;
  },

  getSnapIndexByScroll(scrollPos) {
    const pageSize = this.getSnapPageSize();
    if (!pageSize || pageSize <= 0) return 0;
    const raw = Number(scrollPos || 0) / pageSize;
    return this.clampSnapIndex(Math.round(raw));
  },

  getSnapOffsetByIndex(index) {
    const pageSize = this.getSnapPageSize();
    if (!pageSize || pageSize <= 0) return 0;
    return this.clampSnapIndex(index) * pageSize;
  },

  scrollToSnapOffset(targetOffset, behavior, withLock = true) {
    const scrollEl = this.$element("funcScroll");
    if (!scrollEl || typeof scrollEl.scrollTo !== "function") return false;

    const pos = Math.max(0, Number(targetOffset) || 0);
    const mode = behavior || "smooth";
    if (withLock) {
      this._snapProgrammaticUntil = Date.now() + SNAP_PROGRAMMATIC_MS;
    }

    try {
      if (this.screenShape === "pill-shaped") {
        scrollEl.scrollTo({ top: pos, behavior: mode });
      } else {
        scrollEl.scrollTo({ left: pos, behavior: mode });
      }
    } catch (_) {
      try {
        if (this.screenShape === "pill-shaped") {
          scrollEl.scrollTo({ top: pos });
        } else {
          scrollEl.scrollTo({ left: pos });
        }
      } catch (__){
        return false;
      }
    }
    return true;
  },

  finalizeSnap() {
    this.clearSnapTimer();
    this._snapGestureActive = false;

    const pageSize = this.getSnapPageSize();
    if (!pageSize || pageSize <= 0) return;
    if (this.getSnapMaxIndex() <= 0) return;

    const startIndex = this.clampSnapIndex(this._snapStartIndex);
    let desiredIndex = this.getSnapIndexByScroll(this.currentScrollPos);
    if (desiredIndex > startIndex + SNAP_MAX_STEP) {
      desiredIndex = startIndex + SNAP_MAX_STEP;
    } else if (desiredIndex < startIndex - SNAP_MAX_STEP) {
      desiredIndex = startIndex - SNAP_MAX_STEP;
    }
    desiredIndex = this.clampSnapIndex(desiredIndex);

    const targetOffset = this.getSnapOffsetByIndex(desiredIndex);
    const delta = Math.abs(targetOffset - Number(this.currentScrollPos || 0));
    if (delta > SNAP_THRESHOLD_PX) {
      this.scrollToSnapOffset(targetOffset, "smooth");
    }

    this.currentScrollPos = targetOffset;
    this.updateBgOpacityByScroll(targetOffset);
    this._snapStartIndex = desiredIndex;
  },

  scheduleSnap() {
    if (Date.now() < Number(this._snapProgrammaticUntil || 0)) return;
    if (!this._snapGestureActive) {
      this._snapGestureActive = true;
      this._snapStartIndex = this.getSnapIndexByScroll(this.currentScrollPos);
    }

    this.clearSnapTimer();
    this._snapTimer = setTimeout(() => {
      this._snapTimer = 0;
      this.finalizeSnap();
    }, SNAP_SETTLE_MS);
  },

  getBgPageSize() {
    return this.screenShape === "pill-shaped" ? this.getPillPageStep() : this.pageWidth;
  },

  stopBgSwipePreview() {
    if (this._bgPreviewTimer) {
      clearTimeout(this._bgPreviewTimer);
      this._bgPreviewTimer = 0;
    }
    this._bgPreviewActive = false;
  },

  startBgSwipePreview(fromPos, toPos, durationMs) {
    let from = Number(fromPos);
    let to = Number(toPos);
    if (!isFinite(from)) from = 0;
    if (!isFinite(to)) to = from;

    const distance = Math.abs(to - from);
    if (distance <= 0.01) {
      this.stopBgSwipePreview();
      this.updateBgOpacityByScroll(to);
      return;
    }

    this.stopBgSwipePreview();
    this._bgPreviewActive = true;
    this._bgPreviewFromPos = from;
    this._bgPreviewToPos = to;
    this._bgPreviewPos = from;
    this._bgPreviewStartTs = Date.now();
    this._bgPreviewDurationMs = Math.max(BG_PREVIEW_MIN_MS, Number(durationMs) || SNAP_PROGRAMMATIC_MS);

    // Start blending immediately when swipe is recognized.
    this.updateBgOpacityByScroll(from);
    this.scheduleBgSwipePreview();
  },

  scheduleBgSwipePreview() {
    if (this._bgPreviewTimer || !this._bgPreviewActive) return;

    this._bgPreviewTimer = setTimeout(() => {
      this._bgPreviewTimer = 0;
      if (!this._bgPreviewActive) return;

      const startTs = Number(this._bgPreviewStartTs || 0);
      const duration = Math.max(BG_PREVIEW_MIN_MS, Number(this._bgPreviewDurationMs || SNAP_PROGRAMMATIC_MS));
      if (!startTs) {
        this.stopBgSwipePreview();
        return;
      }

      let p = (Date.now() - startTs) / duration;
      if (!isFinite(p)) p = 1;
      if (p < 0) p = 0;
      if (p > 1) p = 1;

      // Ease-in-out cubic avoids "instant jump" feeling at the beginning.
      const eased = p < 0.5
        ? 4 * p * p * p
        : 1 - Math.pow(-2 * p + 2, 3) / 2;
      const from = Number(this._bgPreviewFromPos || 0);
      const to = Number(this._bgPreviewToPos || 0);
      const pos = from + (to - from) * eased;
      this._bgPreviewPos = pos;
      this.updateBgOpacityByScroll(pos);

      if (p >= 1) {
        this._bgPreviewActive = false;
        this.updateBgOpacityByScroll(to);
        return;
      }
      this.scheduleBgSwipePreview();
    }, BG_PREVIEW_SAMPLE_MS);
  },

  onSwipe(e) {
    if (Date.now() < Number(this._snapProgrammaticUntil || 0)) return;

    const direction = String((e && e.direction) || "").toLowerCase();
    const pageSize = this.getSnapPageSize();
    if (!pageSize || pageSize <= 0) return;

    let step = 0;
    if (this.screenShape === "pill-shaped") {
      if (direction === "up") step = 1;
      else if (direction === "down") step = -1;
    } else {
      if (direction === "left") step = 1;
      else if (direction === "right") step = -1;
    }
    if (!step) return;

    const baseIndex = this.getSnapIndexByScroll(this.currentScrollPos);
    let targetIndex = this.clampSnapIndex(baseIndex + step);
    if (targetIndex > baseIndex + SNAP_MAX_STEP) targetIndex = baseIndex + SNAP_MAX_STEP;
    if (targetIndex < baseIndex - SNAP_MAX_STEP) targetIndex = baseIndex - SNAP_MAX_STEP;
    targetIndex = this.clampSnapIndex(targetIndex);
    if (targetIndex === baseIndex) return;

    const fromOffset = this.getSnapOffsetByIndex(baseIndex);
    const targetOffset = this.getSnapOffsetByIndex(targetIndex);
    this.startBgSwipePreview(fromOffset, targetOffset, SNAP_PROGRAMMATIC_MS);
    this.applyScrollPos(targetOffset, "smooth");
    this._suppressCardClickUntil = Date.now() + SWIPE_CLICK_GUARD_MS;
  },

  onGestureTap() {
    const idx = this.getSnapIndexByScroll(this.currentScrollPos);
    const card = Array.isArray(this.cards) ? this.cards[this.clampSnapIndex(idx)] : null;
    if (card && card.id) {
      this.onClickCard(card.id);
    }
  },

  onScroll(e) {
    try {
      let scrollPos = 0;
      if (this.screenShape === "pill-shaped") {
        let y = 0;
        if (e) {
          if (e.scrollY !== undefined) y = e.scrollY;
          else if (e.scrollTop !== undefined) y = e.scrollTop;
          else if (e.contentOffset && e.contentOffset.y !== undefined) y = -e.contentOffset.y;
        }
        const n = typeof y === "number" ? y : parseFloat(String(y || "0"));
        scrollPos = isFinite(n) ? n : 0;
      } else {
        const x = e && e.scrollX != null ? e.scrollX : 0;
        const n = typeof x === "number" ? x : parseFloat(String(x || "0"));
        scrollPos = isFinite(n) ? n : 0;
      }
      this.currentScrollPos = scrollPos;
    } catch (_) {
      this.currentScrollPos = 0;
    }
    if (this._bgPreviewActive) return;
    this.updateBgOpacityByScroll(this.currentScrollPos);
  },

  updateBgOpacityByScroll(scrollPos) {
    const pageSize = this.getBgPageSize();

    if (!pageSize || pageSize <= 0) {
      this.bgOpacity = this.bgList.map((_, idx) => (idx === 0 ? 1 : 0));
      return;
    }

    const pageCount = this.cards.length;
    if (pageCount === 0) return;

    let index = Math.floor(scrollPos / pageSize);
    if (index < 0) index = 0;
    if (index >= pageCount) index = pageCount - 1;

    const localPos = scrollPos - index * pageSize;
    let p = localPos / pageSize;
    if (p < 0) p = 0;
    if (p > 1) p = 1;

    const op = this.bgList.map(() => 0);

    if (index < this.bgList.length) {
      op[index] = 1 - p;
    }

    if (index + 1 < this.bgList.length) {
      op[index + 1] = p;
    } else if (index < this.bgList.length) {
      op[index] = 1;
    }

    this.bgOpacity = op;
  },

  routeDetail() {
    router.back();
  },

  onClickCard(id) {
    if (this.isLeaving) return;
    if (Date.now() < Number(this._suppressCardClickUntil || 0)) return;

    const targetMapByShape = {
      rect: {
        perm: "pages/perm-rect",
        file: "pages/file-rect",
        shell: "pages/shell-rect",
        setting: "pages/setting-rect",
        log: "pages/log-rect",
        about: "pages/about-rect",
        saver: "pages/saver-rect",
      },
      circle: {
        perm: "pages/perm-circle",
        file: "pages/file-circle",
        shell: "pages/shell-circle",
        setting: "pages/setting-circle",
        log: "pages/log-circle",
        about: "pages/about-circle",
        saver: "pages/saver-circle",
      },
      "pill-shaped": {
        perm: "pages/perm-pill",
        file: "pages/file-pill",
        shell: "pages/shell-pill",
        setting: "pages/setting-pill",
        log: "pages/log-pill",
        about: "pages/about-pill",
        saver: "pages/saver-pill",
      },
    };

    const targetMap = targetMapByShape[this.screenShape] || targetMapByShape.circle;
    const target = targetMap[id] || "";

    if (!this.transitionsEnabled) {
      this.isLeaving = true;
      if (!target) {
        this.isLeaving = false;
        return;
      }
      router.push({ uri: target, params: {} });
      return;
    }

    this.isLeaving = true;
    this.animClass = "page-leave";
    if (!target) {
      this.isLeaving = false;
      this.animClass = "";
      return;
    }

    setTimeout(() => {
      router.push({ uri: target, params: {} });
    }, 120);
  },

  tosast(msg) {
    prompt.showToast({
      message: msg,
      duration: 500,
    });
  },

  async test() {
    try {
      const res = await suExec("uptime");
      console.log("SU OK:", res.output);
    } catch (e) {
      console.log("SU ERR:", e.message);
    }
  },
}, { isHome: true });
