import { sendIpcRequest } from "./ipc-client.js";

const REQUEST_TIMEOUT = 1250;

export function management(cmd, args = {}, options = {}) {
  if (!cmd || typeof cmd !== "string") return Promise.reject(new Error("cmd required"));
  return sendIpcRequest(
    { type: "management", cmd, args: args || {} },
    { timeoutMs: options.timeoutMs || REQUEST_TIMEOUT }
  );
}

export async function getLogs(options = {}) {
  const resp = await management("get_logs", {}, options);
  if (!resp || resp.ok !== true) throw new Error((resp && resp.message) || "get_logs failed");
  return resp.data;
}

export async function clearLogs(options = {}) {
  const resp = await management("clear_logs", {}, options);
  if (!resp || resp.ok !== true) throw new Error((resp && resp.message) || "clear_logs failed");
  return resp.data;
}

export async function getPolicies(options = {}) {
  const resp = await management("get_policies", {}, options);
  if (!resp || resp.ok !== true) throw new Error((resp && resp.message) || "get_policies failed");
  return resp.data || {};
}

export async function getEnv(options = {}) {
  const resp = await management("get_env", {}, options);
  if (!resp || resp.ok !== true) throw new Error((resp && resp.message) || "get_env failed");
  return resp.data || {};
}

export async function setPolicy(appId, policy, options = {}) {
  if (!appId) throw new Error("appId required");
  if (!policy) throw new Error("policy required");
  const resp = await management("set_policy", { app_id: appId, policy }, options);
  if (!resp || resp.ok !== true) throw new Error((resp && resp.message) || "set_policy failed");
  return resp.data;
}

export async function getAllowlist(options = {}) {
  const resp = await management("get_allowlist", {}, options);
  if (!resp || resp.ok !== true) throw new Error((resp && resp.message) || "get_allowlist failed");
  const data = resp.data || {};
  const list = data.allowlist;
  return Array.isArray(list) ? list : [];
}

export async function setAllowlist(list, options = {}) {
  const resp = await management(
    "set_allowlist",
    { allowlist: Array.isArray(list) ? list : [] },
    options
  );
  if (!resp || resp.ok !== true) throw new Error((resp && resp.message) || "set_allowlist failed");
  return resp.data;
}

export async function scanApps(options = {}) {
  const resp = await management("scan_apps", {}, options);
  if (!resp || resp.ok !== true) throw new Error((resp && resp.message) || "scan_apps failed");
  const data = resp.data || {};
  const apps = data.apps;
  return Array.isArray(apps) ? apps : [];
}

export async function scanAppsInfo(options = {}) {
  const resp = await management("scan_apps", {}, options);
  if (!resp || resp.ok !== true) throw new Error((resp && resp.message) || "scan_apps failed");
  const data = resp.data || {};
  const apps = Array.isArray(data.apps) ? data.apps : [];
  const meta = data.meta && typeof data.meta === "object" ? data.meta : {};
  return { apps, meta };
}
