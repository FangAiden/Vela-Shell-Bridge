import { createExecClient } from "./exec-client.js";
import { DaemonUnavailableError } from "./ipc-client.js";
import * as management from "./management-client.js";
import { getLocalSettings } from "../../shared/settings/local-settings.js";

const STATUS_POLL_INTERVAL = 200;

function clampInt(n, minv, maxv, fallback) {
  const v = Math.floor(Number(n));
  if (!isFinite(v)) return fallback;
  if (v < minv) return minv;
  if (v > maxv) return maxv;
  return v;
}

const execClient = createExecClient({
  defaultPollInterval: STATUS_POLL_INTERVAL,
  resolvePollInterval: async () => {
    try {
      const local = await getLocalSettings();
      if (local && local.ipc) {
        return clampInt(local.ipc.jsPollIntervalMs, 50, 2000, STATUS_POLL_INTERVAL);
      }
    } catch (_) {}
    return STATUS_POLL_INTERVAL;
  },
});

const suIpc = {
  exec: execClient.exec,
  kill: execClient.kill,
  management: management.management,
  getLogs: management.getLogs,
  clearLogs: management.clearLogs,
  getPolicies: management.getPolicies,
  getEnv: management.getEnv,
  setPolicy: management.setPolicy,
  getAllowlist: management.getAllowlist,
  setAllowlist: management.setAllowlist,
  scanApps: management.scanApps,
  scanAppsInfo: management.scanAppsInfo,
};

function suExecCompat(cmd, options) {
  return execClient.exec(cmd, options);
}

Object.assign(suExecCompat, suIpc);

export default suExecCompat;
export { DaemonUnavailableError };
