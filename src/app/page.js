import router from "@system.router";
import brightness from "@system.brightness";
import { initPageTransitions, handlePageBack } from "../shared/ui/page-transition.js";

const BASE_TRANSITION_STATE = {
  transitionsEnabled: true,
  animClass: "",
  isLeaving: false,
};

const KEEP_AWAKE_RELEASE_DELAY_MS = 260;
let keepAwakeRefs = 0;
let keepAwakeApplied = false;
let keepAwakeReleaseTimer = 0;

function clearKeepAwakeReleaseTimer() {
  if (keepAwakeReleaseTimer) {
    clearTimeout(keepAwakeReleaseTimer);
    keepAwakeReleaseTimer = 0;
  }
}

function setKeepScreenOnEnabled(enabled) {
  try {
    if (!brightness || typeof brightness.setKeepScreenOn !== "function") return;
    brightness.setKeepScreenOn({ keepScreenOn: !!enabled });
  } catch (_) {}
}

function acquireKeepAwake() {
  clearKeepAwakeReleaseTimer();
  keepAwakeRefs += 1;
  if (!keepAwakeApplied) {
    keepAwakeApplied = true;
    setKeepScreenOnEnabled(true);
  }
}

function releaseKeepAwake() {
  if (keepAwakeRefs > 0) keepAwakeRefs -= 1;
  if (keepAwakeRefs > 0) return;

  clearKeepAwakeReleaseTimer();
  keepAwakeReleaseTimer = setTimeout(() => {
    keepAwakeReleaseTimer = 0;
    if (keepAwakeRefs > 0) return;
    if (!keepAwakeApplied) return;
    keepAwakeApplied = false;
    setKeepScreenOnEnabled(false);
  }, KEEP_AWAKE_RELEASE_DELAY_MS);
}

export function createPage(def = {}, options = {}) {
  const userData = def.data && typeof def.data === "object" ? def.data : {};
  const transitionsFactory = options.transitions;
  const backOptions = options.backOptions && typeof options.backOptions === "object"
    ? options.backOptions
    : {};

  const onBack = typeof options.onBack === "function"
    ? options.onBack
    : () => {
      if (router && typeof router.back === "function") router.back();
    };

  const onShow = def.onShow;
  const onHide = def.onHide;
  const onDestroy = def.onDestroy;
  const onBackPress = def.onBackPress;

  return Object.assign({}, def, {
    data: Object.assign({}, BASE_TRANSITION_STATE, userData),
    onShow() {
      if (!this.__keepAwakeHeld) {
        acquireKeepAwake();
        this.__keepAwakeHeld = true;
      }
      this.$broadcast("page-on-show", {});
      const transitions =
        (typeof transitionsFactory === "function")
          ? transitionsFactory.call(this)
          : (transitionsFactory && typeof transitionsFactory === "object")
            ? transitionsFactory
            : {};
      initPageTransitions(this, transitions);
      if (typeof onShow === "function") {
        return onShow.call(this);
      }
      return undefined;
    },
    onHide() {
      if (this.__keepAwakeHeld) {
        this.__keepAwakeHeld = false;
        releaseKeepAwake();
      }
      if (typeof onHide === "function") {
        return onHide.call(this);
      }
      return undefined;
    },
    onDestroy() {
      if (this.__keepAwakeHeld) {
        this.__keepAwakeHeld = false;
        releaseKeepAwake();
      }
      if (typeof onDestroy === "function") {
        return onDestroy.call(this);
      }
      return undefined;
    },
    onBackPress() {
      if (typeof onBackPress === "function") {
        const handled = onBackPress.call(this);
        if (handled === true) return true;
      }
      return handlePageBack(this, onBack, backOptions);
    },
  });
}
