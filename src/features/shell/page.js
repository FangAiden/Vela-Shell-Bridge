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
    currentJobId: null,
    lastOutputLen: 0,
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
    // If running, kill the job
    if (this.isRunning && this.currentJobId) {
      this.killCurrentJob();
      return true;
    }
    return false;
  },

  openIme() {
    if (this.isRunning) {
      prompt.showToast({ message: "按返回键终止命令", duration: 700 });
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

  appendOutput(output, fromOffset = 0) {
    const full = String(output == null ? "" : output);
    const newPart = full.slice(fromOffset);
    const lines = newPart.split(/\r?\n/).filter((x) => x !== "");
    lines.forEach((line) => this.appendLine(line));
    return full.length;
  },

  async killCurrentJob() {
    if (!this.currentJobId) return;
    try {
      await suIpc.kill(this.currentJobId);
      this.appendLine("[已终止]");
    } catch (e) {
      // ignore
    }
    this.isRunning = false;
    this.currentJobId = null;
  },

  async runCommand(cmd) {
    if (this.isRunning) return;
    this.isRunning = true;
    this.lastOutputLen = 0;
    this.appendLine(`> ${cmd}`);

    try {
      // Start async job (don't wait for completion)
      const startRes = await suIpc.exec(cmd, { sync: false, wait: false, timeoutMs: 5000 });
      if (!startRes || !startRes.jobId) {
        throw new Error("启动失败");
      }

      this.currentJobId = startRes.jobId;

      // Poll for output
      let done = false;
      let pollCount = 0;
      const maxPolls = 600; // 5 minutes max (600 * 500ms)

      while (!done && pollCount < maxPolls) {
        // Poll immediately on first iteration, then wait
        if (pollCount > 0) {
          await this.sleep(500);
        }
        pollCount++;

        if (!this.currentJobId) {
          // Job was killed
          done = true;
          break;
        }

        try {
          const pollRes = await suIpc.poll(this.currentJobId, { timeoutMs: 3000 });
          if (!pollRes) continue;

          // Show streaming output
          const output = pollRes.output || "";
          if (output.length > this.lastOutputLen) {
            this.lastOutputLen = this.appendOutput(output, this.lastOutputLen);
          }

          if (pollRes.state === "done") {
            done = true;
            if (pollRes.exitCode != null) {
              this.appendLine(`[exit ${pollRes.exitCode}]`);
            }
          }
        } catch (pollErr) {
          // Poll error, continue trying
        }
      }

      if (!done) {
        this.appendLine("[超时]");
      }
    } catch (e) {
      const msg = e && e.message ? e.message : "执行失败";
      this.appendLine(`ERR: ${msg}`);
      prompt.showToast({ message: msg, duration: 900 });
    } finally {
      this.isRunning = false;
      this.currentJobId = null;
    }
  },

  sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
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