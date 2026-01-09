import { createPage } from "../../app/page.js";

export default createPage({
  data: {
    inputbox: "",
    showStatus: "flex",
    hide: false
  },
  changeState() {
    this.showStatus = "flex";
    this.hide = !this.hide;
  },
  onComplete(e) {
    const detail = e && e.detail ? e.detail : {};
    const content = String(detail.content == null ? "" : detail.content);
    if (!content) return;
    this.inputbox = String(this.inputbox == null ? "" : this.inputbox) + content;
  },
  onDelete() {
    const cur = String(this.inputbox == null ? "" : this.inputbox);
    this.inputbox = cur.slice(0, -1);
  },
  finishInput() {
    this.hide = true;
    this.showStatus = "none";
  }
});
