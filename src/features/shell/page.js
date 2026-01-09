import prompt from "@system.prompt";
import suIpc from "../../services/su-daemon/index.js";
import { createPage } from "../../app/page.js";
import { oneLine } from "../../shared/utils/text.js";

export default createPage({
  data: {
    textList: [],
    inputBuffer: "",
    inputPreview: "点击输入命令",
    showIme: false,
    imeInput: "",
    isRunning: false,
    imeKeyboardType: "QWERTY",
    imeVibrateMode: "short",
    imeScreenType: "circle",
    imeMaxLength: 5,
  },

  onBackPress() {
    if (this.showIme) {
      this.closeIme();
      return true;
    }
    return false;
  },

  openIme() {
    if (this.isRunning) {
      prompt.showToast({ message: "命令执行中，请稍后", duration: 700 });
      return;
    }
    this.imeInput = this.inputBuffer || "";
    this.showIme = true;
  },

  closeIme() {
    this.showIme = false;
    this.imeInput = "";
  },

  onImeComplete(e) {
    const detail = e && e.detail ? e.detail : {};
    const content = String(detail.content == null ? "" : detail.content);
    if (!content) return;
    this.imeInput = String(this.imeInput == null ? "" : this.imeInput) + content;
  },

  onImeDelete() {
    const cur = String(this.imeInput == null ? "" : this.imeInput);
    this.imeInput = cur.slice(0, -1);
  },

  confirmIme() {
    const text = String(this.imeInput == null ? "" : this.imeInput);
    const cmd = text.trim();
    this.closeIme();
    if (!cmd) return;

    this.inputBuffer = text;
    this.inputPreview = oneLine(cmd) || "点击输入命令";
    this.runCommand(cmd);
  },

  appendLine(line) {
    const next = Array.isArray(this.textList) ? this.textList.slice() : [];
    next.push(String(line == null ? "" : line));
    if (next.length > 140) {
      next.splice(0, next.length - 140);
    }
    this.textList = next;
  },

  appendOutput(output) {
    const lines = String(output == null ? "" : output)
      .split(/\r?\n/)
      .filter((x) => x !== "");
    if (!lines.length) {
      this.appendLine("(无输出)");
      return;
    }
    lines.forEach((line) => this.appendLine(line));
  },

  async runCommand(cmd) {
    if (this.isRunning) return;
    this.isRunning = true;
    this.appendLine(`> ${cmd}`);
    try {
      const res = await suIpc.exec(cmd, { sync: true, timeoutMs: 8000 });
      const out = res && res.output != null ? res.output : "";
      this.appendOutput(out);
      if (res && res.exitCode != null) {
        this.appendLine(`[exit ${res.exitCode}]`);
      }
    } catch (e) {
      const msg = e && e.message ? e.message : "执行失败";
      this.appendLine(`ERR: ${msg}`);
      prompt.showToast({ message: msg, duration: 900 });
    } finally {
      this.isRunning = false;
    }
  },
}, {
  transitions() {
    return {
      onLoaded: (local) => {
        const ime = local && local.ime ? local.ime : {};
        this.imeKeyboardType = ime.keyboardType || "QWERTY";
        this.imeVibrateMode = ime.vibrateMode != null ? ime.vibrateMode : "short";
        this.imeScreenType = ime.screenType || "circle";
        this.imeMaxLength = ime.maxLength != null ? ime.maxLength : 5;
      },
    };
  },
});