import { sendIpcRequest } from "./ipc-client.js";

const REQUEST_TIMEOUT = 1500;
const EXEC_OVERALL_TIMEOUT = 30000;
const STATUS_POLL_INTERVAL = 200;

let busy = false;

export function createExecClient() {
  async function exec(shellCmd, options = {}) {
    if (!shellCmd || typeof shellCmd !== "string") {
      throw new Error("Cmd required");
    }

    const isSync = options.sync === true;

    // For async mode without wait, don't block
    if (!isSync && options.wait === false) {
      return doExecStart(shellCmd, false);
    }

    if (busy) {
      throw new Error("BUSY: Previous command running");
    }

    busy = true;
    try {
      return await doExec(shellCmd, options);
    } finally {
      busy = false;
    }
  }

  async function doExecStart(shellCmd, isSync) {
    const startResp = await sendIpcRequest(
      {
        type: "exec",
        cmd: "exec",
        args: { shell: shellCmd, sync: isSync },
      },
      { timeoutMs: REQUEST_TIMEOUT }
    );

    if (!startResp.ok) {
      throw new Error(startResp.message || "Exec start failed");
    }

    return {
      ok: true,
      jobId: startResp.job_id,
      state: startResp.state,
      raw: startResp,
    };
  }

  async function doExec(shellCmd, options) {
    const isSync = options.sync === true;
    const onProgress = options.onProgress;
    const onStart = options.onStart;
    const overallTimeoutMs = options.timeoutMs || EXEC_OVERALL_TIMEOUT;
    const pollInterval = options.statusPollInterval || STATUS_POLL_INTERVAL;

    // Start execution
    const startResp = await sendIpcRequest(
      {
        type: "exec",
        cmd: "exec",
        args: { shell: shellCmd, sync: isSync },
      },
      { timeoutMs: isSync ? overallTimeoutMs + 2000 : REQUEST_TIMEOUT }
    );

    if (!startResp.ok) {
      throw new Error(startResp.message || "Exec start failed");
    }

    if (startResp.job_id && typeof onStart === "function") {
      try {
        onStart(startResp.job_id);
      } catch (_) {}
    }

    // Sync mode: return immediately
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

    // Async mode: poll for completion
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

      if (!stResp.ok) {
        throw new Error(stResp.message || "Status failed");
      }

      // Progress callback
      if (stResp.result && typeof onProgress === "function") {
        const { output, pid } = stResp.result;
        if (output || pid) {
          try {
            onProgress(output, jobId, pid);
          } catch (_) {}
        }
      }

      // Done
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
  }

  async function poll(jobId, options = {}) {
    if (!jobId) throw new Error("jobId required");

    const resp = await sendIpcRequest(
      {
        type: "exec",
        cmd: "exec",
        args: { job_id: jobId },
      },
      { timeoutMs: options.timeoutMs || REQUEST_TIMEOUT }
    );

    if (!resp.ok) {
      throw new Error(resp.message || "Poll failed");
    }

    const data = resp.result || {};
    return {
      ok: true,
      jobId,
      state: resp.state,
      output: data.output || "",
      exitCode: data.exit_code,
      pid: data.pid,
      raw: resp,
    };
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

  return { exec, poll, kill };
}
