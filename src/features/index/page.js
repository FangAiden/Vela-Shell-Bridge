import router from "@system.router";
import prompt from "@system.prompt";
import device from "@system.device";
import suExec from "../../services/su-daemon/index.js";
import { createPage } from "../../app/page.js";
import { detectScreenProfile, getBucketDefaults } from "../../shared/ui/screen-profile.js";
import { getScaleByBucket } from "../../shared/ui/layout-scale.js";

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
    pillBaseCardHeight: 380,
    pillBaseGap: 40,
  },

  onInit() {
    this.bgOpacity = this.bgList.map((_, idx) => (idx === 0 ? 1 : 0));
    this.currentScrollPos = 0;
    this.detectDeviceProfile();
  },

  onShow() {
    this.isLeaving = false;
    this.animClass = "";
    this.$element("funcScroll").getScrollRect({
      success: ({ width }) => {
        if (this.cards.length > 0) {
          this.pageWidth = width / this.cards.length;
          this.updateBgOpacityByScroll(this.currentScrollPos);
        }
      },
    });
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
    this.screenShape = shape;
    this.screenBucket = bucket;
    this.screenScale = getScaleByBucket(bucket);
  },

  getPillPageStep() {
    const cardHeight = Math.max(300, Math.round(this.pillBaseCardHeight * this.screenScale));
    const gap = Math.max(24, Math.round(this.pillBaseGap * this.screenScale));
    return cardHeight + gap;
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
    this.updateBgOpacityByScroll(this.currentScrollPos);
  },

  updateBgOpacityByScroll(scrollPos) {
    const pageSize = this.screenShape === "pill-shaped" ? this.getPillPageStep() : this.pageWidth;

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

    const targetMapByShape = {
      rect: {
        perm: "pages/rect/perm",
        file: "pages/rect/file",
        shell: "pages/rect/shell",
        setting: "pages/rect/setting",
        log: "pages/rect/log",
        about: "pages/rect/about",
        saver: "pages/rect/saver",
      },
      circle: {
        perm: "pages/circle/perm",
        file: "pages/circle/file",
        shell: "pages/circle/shell",
        setting: "pages/circle/setting",
        log: "pages/circle/log",
        about: "pages/circle/about",
        saver: "pages/circle/saver",
      },
      "pill-shaped": {
        perm: "pages/pill/perm",
        file: "pages/pill/file",
        shell: "pages/pill/shell",
        setting: "pages/pill/setting",
        log: "pages/pill/log",
        about: "pages/pill/about",
        saver: "pages/pill/saver",
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
    }, 180);
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
