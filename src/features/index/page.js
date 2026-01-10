import router from "@system.router";
import prompt from "@system.prompt";
import suExec from "../../services/su-daemon/index.js";
import { createPage } from "../../app/page.js";

export default createPage({
  data: {
    bgList: [
      { id: "blue", src: "/resources/image/glow/blue.png" },
      { id: "red", src: "/resources/image/glow/red.png" },
      { id: "green", src: "/resources/image/glow/green.png" },
      { id: "orange", src: "/resources/image/glow/orange.png" },
      { id: "cyan", src: "/resources/image/glow/cyan.png" },
      { id: "purple", src: "/resources/image/glow/purple.png" },
      { id: "white", src: "/resources/image/glow/white.png" }
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
        subtitle: "执行Shell命令",
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
      }
    ],

    pageWidth: 0,
    bgOpacity: [],
    currentScrollX: 0,
  },

  onInit() {
    this.bgOpacity = this.bgList.map((_, idx) => (idx === 0 ? 1 : 0));
    this.currentScrollX = 0;
  },

  onShow() {
    this.isLeaving = false;
    this.animClass = "";
    this.$element("funcScroll").getScrollRect({
      success: ({ width }) => {
        if (this.cards.length > 0) {
          this.pageWidth = width / this.cards.length;
          this.updateBgOpacityByScroll(this.currentScrollX);
        }
      },
    });
  },

  onScroll(e) {
    try {
      const x = (e && e.scrollX != null) ? e.scrollX : 0;
      const n = (typeof x === "number") ? x : parseFloat(String(x || "0"));
      this.currentScrollX = isFinite(n) ? n : 0;
    } catch (_) {
      this.currentScrollX = 0;
    }
    this.updateBgOpacityByScroll(this.currentScrollX);
  },

  updateBgOpacityByScroll(scrollX) {
    if (!this.pageWidth || this.pageWidth <= 0) {
      this.bgOpacity = this.bgList.map((_, idx) => (idx === 0 ? 1 : 0));
      return;
    }

    const pageCount = this.cards.length;
    if (pageCount === 0) return;

    let index = Math.floor(scrollX / this.pageWidth);
    if (index < 0) index = 0;
    if (index >= pageCount) index = pageCount - 1;

    const localX = scrollX - index * this.pageWidth;
    let p = localX / this.pageWidth;
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

    if (!this.transitionsEnabled) {
      this.isLeaving = true;
      let target = "";
      switch (id) {
        case "perm":
        case "file":
        case "shell":
        case "setting":
        case "log":
        case "about":
        case "saver":
          target = "pages/" + id;
          break;
        default:
          this.isLeaving = false;
          return;
      }
      router.push({ uri: target, params: {} });
      return;
    }

    this.isLeaving = true;
    this.animClass = "page-leave";

    let target = "";
    switch (id) {
      case "perm":
      case "file":
      case "shell":
      case "setting":
      case "log":
      case "about":
      case "saver":
        target = "pages/" + id;
        break;
      default:
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

