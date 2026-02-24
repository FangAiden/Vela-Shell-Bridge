-- UI component assembly for daemon page (flex layout only).

local M = {}

local function set_flex(obj, lvgl, flow, main, cross, track)
    pcall(function() obj:set_flex_flow(flow) end)
    pcall(function() obj:set_flex_align(main, cross, track) end)
end

local function set_flex_grow(obj, grow)
    pcall(function() obj:set_flex_grow(grow) end)
end

local function make_btn(lvgl, parent, theme, ui, text, custom_w)
    local w = custom_w or ui.btn_w
    local pill = lvgl.Object(parent, {
        w = w,
        h = ui.btn_h,
        bg_color = theme.BTN_BG,
        bg_opa = 255,
        radius = ui.btn_radius,
        border_width = 1,
        border_color = theme.BTN_EDGE,
    })
    pill:clear_flag(lvgl.FLAG.SCROLLABLE)
    pill:add_flag(lvgl.FLAG.CLICKABLE)

    set_flex(pill, lvgl, lvgl.FLEX_FLOW.ROW, lvgl.FLEX_ALIGN.CENTER, lvgl.FLEX_ALIGN.CENTER, lvgl.FLEX_ALIGN.CENTER)
    lvgl.Label(pill, {
        text = text,
        text_color = theme.TEXT,
        align = lvgl.ALIGN.CENTER,
    })
    return pill
end

function M.create(lvgl, theme, ui, texts)
    local t = texts or {}

    local root = lvgl.Object(nil, {
        w = ui.screen_w,
        h = ui.screen_h,
        bg_color = theme.BG,
        bg_opa = 255,
        border_width = 0,
        pad_left = ui.content_pad_left or 0,
        pad_right = ui.content_pad_right or 0,
        pad_top = ui.content_pad_top or 0,
        pad_bottom = ui.content_pad_bottom or 0,
        pad_row = ui.content_row_gap or 0,
    })
    root:clear_flag(lvgl.FLAG.SCROLLABLE)
    root:add_flag(lvgl.FLAG.EVENT_BUBBLE)
    set_flex(root, lvgl, lvgl.FLEX_FLOW.COLUMN, lvgl.FLEX_ALIGN.START, lvgl.FLEX_ALIGN.CENTER, lvgl.FLEX_ALIGN.START)

    local top_zone = lvgl.Object(root, {
        w = ui.content_w,
        h = ui.top_zone_h,
        bg_opa = 0,
        border_width = 0,
        pad_left = ui.top_pad_left or 0,
        pad_right = ui.top_pad_right or 0,
        pad_top = ui.top_pad_top or 0,
        pad_bottom = ui.top_pad_bottom or 0,
        pad_row = ui.top_vertical and (ui.top_gap or 0) or 0,
    })
    top_zone:clear_flag(lvgl.FLAG.SCROLLABLE)
    if ui.top_vertical then
        set_flex(top_zone, lvgl, lvgl.FLEX_FLOW.COLUMN, lvgl.FLEX_ALIGN.START, lvgl.FLEX_ALIGN.CENTER, lvgl.FLEX_ALIGN.CENTER)
    else
        set_flex(top_zone, lvgl, lvgl.FLEX_FLOW.ROW, lvgl.FLEX_ALIGN.SPACE_BETWEEN, lvgl.FLEX_ALIGN.CENTER, lvgl.FLEX_ALIGN.CENTER)
    end

    local time_label = lvgl.Label(top_zone, {
        text = "--:--",
        text_color = theme.TEXT_DIM,
    })

    local status_pill = lvgl.Object(top_zone, {
        w = ui.status_w,
        h = ui.status_h,
        bg_color = theme.GREEN_DIM,
        bg_opa = 255,
        radius = ui.status_radius,
        border_width = 1,
        border_color = theme.GREEN,
    })
    status_pill:clear_flag(lvgl.FLAG.SCROLLABLE)
    status_pill:add_flag(lvgl.FLAG.CLICKABLE)
    set_flex(status_pill, lvgl, lvgl.FLEX_FLOW.ROW, lvgl.FLEX_ALIGN.CENTER, lvgl.FLEX_ALIGN.CENTER, lvgl.FLEX_ALIGN.CENTER)

    local status_label = lvgl.Label(status_pill, {
        text = t.status_on_text or "SU Daemon",
        text_color = theme.GREEN,
        align = lvgl.ALIGN.CENTER,
    })

    local log_card = lvgl.Object(root, {
        w = ui.content_w,
        h = ui.log_min_h,
        bg_color = theme.CARD,
        bg_opa = 255,
        radius = ui.log_radius,
        border_width = 1,
        border_color = theme.CARD_EDGE,
        pad_left = ui.log_pad_left or 10,
        pad_right = ui.log_pad_right or 10,
        pad_top = ui.log_pad_top or 8,
        pad_bottom = ui.log_pad_bottom or 8,
    })
    log_card:clear_flag(lvgl.FLAG.SCROLLABLE)
    set_flex(log_card, lvgl, lvgl.FLEX_FLOW.COLUMN, lvgl.FLEX_ALIGN.START, lvgl.FLEX_ALIGN.START, lvgl.FLEX_ALIGN.START)
    set_flex_grow(log_card, 1)

    local log_view = lvgl.Textarea(log_card, {
        w = ui.log_text_w,
        h = ui.log_text_h_min,
        text = "",
        text_color = theme.TERM_TEXT,
        bg_opa = 0,
        border_width = 0,
        pad_left = 0,
        pad_right = 0,
        pad_top = 0,
        pad_bottom = 0,
    })
    log_view:add_flag(lvgl.FLAG.SCROLLABLE)
    set_flex_grow(log_view, 1)

    local button_zone = lvgl.Object(root, {
        w = ui.content_w,
        h = ui.btn_zone_h,
        bg_opa = 0,
        border_width = 0,
        pad_left = ui.btn_zone_pad_left or 0,
        pad_right = ui.btn_zone_pad_right or 0,
        pad_top = ui.btn_zone_pad_top or 0,
        pad_bottom = ui.btn_zone_pad_bottom or 0,
        pad_column = (not ui.button_vertical and not ui.button_circle_split) and (ui.btn_gap or 0) or 0,
        pad_row = (ui.button_vertical or ui.button_circle_split) and (ui.btn_gap or 0) or 0,
    })
    button_zone:clear_flag(lvgl.FLAG.SCROLLABLE)
    if ui.button_vertical then
        set_flex(button_zone, lvgl, lvgl.FLEX_FLOW.COLUMN, lvgl.FLEX_ALIGN.START, lvgl.FLEX_ALIGN.CENTER, lvgl.FLEX_ALIGN.CENTER)
    elseif ui.button_circle_split then
        set_flex(button_zone, lvgl, lvgl.FLEX_FLOW.COLUMN, lvgl.FLEX_ALIGN.START, lvgl.FLEX_ALIGN.CENTER, lvgl.FLEX_ALIGN.CENTER)
    else
        set_flex(button_zone, lvgl, lvgl.FLEX_FLOW.ROW, lvgl.FLEX_ALIGN.CENTER, lvgl.FLEX_ALIGN.CENTER, lvgl.FLEX_ALIGN.CENTER)
    end

    local btn_scan = nil
    local btn_policies = nil
    local btn_clear = nil
    if ui.button_circle_split then
        local top_row = lvgl.Object(button_zone, {
            w = ui.btn_pair_w or (ui.btn_w * 2 + (ui.btn_gap or 0)),
            h = ui.btn_h,
            bg_opa = 0,
            border_width = 0,
            pad_left = 0,
            pad_right = 0,
            pad_top = 0,
            pad_bottom = 0,
            pad_column = ui.btn_gap or 0,
        })
        top_row:clear_flag(lvgl.FLAG.SCROLLABLE)
        set_flex(top_row, lvgl, lvgl.FLEX_FLOW.ROW, lvgl.FLEX_ALIGN.START, lvgl.FLEX_ALIGN.CENTER, lvgl.FLEX_ALIGN.CENTER)

        local bottom_row = lvgl.Object(button_zone, {
            w = ui.btn_single_w or ui.btn_w,
            h = ui.btn_h,
            bg_opa = 0,
            border_width = 0,
            pad_left = 0,
            pad_right = 0,
            pad_top = 0,
            pad_bottom = 0,
        })
        bottom_row:clear_flag(lvgl.FLAG.SCROLLABLE)
        set_flex(bottom_row, lvgl, lvgl.FLEX_FLOW.ROW, lvgl.FLEX_ALIGN.CENTER, lvgl.FLEX_ALIGN.CENTER, lvgl.FLEX_ALIGN.CENTER)

        btn_scan = make_btn(lvgl, top_row, theme, ui, t.btn_scan_text or "Scan", ui.btn_pair_item_w or ui.btn_w)
        btn_policies = make_btn(lvgl, top_row, theme, ui, t.btn_policy_text or "Policy", ui.btn_pair_item_w or ui.btn_w)
        btn_clear = make_btn(lvgl, bottom_row, theme, ui, t.btn_clear_text or "Clear", ui.btn_single_w or ui.btn_w)
    else
        btn_scan = make_btn(lvgl, button_zone, theme, ui, t.btn_scan_text or "Scan")
        btn_policies = make_btn(lvgl, button_zone, theme, ui, t.btn_policy_text or "Policy")
        btn_clear = make_btn(lvgl, button_zone, theme, ui, t.btn_clear_text or "Clear")
    end

    local function update_status(enabled)
        if enabled then
            pcall(function() status_pill:set { bg_color = theme.GREEN_DIM, border_color = theme.GREEN } end)
            pcall(function()
                status_label:set {
                    text = t.status_on_text or "SU Daemon",
                    text_color = theme.GREEN,
                    align = lvgl.ALIGN.CENTER,
                }
            end)
        else
            pcall(function() status_pill:set { bg_color = theme.RED_DIM, border_color = theme.RED } end)
            pcall(function()
                status_label:set {
                    text = t.status_off_text or "SU Stopped",
                    text_color = theme.RED,
                    align = lvgl.ALIGN.CENTER,
                }
            end)
        end
    end

    return {
        root = root,
        time_label = time_label,
        status_pill = status_pill,
        status_label = status_label,
        log_view = log_view,
        btn_scan = btn_scan,
        btn_policies = btn_policies,
        btn_clear = btn_clear,
        update_status = update_status,
    }
end

return M
