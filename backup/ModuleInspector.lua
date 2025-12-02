-- ModuleInspector.lua
-- 自动扫描模块结构 + 构造器参数键（spy table）+（可选）方法反射 +（可选）函数入参探测
-- 对 Lua 函数：用 debug 反射形参名；对 C 函数：基于“温和报错解析/最小实参数”做黑盒探测（默认关闭）
-- 返回 (ok, path, line_count) 或 (false, errmsg)

local M = {}

-- ===== 基础工具 =====
local ok_debug, debugLib = pcall(require, "debug")

local function get_mt(u)
  if ok_debug and debugLib and debugLib.getmetatable then return debugLib.getmetatable(u) end
  return getmetatable(u)
end

local function sorted_keys(t)
  local ks = {}
  for k in pairs(t) do ks[#ks+1] = k end
  table.sort(ks, function(a,b) return tostring(a) < tostring(b) end)
  return ks
end

local function id_of(seen, t)
  local id = seen._id[t]
  if not id then
    seen._last = seen._last + 1
    id = seen._last
    seen._id[t] = id
  end
  return id
end

local function try_pcall(f, ...)
  local ok, a, b, c, d = pcall(f, ...)
  if ok then return true, a, b, c, d end
  return false, a
end

local function safe_tostring(v)
  local ok, s = pcall(function() return tostring(v) end)
  return ok and s or "<tostring error>"
end

-- ===== 函数入参（Lua 层） =====
local function get_function_args_info(fn)
  if type(fn) ~= "function" then return nil end
  if not ok_debug or not debugLib or not debugLib.getinfo then return nil end

  local info = debugLib.getinfo(fn, "uS")
  if not info then return nil end
  if info.what == "C" then return "(C function)" end

  local args = {}
  for i = 1, (info.nparams or 0) do
    local name = debugLib.getlocal(fn, i)
    args[#args+1] = name or ("arg"..i)
  end
  if info.isvararg then args[#args+1] = "..." end
  return "(" .. table.concat(args, ", ") .. ")"
end

-- ===== C Function 入参（温和：报错解析 + 最小实参数） =====
local function parse_expected_from_error(errmsg)
  if type(errmsg) ~= "string" then return nil end
  -- 尽量兼容多种常见格式
  -- e.g. "(table expected, got nil)" / "expects lv_obj_t" / "expected number" / "must be table"
  local typ = errmsg:match("%(([%w_]+) expected")
            or errmsg:match("expects? ([%w_]+)")
            or errmsg:match("expected ([%w_]+)")
            or errmsg:match("must be ([%w_]+)")
  return typ
end

local function gentle_value_for_type(typename, lvgl_mod)
  if typename == "table" then
    return {}
  elseif typename == "string" then
    return ""
  elseif typename == "number" or typename == "integer" then
    return 0
  elseif typename == "boolean" then
    return false
  elseif typename == "function" then
    return function() end
  elseif typename == "userdata" then
    if type(lvgl_mod)=="table" and type(lvgl_mod.scr_act)=="function" then
      local ok, u = pcall(lvgl_mod.scr_act)
      if ok and type(u)=="userdata" then return u end
    end
    return nil
  else
    return nil
  end
end

local function probe_cfunc_signature(fn, fname, opts)
  -- opts: { max_arity=4, lvgl_mod=nil, allow_type_refine=false }
  local maxA = (opts and opts.max_arity) or 4
  local lvgl_mod = opts and opts.lvgl_mod
  local allow_refine = opts and opts.allow_type_refine

  local args = {}
  local min_ok_arity = nil
  local arity_errors = {}
  for n = 0, maxA do
    local ok, err = pcall(fn, table.unpack(args, 1, n))
    if ok then min_ok_arity = n; break end
    arity_errors[n] = tostring(err)
    args[n+1] = nil
  end

  local expected = {}
  for n=0, maxA do
    local e = arity_errors[n]
    if e then
      local k = tonumber(e:match("argument%s*#?(%d+)")) or tonumber(e:match("bad argument%s*#?(%d+)"))
      if k and expected[k]==nil then
        expected[k] = parse_expected_from_error(e)
      end
    end
  end

  if allow_refine then
    for i=1, maxA do
      if expected[i] then
        local testv = gentle_value_for_type(expected[i], lvgl_mod)
        local call_args = {}
        for j=1, math.max(i, (min_ok_arity or 0), 1) do
          call_args[j] = (j==i) and testv or nil
        end
        pcall(fn, table.unpack(call_args))
      end
    end
  end

  return {
    min_ok_arity = min_ok_arity,
    expected     = expected,
    notes        = (min_ok_arity and "min arity that didn't error") or "all tested arities errored"
  }
end

-- ===== 创建/销毁（尽量温和） =====
local function try_create(ctor, parent)
  local ok, obj = try_pcall(function() return ctor(nil) end)
  if ok and type(obj)=="userdata" then return obj end
  if parent then
    ok, obj = try_pcall(function() return ctor(parent) end)
    if ok and type(obj)=="userdata" then return obj end
  end
  ok, obj = try_pcall(function() return ctor() end)
  if ok and type(obj)=="userdata" then return obj end
  return nil
end

local function try_destroy(obj, top_mod)
  if type(obj)~="userdata" then return false end
  local function callm(name)
    local ok, m = pcall(function() return obj[name] end)
    if ok and type(m)=="function" then pcall(m, obj); return true end
    return false
  end
  for _,n in ipairs({"delete","del","destroy","remove","free","close","unref"}) do
    if callm(n) then return true end
  end
  if type(top_mod)=="table" then
    for _,fn in ipairs({"obj_del","obj_delete"}) do
      local f = top_mod[fn]
      if type(f)=="function" then pcall(f, obj); return true end
    end
  end
  return false
end

-- ===== 候选名探针（仅当 __index 是函数时可选启用） =====
local common_candidates = {
  "set","get","set_class","onevent","on","add_event_cb","remove_event_cb",
  "align","center","set_size","set_width","set_height","set_x","set_y","move_foreground","move_background",
  "add_flag","clear_flag","add_state","clear_state","has_flag","has_state",
  "scroll_to_view","scroll_by","scroll_to","scroll_to_x","scroll_to_y","scrollbar_inset",
  "set_style","set_style_bg_color","set_style_text_color","set_style_border_color","set_style_border_width",
  "set_style_radius","set_style_pad_all","set_style_pad_row","set_style_pad_column",
  "set_style_shadow_color","set_style_shadow_width","set_style_shadow_spread","set_style_shadow_ofs_x","set_style_shadow_ofs_y",
  "get_x","get_y","get_width","get_height","get_parent","get_style_bg_color","get_style_text_color",
}
local widget_candidates = {
  Object = {
    "set_scrollbar_mode","set_flex_flow","set_flex_align","set_layout","set_grid_align",
    "set_style_bg_opa","set_style_text_font","set_style_img_opa",
  },
  Label = {
    "set_text","get_text","set_long_mode","get_long_mode","set_recolor","is_recolor",
    "ins_text","cut_text","set_text_selection","get_text_selection_start","get_text_selection_end",
  },
  Textarea = {
    "set_text","get_text","set_placeholder_text","set_password_mode","set_cursor_pos",
    "set_cursor_click_pos","set_max_length","add_char","add_text","del_char","del_char_forward",
    "get_cursor_pos","get_max_length",
  },
  Button = { "set_text","get_text","set_checked" },
  List = { "add_text","add_btn","get_btn_text","get_btn_label","set_text","get_selected_btn" },
  Dropdown = {
    "set_options","add_option","clear_options","set_selected","get_selected","get_selected_str",
    "open","close","is_open","set_symbol","get_symbol","set_dir","get_dir",
  },
  Roller = { "set_options","set_selected","get_selected","get_selected_str","set_visible_row_count","set_wrap","set_mode","get_mode" },
  Image  = { "set_src","get_src","set_zoom","set_angle","set_antialias","set_pivot","set_offset_x","set_offset_y" },
  Led    = { "on","off","toggle","set_brightness","get_brightness" },
  Keyboard = { "set_textarea","set_mode","get_mode","set_popovers","set_map","set_ctrl_map" },
  Calendar = { "set","get_today","get_showed","get_pressed","get_btnm","Arrow","Dropdown" },
  AnalogTime = { "pause","resume","set_hands","set_period" },
  Pointer    = { "set_angle","set_value","set_range" },
  Thumbnail  = { "set_src","set_text" },
  CurvedLabel = { "set_text","set_curve_radius","set_text_align" },
  ImageBar   = { "set_range","set_value","set_bg_src","set_fg_src","set_dir" },
  ImageLineBar = { "set_range","set_value","set_bg_src","set_fg_src","set_dir","set_line_points" },
  ImageLabel = { "set_text","set_src","set_align" },
  Checkbox   = { "set_text","get_text","set_state","is_checked" },
}
local function unique_join(a, b)
  local seen, out = {}, {}
  for _,x in ipairs(a or {}) do if not seen[x] then seen[x]=true; out[#out+1]=x end end
  for _,x in ipairs(b or {}) do if not seen[x] then seen[x]=true; out[#out+1]=x end end
  return out
end

local function list_methods_from_index(obj, mt, writeln, indent, widget_name, enable_probe)
  local idx = mt and rawget(mt, "__index")
  if type(idx) == "table" then
    writeln(indent .. "__index (table) methods [#source: table reflection]")
    local ks = {}
    for k, v in pairs(idx) do if type(v)=="function" then ks[#ks+1]=tostring(k) end end
    table.sort(ks)
    for _,k in ipairs(ks) do writeln(string.format("%s  .%s()", indent, k)) end
    writeln(string.format("%s  [total %d methods found by reflection]", indent, #ks))
  elseif type(idx) == "function" then
    if not enable_probe then
      writeln(indent .. "__index is function (dispatcher) — probing disabled")
      return
    end
    local candidates = unique_join(common_candidates, widget_candidates[widget_name])
    writeln(indent .. "__index (function) dispatcher [#source: candidate probing]")
    local found, total, hit = {}, #candidates, 0
    for _, name in ipairs(candidates) do
      local ok, val = pcall(function() return obj[name] end)
      if ok and type(val)=="function" and not found[name] then
        writeln(string.format("%s  .%s()  (from candidate list)", indent, name))
        found[name]=true; hit=hit+1
      end
    end
    if hit>0 then
      writeln(string.format("%s  [matched %d / %d candidate methods]", indent, hit, total))
    else
      writeln(string.format("%s  (no methods found via candidate probing; extend candidates if needed)", indent))
    end
  else
    writeln(indent .. "__index not present")
  end
end

local function dump_userdata(u, writeln, indent, widget_name, enable_probe)
  indent = indent or ""
  writeln(string.format("%s(userdata) %s", indent, safe_tostring(u)))
  local mt = get_mt(u)
  if type(mt)=="table" then
    writeln(indent .. "metatable:")
    local ks = sorted_keys(mt)
    for _,k in ipairs(ks) do
      writeln(string.format("%s  [%s] = %s", indent, k, type(mt[k])))
    end
    list_methods_from_index(u, mt, writeln, indent.."  ", widget_name, enable_probe)
  else
    writeln(indent .. "no accessible metatable")
  end
end

-- ===== 递归导出（支持 cfg 以控制函数签名打印 & C 函数探测） =====
local function dump_table(t, writeln, indent, seen, path, enable_probe, cfg)
  indent = indent or ""; seen = seen or { _id={}, _last=0 }; path = path or ""
  if type(t)~="table" then
    writeln(string.format("%s%s(%s) = %s", indent, path, type(t), safe_tostring(t))); return
  end
  local myid = id_of(seen, t)
  if seen[t] then
    writeln(string.format("%s%s(table)#%d -> (already seen)", indent, path, myid))
    return
  end
  seen[t] = true

  local mt = get_mt(t)
  local mtflag = mt and " +meta" or ""
  writeln(string.format("%s%s(table)#%d%s", indent, path~="" and (path.." = ") or "", myid, mtflag))

  if mt then
    writeln(indent .. "  __metatable:")
    dump_table(mt, writeln, indent.."    ", seen, "(metatable)", enable_probe, cfg)
  end

  for _,k in ipairs(sorted_keys(t)) do
    local v = t[k]; local kstr = (type(k)=="string") and k or ("["..safe_tostring(k).."]")
    local vt = type(v)
    if vt=="table" then
      local tid = id_of(seen, v)
      if seen[v] then
        writeln(string.format("%s  %s: table#%d -> (already seen)", indent, kstr, tid))
      else
        writeln(string.format("%s  %s: table#%d", indent, kstr, tid))
        dump_table(v, writeln, indent.."    ", seen, "", enable_probe, cfg)
      end
    elseif vt=="function" then
      local sig = ""
      local is_cfunc = false
      if cfg and cfg.dump_function_args then
        local args_str = get_function_args_info(v)
        if args_str then
          if args_str == "(C function)" then is_cfunc = true end
          sig = " " .. args_str
        end
      end

      local csig = nil
      if is_cfunc and cfg and cfg.cfunc_probe and (cfg.cfunc_probe.mode ~= "off") then
        local mode = cfg.cfunc_probe.mode            -- "arity" | "types"
        local allow_refine = (mode == "types")
        local info = probe_cfunc_signature(v, kstr, {
          max_arity = (cfg.cfunc_probe.max_arity or 4),
          lvgl_mod  = (cfg.cfunc_probe.lvgl_mod),
          allow_type_refine = allow_refine
        })
        local parts = {}
        if info.min_ok_arity ~= nil then parts[#parts+1] = "min_ok_arity="..info.min_ok_arity end
        local exp = {}
        -- expected 索引从 1..N 紧凑打印
        local maxE = 0
        for i,_ in pairs(info.expected) do if i>maxE then maxE=i end end
        for i=1,maxE do
          if info.expected[i] then exp[#exp+1] = i..":"..info.expected[i] end
        end
        if #exp > 0 then parts[#parts+1] = "expected["..table.concat(exp, ",").."]" end
        if #parts > 0 then csig = "  {"..table.concat(parts, "; ").."}" end
      end

      writeln(string.format("%s  %s: function%s %s%s", indent, kstr, sig, safe_tostring(v), csig or ""))
    elseif vt=="userdata" then
      writeln(string.format("%s  %s: userdata %s", indent, kstr, safe_tostring(v)))
      dump_userdata(v, writeln, indent.."    ", kstr, enable_probe)
    elseif vt=="thread" then
      writeln(string.format("%s  %s: thread %s", indent, kstr, safe_tostring(v)))
    else
      writeln(string.format("%s  %s: %s %s", indent, kstr, vt, safe_tostring(v)))
    end
  end
end

-- ===== 构造器参数键探测（spy table） =====
local function discover_option_keys(ctor, parent)
  local accessed = {}
  local spy = setmetatable({}, {
    __index = function(_, k) accessed[k] = true; return nil end,
    __pairs = function() return function() return nil end end, -- 阻止 pairs 遍历
    __len   = function() return 0 end,
  })

  local function call_and_cleanup(callf)
    local ok, ret = try_pcall(callf)
    if ok and type(ret)=="userdata" then try_destroy(ret) end
    return ok
  end

  local ok1 = call_and_cleanup(function() return ctor(nil, spy) end)
  local ok2 = false
  if not ok1 and parent then ok2 = call_and_cleanup(function() return ctor(parent, spy) end) end
  local ok3 = false
  if not ok1 and not ok2 then ok3 = call_and_cleanup(function() return ctor(spy) end) end

  local keys = {}
  for k in pairs(accessed) do keys[#keys+1] = k end
  table.sort(keys, function(a,b) return tostring(a) < tostring(b) end)
  return keys, (ok1 or ok2 or ok3)
end

-- ===== 识别疑似构造器 =====
local function is_probable_ctor(name)
  if name == "new" then return true end
  local first = tostring(name):sub(1,1)
  return first:match("%u") ~= nil
end

-- ===== 写文件（原子写） =====
local function open_writer(path)
  local tmp = path .. ".tmp"
  local f = assert(io.open(tmp, "w"))
  local n = 0
  local function wl(s) f:write(s); f:write("\n"); n=n+1 end
  local function okf() f:close(); os.remove(path); assert(os.rename(tmp, path)); return n end
  local function erf() f:close(); os.remove(tmp) end
  return wl, okf, erf
end

-- ===== 主流程 =====
local function build_report(top, mod_name, cfg)
  cfg = cfg or {}
  local writeln, okf = open_writer(cfg.output_path or ((os.getenv("TEMP") or "/tmp").."/"..mod_name.."_inspect.txt"))

  local dump_methods = (cfg.dump_methods ~= false)            -- 默认 true：与你原逻辑一致
  local widgets = cfg.widget_list                             -- { Name=true, ... } 仅这些做实例方法反射
  local enable_ctor_probe = (cfg.enable_ctor_probe ~= false)  -- 可在设备上设 false 关闭

  writeln(("== Module Tree: %s =="):format(mod_name))
  dump_table(top, writeln, "", nil, mod_name, dump_methods, cfg)

  -- 构造器参数键（spy）探测
  if enable_ctor_probe then
    writeln("")
    writeln("== Constructors & Option Keys (spy-table) ==")

    local parent = nil
    try_pcall(function()
      if type(top)=="table" and type(top.Object)=="function" then
        local w = (type(top.HOR_RES)=="function" and top.HOR_RES()) or 480
        local h = (type(top.VER_RES)=="function" and top.VER_RES()) or 320
        parent = top.Object(nil, { w = w, h = h })
      end
    end)

    for _, name in ipairs(sorted_keys(top)) do
      local fn = top[name]
      if type(fn)=="function" and is_probable_ctor(name) then
        writeln(("\n-- ctor: %s.%s --"):format(mod_name, tostring(name)))
        local keys, ok_call = discover_option_keys(fn, parent)
        if #keys > 0 then
          writeln("  ctor_option_keys:")
          for _,k in ipairs(keys) do writeln("    - " .. tostring(k)) end
        else
          writeln("  ctor_option_keys: (none discovered)")
        end
        writeln("  ctor_probe_call_ok: " .. tostring(ok_call))

        if widgets and widgets[name] then
          local obj = try_create(fn, parent)
          if obj then
            dump_userdata(obj, writeln, "  ", name, dump_methods)
            try_destroy(obj, top)
          else
            writeln("  (failed to create instance for metatable dump)")
          end
        end
      end
    end

    if parent then try_destroy(parent, top) end
  else
    writeln("")
    writeln("== Constructors & Option Keys (disabled by cfg.enable_ctor_probe=false) ==")
  end

  writeln("")
  writeln(("== End of %s =="):format(mod_name))
  local lines = okf()
  return lines
end

-- ===== 对外 API =====
function M.inspect_module(mod_table, mod_name, cfg)
  assert(type(mod_table)=="table", "inspect_module: mod_table must be table")
  local ok, lines_or_err = pcall(build_report, mod_table, (mod_name or "<module>"), cfg or {})
  if ok then
    local path = (cfg and cfg.output_path) or ((os.getenv("TEMP") or "/tmp").."/"..(mod_name or "module").."_inspect.txt")
    return true, path, lines_or_err
  else
    return false, tostring(lines_or_err)
  end
end

function M.inspect_by_name(mod_name, cfg)
  assert(type(mod_name)=="string" and #mod_name>0, "inspect_by_name: module name required")
  local ok, mod_or_err = pcall(require, mod_name)
  if not ok then return false, ("require('%s') failed: %s"):format(mod_name, tostring(mod_or_err)) end
  return M.inspect_module(mod_or_err, mod_name, cfg)
end

return M
