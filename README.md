## 项目介绍

Vela-Shell-Bridge 是一个为小米VelaOS穿戴设备设计的 QuickApp → Lua → Shell 执行桥接层。
它允许普通快应用，在严格的权限策略下，通过 Lua 守护进程执行系统级 Shell 命令。

- 文件 IPC 作为通信通道
- Lua 守护进程负责执行与回显
- 支持权限管理、执行日志、白名单
- 可在手表和 PC 模拟器运行

这是一个能让 QuickApp 执行系统命令 的受控提权模块。

## 开发文档

[Lua表盘应用文档](https://github.com/FangAiden/Lua_Watchface_Documentation)
[Vela JS 快应用文档](https://iot.mi.com/vela/quickapp/)

## 流程图

```mermaid
sequenceDiagram
  participant B as AppB (QuickApp)
  participant FS as QuickApp File System<br/>/data/quickapp/files/AppB/
  participant L as Lua Daemon<br/>ipc.run_once()
  participant EX as exec.lua
  participant LOG as log.lua

  B->>FS: Write ipc_request_7.json<br/>{ type: "exec", args: "ls" }
  FS->>L: Detected on next ipc.run_once()
  L->>EX: exec("ls")
  EX->>EX: os.execute("ls > tmp")
  EX->>L: return { exit_code, output }
  L->>LOG: record count + last_ts
  L->>FS: Write ipc_response_7.json
  L->>FS: Delete ipc_request_7.json
  FS->>B: AppB reads response file
```

## 架构图1

```mermaid
flowchart LR

%% -------------------------------
%% Android phone
%% -------------------------------
subgraph Android["Android phone"]
  AApp["Android companion app<br/>Permission manager / Debug UI"]
  ABridge["Communicates with AppA via QuickApp APIs<br/>(No direct file IPC)"]
  AApp --> ABridge
end

%% -------------------------------
%% Watch - Real Device
%% -------------------------------
subgraph Watch["Watch - Real Device"]
  direction LR

  %% QuickApps
  subgraph QuickApps["QuickApp Sandboxes<br/>Path: /data/quickapp/files/AppId/"]
    direction TB

    subgraph AppA["AppA (Admin Manager)<br/>AppId = ADMIN_APP_ID"]
      AppA_Req["ipc_request_{id}.json"]
      AppA_Res["ipc_response_{id}.json"]
    end

    subgraph AppB["AppB (Normal App)<br/>AppId = any.other.app"]
      AppB_Req["ipc_request_{id}.json"]
      AppB_Res["ipc_response_{id}.json"]
    end
  end

  %% Lua Watchface Daemon
  subgraph LuaDaemon["Lua SU Daemon (Watchface)<br/>Base Dir:<br/>/data/app/watchface/market/167210065/lua"]
    direction TB

    UI["app.lua<br/>Watchface UI + Daemon bootstrap<br/>- Time Label<br/>- Log Textarea<br/>- 3 Debug Buttons<br/>- Start lvgl.Timer → ipc.run_once()"]

    subgraph Core["core/"]
      CoreIPC["ipc.lua<br/>File IPC router<br/>- Read request JSON<br/>- Route to domain<br/>- Write response JSON"]
    end

    subgraph Domain["domain/"]
      Policy["policy.lua<br/>allow / deny / ask / allow_once<br/>Backed by policies.json"]
      Allowlist["allowlist.lua<br/>Allowed App List<br/>Backed by allowlist.json"]
      LogMod["log.lua<br/>Per-app request stats<br/>Backed by requests_log.json"]
      ExecMod["exec.lua<br/>os.execute() wrapper<br/>Redirect output to tmp file"]
      ScanMod["app_scan.lua<br/>Scan QuickApp dirs for AppIds"]
    end

    subgraph Util["util/"]
      FSUtil["fs_util.lua<br/>read/write/remove file<br/>list_dirs: cd DIR && ls (no flags)<br/>atomic write via .tmp → rename"]
      JSONUtil["json_util.lua<br/>JSON.toString / JSON.toJSON"]
    end

    subgraph Data["data/ (persistent)"]
      DF_Policies["policies.json"]
      DF_Allowlist["allowlist.json"]
      DF_ReqLog["requests_log.json"]
    end
  end

  %% Connections inside Lua daemon
  UI --> CoreIPC
  CoreIPC --> Policy
  CoreIPC --> Allowlist
  CoreIPC --> LogMod
  CoreIPC --> ExecMod
  CoreIPC --> ScanMod
  CoreIPC --> FSUtil
  CoreIPC --> JSONUtil

  Policy --> DF_Policies
  Allowlist --> DF_Allowlist
  LogMod --> DF_ReqLog

  %% File IPC connections
  AppA_Req --> CoreIPC
  CoreIPC --> AppA_Res

  AppB_Req --> CoreIPC
  CoreIPC --> AppB_Res
end

%% -------------------------------
%% Simulator (Dev PC)
%% -------------------------------
subgraph Sim["Dev PC / Simulator (Lua Only)"]
  SimApp["app/app.lua<br/>Simulator UI + Timer"]
  SimIPC["app/core/ipc.lua"]
  SimDomain["app/domain/*"]
  SimUtil["app/util/*"]
  SimData["app/data/* (optional)"]

  SimApp --> SimIPC
  SimIPC --> SimDomain
  SimIPC --> SimUtil
end

```

## 架构图2

```mermaid
graph TB

    %% ===== 上层：快应用 =====
    subgraph Apps["快应用层"]
        AppA["AppA 权限管理器"]
        AppB["AppB 普通应用"]
    end

    %% ===== 中间：每个应用自己的 IPC 文件 =====
    subgraph FS["文件 IPC 层 每个应用各自沙盒"]
        AReq["A ipc_request.json"]
        AResp["A ipc_response.json"]
        BReq["B ipc_request.json"]
        BResp["B ipc_response.json"]
    end

    %% ===== 下层：Lua 守护进程 + 系统 =====
    subgraph Lua["Lua 表盘守护进程"]
        IPC["IPC 管理"]
        Policy["权限策略管理"]
        Log["请求日志管理"]
        Exec["Shell 执行"]
    end

    System["NuttX 系统 层"]

    %% --- AppA：只发管理命令、读管理结果 ---
    AppA --> AReq
    AResp --> AppA

    %% --- AppB：只发执行命令、读执行结果 ---
    AppB --> BReq
    BResp --> AppB

    %% --- Lua 只从请求文件读入 ---
    AReq --> IPC
    BReq --> IPC

    %% --- IPC 把管理类命令交给策略模块和日志模块 ---
    IPC --> Policy
    IPC --> Log

    %% --- IPC 把 exec 命令交给执行模块 ---
    IPC --> Exec

    %% --- 权限策略会影响执行结果（在 Exec 内部检查） ---
    Policy --> Exec

    %% --- Exec 执行完成后写回响应文件 ---
    Exec --> BResp

    %% --- 策略查询或变更的结果写回给 AppA ---
    Policy --> AResp

    %% --- Exec 真正通过 os.execute 调系统 ---
    Exec --> System

    %% --- 日志模块只和 Lua 内部日志有关 不单独连应用 ---
    Log --> IPC
```
