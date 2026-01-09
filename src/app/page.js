import router from "@system.router";
import { initPageTransitions, handlePageBack } from "../shared/ui/page-transition.js";

const BASE_TRANSITION_STATE = {
  transitionsEnabled: true,
  animClass: "",
  isLeaving: false,
};

export function createPage(def = {}, options = {}) {
  const userData = def.data && typeof def.data === "object" ? def.data : {};
  const transitionsFactory = options.transitions;
  const backOptions = options.backOptions && typeof options.backOptions === "object"
    ? options.backOptions
    : {};
  const onBack = typeof options.onBack === "function"
    ? options.onBack
    : () => router.back();

  const onShow = def.onShow;
  const onBackPress = def.onBackPress;

  return Object.assign({}, def, {
    data: Object.assign({}, BASE_TRANSITION_STATE, userData),
    onShow() {
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
    onBackPress() {
      if (typeof onBackPress === "function") {
        const handled = onBackPress.call(this);
        if (handled === true) return true;
      }
      return handlePageBack(this, onBack, backOptions);
    },
  });
}
