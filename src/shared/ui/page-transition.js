import { getCachedTransitionsEnabled, getLocalSettings } from "../settings/local-settings.js";

const DEFAULT_ENTER_CLASS = "page-enter";
const DEFAULT_LEAVE_CLASS = "page-leave";
const DEFAULT_STATIC_CLASS = "page-static";
const DEFAULT_ENTER_MS = 140;
const DEFAULT_LEAVE_MS = 120;
const ENTER_SETTLE_TIMER_KEY = "__VSB_ENTER_SETTLE_TIMER__";
const TRANSITION_SEQ_KEY = "__VSB_TRANSITION_SEQ__";

function clearEnterSettleTimer(ctx) {
  const timerId = ctx && ctx[ENTER_SETTLE_TIMER_KEY];
  if (timerId) {
    clearTimeout(timerId);
  }
  if (ctx) {
    ctx[ENTER_SETTLE_TIMER_KEY] = 0;
  }
}

function scheduleEnterSettle(ctx, seq, staticClass, enterMs) {
  clearEnterSettleTimer(ctx);
  const delay = Math.max(0, Number(enterMs) || 0);
  ctx[ENTER_SETTLE_TIMER_KEY] = setTimeout(() => {
    if (!ctx || ctx[TRANSITION_SEQ_KEY] !== seq) return;
    if (ctx.isLeaving) return;
    ctx.animClass = staticClass;
    ctx[ENTER_SETTLE_TIMER_KEY] = 0;
  }, delay);
}

export function initPageTransitions(ctx, options = {}) {
  const enterClass = options.enterClass || DEFAULT_ENTER_CLASS;
  const staticClass = options.staticClass || DEFAULT_STATIC_CLASS;
  const enterMs = options.enterMs != null ? options.enterMs : DEFAULT_ENTER_MS;
  const seq = (ctx[TRANSITION_SEQ_KEY] || 0) + 1;
  ctx[TRANSITION_SEQ_KEY] = seq;

  clearEnterSettleTimer(ctx);
  ctx.transitionsEnabled = getCachedTransitionsEnabled();
  ctx.isLeaving = false;
  ctx.animClass = "";

  setTimeout(() => {
    if (ctx[TRANSITION_SEQ_KEY] !== seq) return;
    if (ctx.transitionsEnabled) {
      ctx.animClass = enterClass;
      scheduleEnterSettle(ctx, seq, staticClass, enterMs);
    } else {
      ctx.animClass = staticClass;
    }
  }, 0);

  return getLocalSettings().then((local) => {
    const enabled = !!(local && local.ui && local.ui.enableTransitions);
    ctx.transitionsEnabled = enabled;
    if (!enabled) {
      clearEnterSettleTimer(ctx);
      ctx.animClass = staticClass;
    } else if (!ctx.isLeaving && ctx[TRANSITION_SEQ_KEY] === seq) {
      const currentClass = String(ctx.animClass || "");
      if (!currentClass) {
        ctx.animClass = enterClass;
        scheduleEnterSettle(ctx, seq, staticClass, enterMs);
      }
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

  clearEnterSettleTimer(ctx);
  ctx[TRANSITION_SEQ_KEY] = (ctx[TRANSITION_SEQ_KEY] || 0) + 1;
  ctx.isLeaving = true;
  ctx.animClass = leaveClass;
  if (typeof onBack === "function") {
    setTimeout(onBack, leaveMs);
  }
  return true;
}
