## 项目介绍

Vela-Shell-Bridge 是一个为小米VelaOS穿戴设备设计的 QuickApp → Lua → Shell 执行桥接层。
它允许普通快应用，在严格的权限策略下，通过 Lua 守护进程执行系统级 Shell 命令。

- 文件 IPC 作为通信通道
- Lua 守护进程负责执行与回显
- JS 侧提供 su-daemon 客户端与授权应用单文件脚本
- 支持权限管理、执行日志、白名单
- 可在手表和 PC 模拟器运行

这是一个能让 QuickApp 执行系统命令 的受控提权模块。

## 目标设备 Shell 特性（NuttX / `emulator-5554`）

通过 `adb -s emulator-5554 shell` 实测：目标环境的 `sh` 更接近“精简脚本解释器”，很多常见 shell 特性不可用。

- 支持：换行/`;` 分隔、stdout 重定向 `>`/`>>`、后台 `&`（命令行尾）、`$!`、`if/then/else/fi`
- 不支持：`|`/`||`/`&&`、fd 重定向 `2>`、`grep/head/tail` 等常见工具、常见变量 `$?` `$$` `$1`...
- 注意：`$!` 会在后续命令后变化，必须立即保存；`if` 的条件里不要写 `cmd1; cmd2`（会触发 `echo: not valid in this context`）

因此异步 exec 的完成态 `exit_code` 采用 `-1` 表示“未知”（kill 为 `137`）。同步 exec 仍能返回真实 exit code。

可以用 `tools/probe-shell.ps1` 复现这套探测（默认 `emulator-5554`）。

## 开发文档

[Lua表盘应用文档](https://github.com/FangAiden/Lua_Watchface_Documentation)
[Vela JS 快应用文档](https://iot.mi.com/vela/quickapp/)

## 授权应用接入

被授权应用可直接拷贝 `tools/su-shell.js` 使用 `exec/execSync/kill` 调用 Shell。
主应用使用 `src/services/su-daemon/index.js`（含管理接口），只需 exec 可参考 `src/services/su-daemon/public.js`。

## 手机互联（Interconnect）

本项目已接入 `@system.interconnect`，可以让手机通过 interconnect 消息通道远程调用：

- Shell 执行（并保留工作目录 `cwd` 作为“上下文”）
- 任意路径文件读写（base64 分块传输）

在手表端：进入「设置」页开启 `Interconnect 远程控制`，会生成 6 位配对码（token）。手机端每次请求需携带该 token。

### 快速上手

1) 手表端：打开本应用 → 「设置」→ 开启「Interconnect 远程控制」→ 记下「配对码」
2) 手机端：建立 interconnect 连接（拿到 `conn` 对象，具备 `send()` + `onmessage`）
3) 手机端先发 `hello` 探测是否开启远程控制
4) 远程控制开启后，所有 RPC 请求都需要携带 `token`

> 注意：远程控制默认关闭；开启后等同“远程管理权限”，请妥善保管 token。

### 消息协议（VSB RPC v1）

设备之间通过 interconnect **消息**传递 JSON（对象或字符串均可；本项目的响应一定是 JSON 字符串）。

#### 请求格式

```json
{
  "v": 1,
  "id": "req_1",
  "method": "shell.exec",
  "token": "123456",
  "params": { "cmd": "ls", "sync": true, "timeoutMs": 8000 }
}
```

- `v`: 协议版本（固定 `1`）
- `id`: 请求 ID（建议全局唯一；响应会原样带回）
- `method`: 方法名（见下文）
- `token`: 配对码（远程控制开启后必填；`hello` 不需要）
- `params`: 参数对象（各方法不同）

#### 响应格式

```json
{
  "v": 1,
  "id": "req_1",
  "ok": true,
  "result": { "exitCode": 0, "output": "..." }
}
```

失败时：

```json
{
  "v": 1,
  "id": "req_1",
  "ok": false,
  "error": { "code": "AUTH_FAILED", "message": "Invalid token" },
  "message": "Invalid token"
}
```

常见错误码：

- `REMOTE_DISABLED`：手表端未开启远程控制
- `AUTH_FAILED`：token 不匹配
- `BAD_REQUEST`：参数缺失/非法
- `UNKNOWN_METHOD`：方法不存在
- `INTERNAL_ERROR`：内部异常（如 daemon busy）
- `REPLY_TOO_LARGE`：响应体过大（本项目会截断输出）

### 方法列表

- `hello`
- `shell.exec`
- `shell.getCwd` / `shell.setCwd`
- `fs.stat`
- `fs.read`
- `fs.write`

---

### hello

用途：探测服务端信息（无需 token；即使远程控制未开启也可调用）。

请求：

```json
{ "v": 1, "id": "req_hello", "method": "hello" }
```

响应：

```json
{
  "v": 1,
  "id": "req_hello",
  "ok": true,
  "result": { "server": "VelaShellBridge", "protocol": 1, "remoteEnabled": true, "hasToken": true, "ts": 1700000000000 }
}
```

---

### shell.exec

用途：执行一条 Shell 命令，并返回输出。

#### 关于“上下文”

VelaOS 上每次 `exec` 都是一个新的 `sh -c`，无法像传统终端那样保留完整上下文（变量/函数/alias/管道等）。

本项目提供的“上下文”能力：**保存工作目录 `cwd`**（按 AppId 隔离）。你可以：

- 直接执行 `cd /some/path` 来更新 `cwd`（该命令会被 daemon 拦截，不会启动子进程）
- 后续所有 `shell.exec` 都会在执行前自动 `cd <cwd>`

#### params

- `cmd`（string，必填）：要执行的命令
- `sync`（boolean，可选，默认 `true`）：同步模式能返回真实 `exitCode`；异步模式 exitCode 可能为 `-1`（受 NuttX shell 限制）
- `timeoutMs`（number，可选，默认 `15000`）：整体超时（ms）

请求示例：

```json
{ "v": 1, "id": "req_ls", "method": "shell.exec", "token": "123456", "params": { "cmd": "ls /data", "timeoutMs": 8000 } }
```

响应示例：

```json
{
  "v": 1,
  "id": "req_ls",
  "ok": true,
  "result": { "cmd": "ls /data", "mode": "sync", "exitCode": 0, "output": "...", "cwd": "/data" }
}
```

`cd` 示例：

```json
{ "v": 1, "id": "req_cd", "method": "shell.exec", "token": "123456", "params": { "cmd": "cd /data/quickapp" } }
```

---

### shell.getCwd / shell.setCwd

用途：直接读/写 daemon 记录的 `cwd`。

```json
{ "v": 1, "id": "req_getcwd", "method": "shell.getCwd", "token": "123456" }
```

```json
{ "v": 1, "id": "req_setcwd", "method": "shell.setCwd", "token": "123456", "params": { "cwd": "/data" } }
```

---

### fs.stat

用途：查询文件/目录是否存在、是否为目录、文件大小。

请求：

```json
{ "v": 1, "id": "req_stat", "method": "fs.stat", "token": "123456", "params": { "path": "/data/apps.json" } }
```

响应：

```json
{ "v": 1, "id": "req_stat", "ok": true, "result": { "path": "/data/apps.json", "exists": true, "is_dir": false, "size": 12345 } }
```

---

### fs.read（base64 分块下载）

用途：从任意路径读取文件内容（二进制安全，适合传输大文件）。

#### params

- `path`（string，必填）
- `offset`（number，可选，默认 `0`）
- `length`（number，可选，默认 `2048`，最大 `32768`）
- `encoding`（string，可选，固定 `base64`）

请求：

```json
{ "v": 1, "id": "req_read_0", "method": "fs.read", "token": "123456", "params": { "path": "/data/apps.json", "offset": 0, "length": 4096, "encoding": "base64" } }
```

响应：

```json
{
  "v": 1,
  "id": "req_read_0",
  "ok": true,
  "result": { "path": "/data/apps.json", "encoding": "base64", "offset": 0, "next_offset": 4096, "eof": false, "size": 12345, "data": "...." }
}
```

---

### fs.write（base64 分块上传）

用途：向任意路径写入文件内容（支持覆盖/追加）。

#### params

- `path`（string，必填）
- `data`（string，必填）：base64 字符串
- `mode`（string，可选）：`truncate`（覆盖写）或 `append`（追加写，默认）
- `encoding`（string，可选，固定 `base64`）

示例：写入（覆盖）一个文本文件：

```json
{ "v": 1, "id": "req_write_0", "method": "fs.write", "token": "123456", "params": { "path": "/tmp/hello.txt", "mode": "truncate", "encoding": "base64", "data": "aGVsbG8K" } }
```

响应：

```json
{ "v": 1, "id": "req_write_0", "ok": true, "result": { "path": "/tmp/hello.txt", "bytes": 6, "mode": "truncate" } }
```

---

### 例子：手机端最小 RPC 封装（伪代码）

手机侧 interconnect SDK/API 形态可能不同，但通常都有类似：

- `conn.send({ data: <string|object> })`
- `conn.onmessage = (evt) => { /* evt.data */ }`

下面示例仅演示“按 id 匹配响应”的用法：

```js
function makeId() {
  return `req_${Date.now()}_${Math.floor(Math.random() * 100000)}`;
}

function createRpc(conn) {
  const pending = new Map();

  conn.onmessage = (evt) => {
    const msg = (typeof evt.data === "string") ? JSON.parse(evt.data) : evt.data;
    const p = pending.get(msg.id);
    if (!p) return;
    pending.delete(msg.id);
    if (msg.ok) p.resolve(msg.result);
    else p.reject(new Error(msg.message || (msg.error && msg.error.message) || "RPC error"));
  };

  function call(method, params, token, timeoutMs = 15000) {
    const id = makeId();
    const req = { v: 1, id, method, token, params };

    return new Promise((resolve, reject) => {
      const t = setTimeout(() => {
        pending.delete(id);
        reject(new Error(`timeout: ${method}`));
      }, timeoutMs);

      pending.set(id, {
        resolve: (v) => { clearTimeout(t); resolve(v); },
        reject: (e) => { clearTimeout(t); reject(e); },
      });

      conn.send({ data: JSON.stringify(req) });
    });
  }

  return { call };
}
```

### 例子：远程执行 Shell（带 cwd）

```js
const rpc = createRpc(conn);
const token = "123456";

await rpc.call("hello", null, null, 3000);
await rpc.call("shell.exec", { cmd: "cd /data/quickapp" }, token);
const r = await rpc.call("shell.exec", { cmd: "ls", timeoutMs: 8000 }, token);
console.log(r.exitCode, r.cwd, r.output);
```

### 例子：下载文件（fs.read 循环直到 eof）

```js
const rpc = createRpc(conn);
const token = "123456";

let offset = 0;
const parts = [];
while (true) {
  const r = await rpc.call("fs.read", { path: "/data/apps.json", offset, length: 8192, encoding: "base64" }, token);
  // 重要：r.data 是“该分块”的 base64，不要 chunks.join("") 后一次性解码；
  // 应当逐块解码成 bytes，再拼接 bytes。
  parts.push(base64DecodeToBytes(r.data));
  offset = r.next_offset;
  if (r.eof) break;
}

// bytes = concatBytes(parts);
```

Node.js 参考实现：

```js
const parts = [];
let offset = 0;
while (true) {
  const r = await rpc.call("fs.read", { path: "/data/apps.json", offset, length: 8192, encoding: "base64" }, token);
  parts.push(Buffer.from(r.data, "base64"));
  offset = r.next_offset;
  if (r.eof) break;
}
const bytes = Buffer.concat(parts);
```

### 例子：上传文件（truncate + append 分块写入）

```js
const rpc = createRpc(conn);
const token = "123456";

// 假设 bytes 是 Uint8Array/byte[]（按你的语言环境获取）
const bytes = getBytesSomehow();

const CHUNK_BYTES = 8 * 1024; // 建议按“字节”分块，再对每块做 base64
let first = true;
for (let i = 0; i < bytes.length; i += CHUNK_BYTES) {
  const chunk = bytes.slice(i, i + CHUNK_BYTES);
  const b64 = base64EncodeBytes(chunk);

  await rpc.call("fs.write", {
    path: "/tmp/upload.bin",
    encoding: "base64",
    mode: first ? "truncate" : "append",
    data: b64
  }, token, 12000);

  first = false;
}
```

Node.js 参考实现：

```js
const fs = require("node:fs");
const bytes = fs.readFileSync("./upload.bin");

const CHUNK_BYTES = 8 * 1024;
let first = true;
for (let i = 0; i < bytes.length; i += CHUNK_BYTES) {
  const chunk = bytes.subarray(i, i + CHUNK_BYTES);
  const b64 = chunk.toString("base64");
  await rpc.call("fs.write", {
    path: "/tmp/upload.bin",
    encoding: "base64",
    mode: first ? "truncate" : "append",
    data: b64
  }, token, 12000);
  first = false;
}
```

## 流程图

### 流程 1：被授权应用（文件 IPC）执行 Shell

```mermaid
sequenceDiagram
  participant App as AppB (Authorized QuickApp)
  participant Client as tools/su-shell.js
  participant Files as AppB sandbox files<br/>/data/files/AppB/
  participant Lua as Lua Daemon<br/>ipc.run_once()
  participant Router as app/core/ipc_router.lua
  participant ExecUC as app/usecases/exec.lua
  participant Policy as app/domain/policy.lua
  participant Settings as app/domain/settings.lua
  participant ExecDom as app/domain/exec.lua
  participant Log as app/domain/log.lua

  App->>Client: exec("cd /data/quickapp; ls")
  Client->>Files: Write ipc_request_{id}.json<br/>{ type: "exec", cmd: "exec", args: { shell, sync } }
  Files->>Lua: scanned by timer
  Lua->>Router: route_request(ctx, app_id, req)
  Router->>ExecUC: handle(app_id, req, ctx)
  ExecUC->>Settings: cmd_blacklist / save_history
  ExecUC->>Policy: check_exec_allowed(app_id)
  Note right of ExecUC: "cd ..." 会被拦截为修改 cwd<br/>不启动子进程
  ExecUC->>ExecDom: start_job(shell, sync, app_id)<br/>（自动 cd cwd 后执行）
  ExecDom-->>ExecUC: { exit_code, output, cwd }
  ExecUC->>Log: record_request / record_exec_start
  ExecUC-->>Lua: response payload
  Lua->>Files: Write ipc_response_{id}.json
  Client->>Files: Read ipc_response_{id}.json
  Client-->>App: { exitCode, output, cwd }
```

### 流程 2：手机互联（Interconnect）远程执行 Shell

```mermaid
sequenceDiagram
  participant Phone as Phone App / Script
  participant IC as Interconnect Channel
  participant Bridge as QuickApp bridge<br/>services/interconnect
  participant SU as services/su-daemon (IPC client)
  participant Files as Admin sandbox files<br/>/data/files/com.super.su.aigik/
  participant Lua as Lua Daemon
  participant ExecUC as app/usecases/exec.lua

  Phone->>IC: send RPC JSON<br/>{ v, id, method:"shell.exec", token, params }
  IC->>Bridge: onmessage(data)
  Bridge->>Bridge: parse + auth(token) + dispatch
  alt REMOTE_DISABLED / AUTH_FAILED / BAD_REQUEST
    Bridge-->>IC: reply ok=false
    IC-->>Phone: onmessage(reply)
  else ok
    Bridge->>SU: suIpc.exec(cmd)
    SU->>Files: Write ipc_request_{id}.json (type=exec)
    Files->>Lua: scanned by timer
    Lua->>ExecUC: handle exec
    ExecUC-->>Lua: response { exit_code, output, cwd }
    Lua->>Files: Write ipc_response_{id}.json
    SU->>Files: Read ipc_response_{id}.json
    Bridge-->>IC: reply ok=true { exitCode, output, cwd }
    IC-->>Phone: onmessage(reply)
  end
```

### 流程 3：手机互联（Interconnect）文件读写（fs.read/fs.write）

```mermaid
sequenceDiagram
  participant Phone as Phone App / Script
  participant IC as Interconnect Channel
  participant Bridge as QuickApp bridge<br/>services/interconnect
  participant SU as services/su-daemon (IPC client)
  participant Files as Admin sandbox files<br/>/data/files/com.super.su.aigik/
  participant Lua as Lua Daemon
  participant MgmtUC as app/usecases/management.lua
  participant FS as (Lua) io.open / filesystem

  loop repeat until eof
    Phone->>IC: send RPC<br/>{ method:"fs.read", params:{path,offset,length,encoding:"base64"} }
    IC->>Bridge: onmessage(data)
    Bridge->>SU: suIpc.management("fs_read", args)
    SU->>Files: Write ipc_request_{id}.json (type=management)
    Files->>Lua: scanned by timer
    Lua->>MgmtUC: handle fs_read / fs_write / fs_stat ...
    MgmtUC->>FS: read/write bytes
    MgmtUC-->>Lua: response { data:"base64...", next_offset, eof }
    Lua->>Files: Write ipc_response_{id}.json
    SU->>Files: Read ipc_response_{id}.json
    Bridge-->>IC: reply ok=true { result }
    IC-->>Phone: onmessage(reply)
  end
```

## 架构图1（系统）

```mermaid
flowchart LR

subgraph Phone["Phone（小米穿戴 / Companion / 自定义脚本）"]
  direction TB
  PhoneConn["Interconnect connection<br/>send()/onmessage"]
  PhoneRPC["VSB RPC v1 client<br/>按 id 匹配响应"]
  PhoneConn <--> PhoneRPC
end

subgraph Watch["Watch（VelaOS）"]
  direction TB

  subgraph AdminQuickApp["Admin QuickApp：SuperSU（com.super.su.aigik）"]
    direction TB
    AppEntry["src/app.ux<br/>initInterconnectBridge()"]
    UI["pages/* + features/*<br/>UI + 业务逻辑"]
    SuClient["services/su-daemon/*<br/>IPC client: exec + management"]
    Bridge["services/interconnect/index.js<br/>RPC server + token"]
    LocalSettings["shared/settings/local-settings.js<br/>remote.enabled/token"]

    AppEntry --> Bridge
    UI --> SuClient
    UI --> LocalSettings
    Bridge --> SuClient
    Bridge --> LocalSettings
  end

  subgraph AdminFiles["Admin sandbox files<br/>/data/files/com.super.su.aigik/"]
    AdminReq["ipc_request_{id}.json"]
    AdminRes["ipc_response_{id}.json"]
  end

  subgraph AuthorizedApps["Authorized QuickApps（被授权）"]
    direction TB
    PublicJS["tools/su-shell.js（单文件客户端）"]
    PublicReq["/data/files/{AppId}/ipc_request_{id}.json"]
    PublicRes["/data/files/{AppId}/ipc_response_{id}.json"]
    PublicJS --> PublicReq
    PublicRes --> PublicJS
  end

  subgraph LuaDaemon["Lua SU Daemon（watchface）"]
    direction TB
    IPC["app/core/ipc.lua<br/>scan requests + write responses"]
    Router["app/core/ipc_router.lua"]
    ExecUC["usecases/exec.lua<br/>policy + blacklist + cd"]
    MgmtUC["usecases/management.lua<br/>policies + allowlist + settings + fs_* + env"]

    ExecDom["domain/exec.lua<br/>jobs + per-app cwd"]
    Policy["domain/policy.lua"]
    Allowlist["domain/allowlist.lua"]
    SettingsDom["domain/settings.lua"]
    LogDom["domain/log.lua"]
    ScanMod["domain/app_scan.lua"]
  end

  subgraph Data["Lua data（persist）"]
    Policies["data/policies.json"]
    Allow["data/allowlist.json"]
    SettingsJson["data/settings.json"]
    Logs["data/requests_log.json"]
    ExecLogs["data/exec_logs.json"]
  end

  subgraph Jobs["Job tmp files"]
    JobDir["tmp/su_jobs/job_{id}.*<br/>.sh/.out/.status/.pid"]
  end
end

PhoneConn <--> Bridge

SuClient --> AdminReq
AdminRes --> SuClient

PublicReq --> IPC
IPC --> PublicRes

AdminReq --> IPC
IPC --> AdminRes

Allowlist -- scan list --> IPC

IPC --> Router
Router --> ExecUC
Router --> MgmtUC

ExecUC --> ExecDom
ExecUC --> Policy
ExecUC --> SettingsDom
ExecUC --> LogDom

MgmtUC --> Policy
MgmtUC --> Allowlist
MgmtUC --> SettingsDom
MgmtUC --> LogDom
MgmtUC --> ScanMod

Policy --> Policies
Allowlist --> Allow
SettingsDom --> SettingsJson
LogDom --> Logs
LogDom --> ExecLogs
ExecDom --> JobDir

```

## 架构图2（JS 侧）

```mermaid
flowchart TB
  AppEntry["src/app.ux<br/>onCreate()"]
  InterconnectAPI["@system.interconnect"]
  Bridge["services/interconnect/index.js<br/>RPC server + token"]
  SuDaemon["services/su-daemon/*<br/>IPC client"]
  LocalSettings["shared/settings/local-settings.js<br/>remote + ui + ipc + ime"]

  subgraph Pages["视图层 pages/*.ux"]
    Ux["index/perm/file/shell/setting/log/about/..."]
  end

  subgraph Features["功能层 features/*/page.js"]
    F["index/perm/file/shell/setting/log/about/..."]
  end

  Base["app/page.js<br/>createPage()"]
  Shared["shared/*<br/>utils + ui/page-transition"]
  UI["ui/components/*"]

  AppEntry --> Bridge
  Bridge --> InterconnectAPI
  Bridge --> SuDaemon
  Bridge --> LocalSettings

  Pages --> Features
  Pages --> UI
  Features --> Base
  Features --> Shared
  Features --> LocalSettings
  Features --> SuDaemon
```
