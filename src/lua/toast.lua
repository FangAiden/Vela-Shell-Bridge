local Toast = {}

function Toast.show(text, duration, parent)
  duration = duration or 2000
  -- 不再创建全屏 parent：如果没有传 parent，就直接在 root 上创建 Label
  local label = lvgl.Label(parent, {
    text = text,
    align = { type = lvgl.ALIGN.CENTER },  -- 底部居中
    text_color = "#ffffff",
    bg_color = "#000000",
    bg_opa = lvgl.OPA(80),
    pad_all = 10,
    radius = 10,
    opa = 0,  -- 初始透明
  })                                           

  -- 淡入
  local fadeIn = label:Anim({
    start_value = 0, end_value = 255, duration = 300, path = "ease_out",
    exec_cb = function(obj, v) obj:set { opa = v } end
  })                      
  fadeIn:start()

  -- 停留后淡出并删除
  lvgl.Timer({
    period = duration, repeat_count = 1,         
    cb = function()
      local fadeOut = label:Anim({
        start_value = 255, end_value = 0, duration = 300, path = "ease_in",
        exec_cb = function(obj, v) obj:set { opa = v } end,
        done_cb = function() label:delete() end
      })
      fadeOut:start()
    end
  })
end

return Toast
