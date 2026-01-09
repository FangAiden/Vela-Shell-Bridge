import { sendIpcRequest } from "./ipc-client.js";

const REQUEST_TIMEOUT = 1250;
const EXEC_OVERALL_TIMEOUT = 30000;
const STATUS_POLL_INTERVAL = 200;

let currentExecution = null;

function runExclusive(taskFn) {
  if (currentExecution) return Promise.reject(new Error("BUSY: Previous command running"));
  const p = Promise.resolve().then(taskFn);
  currentExecution = p;
  const unlock = () => {
    if (currentExecution === p) currentExecution = null;
  };
  return p.then(
    (v) => {
      unlock();
      return v;
    },
    (e) => {
      unlock();
      throw e;
    }
  );
}

function clampInt(n, minv, maxv, fallback) {
  const v = Math.floor(Number(n));
  if (!isFinite(v)) return fallback;
  if (v < minv) return minv;
  if (v > maxv) return maxv;
  return v;
}

export function createExecClient(options = {}) {
  const resolvePollInterval = options.resolvePollInterval;
  const defaultPollInterval = options.defaultPollInterval || STATUS_POLL_INTERVAL;

  async function getPollInterval(userOptions) {
    let pollInterval = defaultPollInterval;
    if (typeof resolvePollInterval === "function") {
      try {
        const resolved = await resolvePollInterval();
        if (resolved != null) pollInterval = resolved;
      } catch (_) {}
    }
    return clampInt(
      userOptions && userOptions.statusPollInterval,
      50,
      2000,
      pollInterval
    );
  }

  function exec(shellCmd, options = {}) {
    if (!shellCmd || typeof shellCmd !== "string") {
      return Promise.reject(new Error("Cmd required"));
    }

    const isSync = options.sync === true;
    const onProgress = options.onProgress;
    const onStart = options.onStart;
    const overallTimeoutMs = options.timeoutMs || EXEC_OVERALL_TIMEOUT;

    return runExclusive(async () => {
      const pollInterval = await getPollInterval(options);

      let startResp;
      startResp = await sendIpcRequest(
        {
          type: "exec",
          cmd: "exec",
          args: { shell: shellCmd, sync: isSync },
        },
        { timeoutMs: isSync ? overallTimeoutMs + 2000 : REQUEST_TIMEOUT }
      );

      if (!startResp.ok) throw new Error(startResp.message || "Exec start failed");

      if (startResp.job_id && typeof onStart === "function") {
        try {
          onStart(startResp.job_id);
        } catch (_) {}
      }

      if (isSync) {
        const data = startResp.result || startResp.data || {};
        return {
          id: startResp.id,
          ok: true,
          mode: "sync",
          exitCode: data.exit_code,
          output: data.output,
          raw: startResp,
        };
      }

      const jobId = startResp.job_id;
      const startTime = Date.now();

      while (true) {
        if (Date.now() - startTime > overallTimeoutMs) {
          throw new Error(`Timeout ${overallTimeoutMs}ms`);
        }
        await new Promise((r) => setTimeout(r, pollInterval));

        const stResp = await sendIpcRequest(
          {
            type: "exec",
            cmd: "exec",
            args: { job_id: jobId },
          },
          { timeoutMs: REQUEST_TIMEOUT }
        );

        if (!stResp.ok) throw new Error(stResp.message || "Status failed");

        if (stResp.result) {
          const { output, pid } = stResp.result;
          if (typeof onProgress === "function" && (output || pid)) {
            try {
              onProgress(output, jobId, pid);
            } catch (_) {}
          }
        }

        if (stResp.state === "done") {
          const data = stResp.result || {};
          return {
            id: stResp.id,
            ok: true,
            mode: "async",
            jobId,
            exitCode: data.exit_code,
            output: data.output,
            pid: data.pid,
            raw: stResp,
          };
        }
      }
    });
  }

  function kill(jobId) {
    if (!jobId) return Promise.reject(new Error("jobId required"));
    return sendIpcRequest(
      { type: "exec", cmd: "kill", args: { job_id: jobId } },
      { timeoutMs: REQUEST_TIMEOUT * 2 }
    ).then((resp) => {
      if (!resp.ok) throw new Error(resp.message || "kill failed");
      return resp.data || resp;
    });
  }

  return { exec, kill };
}
