import { createExecClient } from "./exec-client.js";
import { DaemonUnavailableError } from "./ipc-client.js";

const STATUS_POLL_INTERVAL = 200;

const execClient = createExecClient({
  defaultPollInterval: STATUS_POLL_INTERVAL,
});

const suIpc = {
  exec: execClient.exec,
  kill: execClient.kill,
};

function suExecCompat(cmd, options) {
  return execClient.exec(cmd, options);
}

Object.assign(suExecCompat, suIpc);

export default suExecCompat;
export { DaemonUnavailableError };
