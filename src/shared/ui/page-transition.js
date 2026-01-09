import { getCachedTransitionsEnabled, getLocalSettings } from "../settings/local-settings.js";

const DEFAULT_ENTER_CLASS = "page-enter";
const DEFAULT_LEAVE_CLASS = "page-leave";
const DEFAULT_STATIC_CLASS = "page-static";
const DEFAULT_LEAVE_MS = 180;

export function initPageTransitions(ctx, options = {}) {
  const enterClass = options.enterClass || DEFAULT_ENTER_CLASS;
  const staticClass = options.staticClass || DEFAULT_STATIC_CLASS;

  ctx.transitionsEnabled = getCachedTransitionsEnabled();
  ctx.isLeaving = false;
  ctx.animClass = "";

  setTimeout(() => {
    ctx.animClass = ctx.transitionsEnabled ? enterClass : staticClass;
  }, 0);

  return getLocalSettings().then((local) => {
    const enabled = !!(local && local.ui && local.ui.enableTransitions);
    ctx.transitionsEnabled = enabled;
    if (!enabled) {
      ctx.animClass = staticClass;
    }
    if (typeof options.onLoaded === "function") {
      options.onLoaded(local);
    }
    return local;
  });
}

export function handlePageBack(ctx, onBack, options = {}) {
  const leaveClass = options.leaveClass || DEFAULT_LEAVE_CLASS;
  const leaveMs =
    options.leaveMs != null ? options.leaveMs : DEFAULT_LEAVE_MS;

  if (!ctx.transitionsEnabled) {
    if (typeof onBack === "function") onBack();
    return true;
  }
  if (ctx.isLeaving) return true;

  ctx.isLeaving = true;
  ctx.animClass = leaveClass;
  if (typeof onBack === "function") {
    setTimeout(onBack, leaveMs);
  }
  return true;
}
