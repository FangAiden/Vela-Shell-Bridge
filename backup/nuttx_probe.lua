-- nuttx_probe.lua
-- 纯内省：不访问/枚举文件系统。仅使用 preload / loaded / 可选 try_names 的 require 测试。
local M = {}

local function sorted_keys(t)
  local ks = {}
  for k,_ in pairs(t or {}) do ks[#ks+1] = k end
  table.sort(ks); return ks
end

-- 核心：探测（不进行任何文件系统访问）
-- opts = {
--   try_names = {"cjson","ffi","socket",...}, -- 可选：待测试的模块名列表
--   do_load   = false,                        -- true 则 pcall(require, name)
-- }
function M.probe(opts)
  opts = opts or {}
  local try_names = opts.try_names or {}
  local do_load   = not not opts.do_load

  -- 仅内省
  local preloaded = sorted_keys(package.preload or {})
  local loaded    = sorted_keys(package.loaded or {})

  -- 测试候选名（不做 searchpath，不枚举文件）
  local tested = {}
  for _, name in ipairs(try_names) do
    local rec = { name = name }
    if do_load then
      local ok, err = pcall(require, name)
      rec.load_ok, rec.load_err = ok, (ok and nil or tostring(err))
    else
      -- 不加载时，仅标注“未测试”
      rec.load_ok, rec.load_err = nil, "not_tested"
    end
    tested[#tested+1] = rec
  end

  return {
    version       = tostring(_VERSION) .. (jit and (" / "..jit.version) or ""),
    package_path  = tostring(package.path),
    package_cpath = tostring(package.cpath),
    preloaded     = preloaded,   -- 静态注册（NuttX 常见）
    loaded        = loaded,      -- 运行期已加载
    tested        = tested,      -- 你传入的候选名测试结果
  }
end

-- 将结果写到文本文件（默认 /tmp/probe_result.txt）
function M.write_report(res, filepath)
  filepath = filepath or "/tmp/probe_result.txt"
  local f, err = io.open(filepath, "w")
  if not f then
    print("无法写入文件: "..tostring(err))
    return false, err
  end

  local function section(title, lines)
    f:write("\n["..title.."]\n")
    if lines and #lines > 0 then
      for _, s in ipairs(lines) do f:write("  "..tostring(s).."\n") end
    else
      f:write("  (none)\n")
    end
  end

  f:write("=== Lua Module Probe Report (No FS) ===\n")
  f:write("Lua: "..res.version.."\n")
  f:write("package.path  = "..res.package_path.."\n")
  f:write("package.cpath = "..res.package_cpath.."\n")

  section("Preloaded (package.preload keys)", res.preloaded)
  section("Currently loaded (package.loaded keys)", res.loaded)

  f:write("\n[Tested candidates]\n")
  if #res.tested == 0 then
    f:write("  (no candidates provided)\n")
  else
    for _, r in ipairs(res.tested) do
      local state = (r.load_ok == nil) and "not_tested"
                  or (r.load_ok and "ok" or ("fail: "..tostring(r.load_err)))
      f:write(string.format("  %-30s %s\n", r.name, state))
    end
  end

  f:write("\n[Notes]\n")
  f:write("  • 本报告不扫描文件系统；仅反映 preload/loaded 以及你提供的候选名加载结果。\n")
  f:write("  • 若你希望更多模块被发现，请在启动前把它们加入 package.preload，或先 require 一次。\n")

  f:write("\n[End of Report]\n")
  f:close()
  print("结果已写入: "..filepath)
  return true
end

return M
