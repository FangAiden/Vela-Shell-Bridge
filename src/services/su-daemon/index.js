import { createExecClient } from "./exec-client.js";
import { DaemonUnavailableError } from "./ipc-client.js";
import * as management from "./management-client.js";

const execClient = createExecClient();

const suIpc = {
  exec: execClient.exec,
  poll: execClient.poll,
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
