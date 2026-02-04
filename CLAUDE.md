# CLAUDE.md

## 项目概述

Vela-Shell-Bridge (VSB) 是运行在小米 VelaOS 智能手表上的权限管控 Shell 执行桥，由两部分组成：

1. **Lua 守护进程** — 以表盘 (watchface) 形式常驻，负责 IPC 轮询、Shell 命令执行、权限管控、日志记录
2. **QuickApp (JS) 客户端** — 提供管理 UI (终端、权限管理、文件管理器等) 和手机远程控制桥

两者通过**文件 IPC 协议**通信：JS 端写 JSON 请求文件，Lua 端轮询读取并写回响应。

## 关键限制

- `io.popen` 不可用 — 需要 `os.execute("cmd > /tmp/out.txt")` + `io.open` 读取
- LVGL 仅 11 个控件可用 (Arc/Bar/Slider/Switch 等均不可用)
- 未知特性需在按钮回调中测试，避免初始化阶段 Panic 循环重启
- NuttX nsh 不支持: `&&` `||` · `$()` · `2>` · `for` · glob · 函数定义

## 技术栈

| 层 | 技术 |
|---|---|
| 管理端 UI | JavaScript + UX 模板 (VelaOS QuickApp 框架) |
| 守护进程 | Lua + LVGL 9 (表盘应用) |
| 构建工具 | aiot-toolkit v2.0.4 + JSC 编译 |
| 部署脚本 | PowerShell (.ps1)，通过 ADB 推送 |
| 目标平台 | NuttX (VelaOS)，支持真机和模拟器 |
| 图片处理 | Python (Pillow, pypng, pngquant, lz4) |

## 项目结构

```
src/                              # QuickApp (JS) 源码
├── app.ux                        # 应用入口
├── app/page.js                   # 页面工厂 createPage()
├── pages/                        # 9 个 UX 视图模板
│   ├── index/  shell/  perm/     #   主页 · 终端 · 权限管理
│   ├── file/  setting/  log/     #   文件管理 · 设置 · 日志
│   └── about/  saver/  test/     #   设备信息 · 屏保 · 测试
├── features/                     # 业务逻辑 (与 pages/ 一一对应)
│   └── {page}/page.js            #   每页独立逻辑入口
├── services/
│   ├── su-daemon/                # IPC 客户端 (ipc-client/exec-client/management-client)
│   └── interconnect/index.js     # 手机远程 RPC 桥
├── shared/                       # 设置持久化 · 转场动画 · 工具函数
└── ui/components/                # timeBar · iconText · InputMethod

watchface/fprj/app/lua/           # Lua 守护进程源码
├── main.lua                      # 入口: LVGL UI + 守护定时器
├── su_config.lua                 # 全局常量
├── core/                         # IPC 基础设施 (ipc/router/responses/context/json)
├── domain/                       # 业务逻辑 (exec/policy/allowlist/settings/log/app_scan)
├── util/                         # 工具 (fs/str/base64/json/store/log/num)
└── data/                         # 运行时持久化数据

docs/                             # Lua 开发文档 (本地，直接读取)
scripts/                          # 部署脚本 (pushlua/build_face/reloader 等)
bin/                              # 构建输出
```

## 常用命令

```bash
npm start            # 开发模式 (watch + JSC)
npm run build        # 构建 QuickApp
npm run release      # 发布构建
npm run lint         # ESLint 检查修复 src/ 下 .ux/.js
```

```powershell
.\scripts\pushlua.ps1          # 推送 Lua 到设备 (完整部署 + 重启)
.\scripts\pushlua.ps1 -Hot     # 热重载推送 (不重启)
.\scripts\build_face.ps1       # 编译 .face 表盘二进制
```

## 架构

### 文件 IPC 协议

每个应用在 `/data/files/{app_id}/` 下有两个固定文件：
- `ipc_in.json` — JS 写入请求 (文件存在 = 请求待处理)
- `ipc_out.json` — Lua 写入响应

**Lua 端主循环 (ipc.lua `run_once()`)**:
1. 检查 ADMIN_APP_ID 的 `ipc_in.json`
2. 遍历 allowlist 中所有已启用应用的 `ipc_in.json`
3. 对每个请求：读取 → **立即删除** → 路由处理 → 写响应
4. 刷新所有脏数据存储

**JS 端 (ipc-client.js)**: 写请求到 `internal://files/ipc_in.json`，80ms 间隔轮询响应，单请求队列防竞态，默认超时 1500ms。

**请求格式**:
```json
{ "id": "timestamp_random", "type": "exec|management", "cmd": "...", "args": {...} }
```

### 请求路由 (ipc_router.lua)

**exec 类型**:
- `args.shell` → 执行命令 (黑名单检查 → 权限检查 → 同步/异步执行)
- `args.job_id` → 轮询作业状态
- `cmd == "kill"` → 终止作业

**management 类型** (仅限 ADMIN_APP_ID):
- `get_policies` / `set_policy` — 权限策略 CRUD
- `get_allowlist` / `set_allowlist` — 白名单管理
- `get_settings` / `set_settings` — 守护进程设置
- `get_logs` / `clear_logs` — 执行日志
- `scan_apps` — 扫描已安装应用
- `get_env` — 获取环境信息
- `shell_get_cwd` / `shell_set_cwd` — 工作目录管理
- `fs_stat` / `fs_read` / `fs_write` — 文件操作 (base64 编码)

### Shell 执行引擎 (domain/exec.lua)

**同步执行**: `cd {cwd}; {cmd} > {out_file}` → 读取输出 → 解析退出码 → 清理。多行命令合并为 `;` 分隔。

**异步执行**: 生成 wrapper 脚本并后台运行 (`sh wrapper.sh &`)：
```bash
cat /proc/self/status > {pid_file}   # 捕获 PID
cd {cwd}
if sh -c '{escaped_cmd}' >> {out_file}
then echo 0 > {status_file}
else echo 1 > {status_file}
fi
```
产生 5 个作业文件: `_wrapper.sh`, `.out`, `.status`, `.pid`, `.owner`

**cd 命令**: 特殊处理，每应用独立 CWD_MAP (内存中)，支持相对路径，不创建作业。

**作业管理**: 通过 `/proc/{pid}/status` 判断存活，kill 发送 `kill -9` 写退出码 137，作业所有权校验（仅创建者或 admin 可操作）。

**退出码**: `os.execute()` 返回 wait() 格式 (code >> 8)，Lua 端归一化。

### 权限模型 (domain/policy.lua)

| 策略 | 行为 | 持久化 |
|------|------|--------|
| `allow` | 始终允许 | 持久 (policies.json) |
| `deny` | 始终拒绝 | 持久 |
| `ask` | 需要用户确认 (默认) | 持久 |
| `allow_once` | 允许一次后恢复 ask | 临时 (session 表) |
| `allow_until_reboot` | 会话内允许 | 临时 |

检查顺序：session 表 (临时覆盖) → 持久策略。

### 远程控制 RPC (interconnect/index.js)

手机通过 interconnect (WebSocket) 远程操控手表：
- 6 位 token 认证
- 方法: `hello`, `shell.exec`, `fs.read`, `fs.write`, `fs.stat`, `shell.getCwd`, `shell.setCwd`
- 响应超过 12KB 截断
- 错误码: `REMOTE_DISABLED`, `AUTH_FAILED`, `BAD_REQUEST`, `UNKNOWN_METHOD`, `INTERNAL_ERROR`

## NuttX Shell 能力 (模拟器实测)

**支持** ✅:
`;` 分隔 · `>` `>>` 重定向 · `&` 后台 · `|` 管道 (可链式) · `$VAR` 变量展开 · `$?` 退出码 · 反引号替换 · `if/then/else/fi` · `while/do/done` · `[ ]`/`test` · `alias` · `set`/`unset` · `source` · `sh script.sh`

**不支持** ❌:
`&&` `||` 逻辑链 · `2>` stderr 重定向 · `$()` 命令替换 · `$$` PID · `for` 循环 · `*` `?` glob 通配符 · 函数定义

**常用内置应用**: `lua` · `qjs` · `iwasm` · `curl` · `ping` · `tar` · `gzip` · `unzip` · `getprop`/`setprop` · `pm`/`am` · `ffmpeg`

> 完整命令参考: [docs/shell/overview.md](docs/shell/overview.md)

**文件系统**:

| 路径 | 类型 | 说明 |
|------|------|------|
| `/data/` | fatfs | 唯一可写分区 (含 `files/` 沙箱、`quickapp/`、`apps.json`) |
| `/tmp/` | tmpfs | 内存临时目录 (重启清空) |
| `/proc/` | procfs | 进程信息 (含 `/proc/self/status`) |
| 其余 (`/etc/`, `/system/`, `/resource/` 等) | romfs | 只读 |

## 配置与数据

- **`su_config.lua`** — 守护进程全局常量 (路径、应用 ID、轮询间隔范围、输出/日志限制)
- **`local-settings.js`** — JS 端本地设置 (UI/远程控制/Shell模式/输入法)，内存缓存 + storage 持久化
- **`watchface.config.json`** — 构建配置 (projectName/watchfaceId/lvgl版本)，`sync_watchface_config.ps1` 同步到 .fprj 和 main.lua
- **`data/` 目录** — 运行时持久化文件 (policies/allowlist/settings/logs)，通过 `util/store.lua` 管理：脏标记 + 按需刷盘 + 原子写入 (.tmp → rename)

## 前端架构

所有页面通过 `createPage()` 工厂创建 (`app/page.js`)，自动注入转场动画和返回键处理。视图层在 `pages/`，业务逻辑在 `features/`，一一对应。

自定义组件: **timeBar** (时间栏) · **iconText** (主页卡片) · **InputMethod** (QWERTY/T9 输入法，适配圆形/方形/药丸屏)

## 代码约定

**JavaScript**:
- ES6+ 模块，async/await，camelCase
- 超时包装: `new Promise` + `setTimeout` + `done` 标志防重入
- Shell 转义: `shellEscape(text) → '${text.replace(/'/g, "'\\''")}'`
- 输出缓冲: 140 行循环缓冲 (splice)

**Lua**:
- 模块模式: `local M = {} ... return M`，snake_case 函数，UPPER_CASE 常量
- `pcall()` 包裹所有外部调用
- 懒加载 require 避免循环依赖 (util/log.lua)
- 无 lfs 依赖，目录判断: `io.open(path .. "/.") ~= nil` 或 `cd` 回写

## 开发工作流

### 热重载

`pushlua.ps1 -Hot` 注入 `scripts/reloader.lua` 为设备上的 main.lua：
- 跟踪用户代码创建的 timer/animation/subscription 资源
- 监控 `.hotreload/` 目录时间戳变化触发重载
- 重载时：清理资源 → 卸载用户模块 (保留核心) → 重新 require
- 失败时捕获错误堆栈并恢复

### 模拟器

基于 QEMU 的 Android 模拟器 (v32.1.15)，运行 NuttX VelaOS。系统崩溃会自动重启。

- 设备: `emulator-5554`，圆形屏 320dpi
- 网络: `10.0.2.15/24` (网关 `10.0.2.2`)
- Shell: `adb -s emulator-5554 shell "command"`
- 虚拟硬件控制: `adb emu`

## 参考文档

### QuickApp JS API

引入方式: `import module from '@system.module'`

**网络**: [Interconnect](https://iot.mi.com/vela/quickapp/zh/features/network/interconnect.html) · [Fetch](https://iot.mi.com/vela/quickapp/zh/features/network/fetch.html) · [Download](https://iot.mi.com/vela/quickapp/zh/features/network/download.html) · [Upload](https://iot.mi.com/vela/quickapp/zh/features/network/uploadtask.html) · [WebSocket](https://iot.mi.com/vela/quickapp/zh/features/network/websocket.html)

**文件/存储**: [File](https://iot.mi.com/vela/quickapp/zh/features/file/file.html) (`internal://` 路径读写) · [Storage](https://iot.mi.com/vela/quickapp/zh/features/file/storage.html) (KV 存储)

**基础**: [App](https://iot.mi.com/vela/quickapp/zh/features/basic/app.html) · [Router](https://iot.mi.com/vela/quickapp/zh/features/basic/router.html) · [Device](https://iot.mi.com/vela/quickapp/zh/features/basic/device.html) · [Configuration](https://iot.mi.com/vela/quickapp/zh/features/basic/configuration.html)

**系统**: [Notification](https://iot.mi.com/vela/quickapp/zh/features/system/notification.html) · [Vibrator](https://iot.mi.com/vela/quickapp/zh/features/system/vibrator.html) · [Sensor](https://iot.mi.com/vela/quickapp/zh/features/system/sensor.html) · [Geolocation](https://iot.mi.com/vela/quickapp/zh/features/system/geolocation.html) · [Battery](https://iot.mi.com/vela/quickapp/zh/features/system/battery.html) · [Network](https://iot.mi.com/vela/quickapp/zh/features/system/network.html) · [Brightness](https://iot.mi.com/vela/quickapp/zh/features/system/brightness.html) · [Volume](https://iot.mi.com/vela/quickapp/zh/features/system/volume.html) · [Record](https://iot.mi.com/vela/quickapp/zh/features/system/record.html) · [Clipboard](https://iot.mi.com/vela/quickapp/zh/features/system/clipboard.html)

**其他**: [Prompt](https://iot.mi.com/vela/quickapp/zh/features/other/prompt.html) · [Audio](https://iot.mi.com/vela/quickapp/zh/features/media/audio.html) · [Cipher](https://iot.mi.com/vela/quickapp/zh/features/system/cipher.html)

**UI 组件**: [div](https://iot.mi.com/vela/quickapp/zh/component/container/div.html) · [list](https://iot.mi.com/vela/quickapp/zh/component/container/list.html) · [list-item](https://iot.mi.com/vela/quickapp/zh/component/container/list-item.html) · [swiper](https://iot.mi.com/vela/quickapp/zh/component/container/swiper.html) · [stack](https://iot.mi.com/vela/quickapp/zh/component/container/stack.html) · [refresh](https://iot.mi.com/vela/quickapp/zh/component/container/refresh.html) · [text](https://iot.mi.com/vela/quickapp/zh/component/basic/text.html) · [image](https://iot.mi.com/vela/quickapp/zh/component/basic/image.html) · [progress](https://iot.mi.com/vela/quickapp/zh/component/basic/progress.html) · [span](https://iot.mi.com/vela/quickapp/zh/component/basic/span.html) · [a](https://iot.mi.com/vela/quickapp/zh/component/basic/a.html) · [input](https://iot.mi.com/vela/quickapp/zh/component/form/input.html) · [slider](https://iot.mi.com/vela/quickapp/zh/component/form/slider.html) · [switch](https://iot.mi.com/vela/quickapp/zh/component/form/switch.html) · [picker](https://iot.mi.com/vela/quickapp/zh/component/form/picker.html) · [label](https://iot.mi.com/vela/quickapp/zh/component/form/label.html)

**框架**: [Manifest](https://iot.mi.com/vela/quickapp/zh/guide/start/manifest.html) · [生命周期](https://iot.mi.com/vela/quickapp/zh/guide/framework/script.html) · [模板语法](https://iot.mi.com/vela/quickapp/zh/guide/framework/template.html) · [样式](https://iot.mi.com/vela/quickapp/zh/guide/framework/style.html) · [事件](https://iot.mi.com/vela/quickapp/zh/guide/framework/event.html)

### Lua 开发文档

本地 `docs/` 目录包含 Lua 表盘开发的完整 API 文档 (Lua 5.4.0, LVGL 9, NuttX 12.3.0)，开发时直接读取对应文件即可。
