-- Bucket-based 3-zone flex layout:
-- 1) top_zone    : time + daemon switch
-- 2) log_zone    : main log area (flex-grow)
-- 3) button_zone : 3 action buttons
--
-- Shape adaptation:
-- - circle/pill: top zone uses vertical stacking (time above status).
-- - circle: keep log/button inside safe area by larger content padding.
-- - circle: button zone uses 2+1 layout (two buttons above, one below).
-- - pill: reserve bigger button zone and stack 3 buttons vertically.

local M = {}

local BUCKET_BG_SIZE = {
    r336 = { width = 336, height = 480 },
    r390 = { width = 390, height = 450 },
    r432 = { width = 432, height = 514 },
    c466 = { width = 466, height = 466 },
    c480 = { width = 480, height = 480 },
    p192 = { width = 192, height = 490 },
    p212 = { width = 212, height = 520 },
}

local BUCKET_LAYOUT = {
    r336 = {
        content = { padding = { left = 16, right = 16, top = 16, bottom = 16 }, row_gap = 8, min_w = 120 },
        text = { font_h = 15, char_w = 7 },
        top_zone = { h = 44, padding = { left = 0, right = 0, top = 0, bottom = 0 } },
        status = { h = 26, w_ratio = 0.48, radius = 13, min_w = 64, min_right_space = 56 },
        log_zone = { min_h = 120, radius = 14, padding = { left = 10, right = 10, top = 8, bottom = 8 } },
        button_zone = { h = 56, padding = { left = 0, right = 0, top = 0, bottom = 0 }, gap = 6 },
        button = { h = 34, radius = 17, min_w = 40 },
    },
    r390 = {
        content = { padding = { left = 20, right = 20, top = 18, bottom = 18 }, row_gap = 8, min_w = 120 },
        text = { font_h = 16, char_w = 7 },
        top_zone = { h = 46, padding = { left = 0, right = 0, top = 0, bottom = 0 } },
        status = { h = 28, w_ratio = 0.48, radius = 14, min_w = 64, min_right_space = 56 },
        log_zone = { min_h = 130, radius = 14, padding = { left = 10, right = 10, top = 8, bottom = 8 } },
        button_zone = { h = 58, padding = { left = 0, right = 0, top = 0, bottom = 0 }, gap = 7 },
        button = { h = 34, radius = 17, min_w = 40 },
    },
    r432 = {
        content = { padding = { left = 28, right = 28, top = 20, bottom = 20 }, row_gap = 8, min_w = 120 },
        text = { font_h = 16, char_w = 7 },
        top_zone = { h = 60, padding = { left = 0, right = 0, top = 0, bottom = 0 } },
        status = { h = 28, w_ratio = 0.48, radius = 14, min_w = 64, min_right_space = 56 },
        log_zone = { min_h = 150, radius = 14, padding = { left = 10, right = 10, top = 8, bottom = 8 } },
        button_zone = { h = 62, padding = { left = 0, right = 0, top = 0, bottom = 0 }, gap = 8 },
        button = { h = 34, radius = 17, min_w = 40 },
    },
    c466 = {
        content = { padding = { left = 42, right = 42, top = 26, bottom = 22 }, row_gap = 8, min_w = 120 },
        text = { font_h = 16, char_w = 7 },
        top_zone = { h = 72, gap = 8, padding = { left = 0, right = 0, top = 0, bottom = 0 } },
        status = { h = 28, w_ratio = 0.48, stack_w_ratio = 0.64, radius = 14, min_w = 64, min_right_space = 56 },
        log_zone = { min_h = 110, radius = 14, padding = { left = 10, right = 10, top = 8, bottom = 8 } },
        button_zone = { h = 76, padding = { left = 18, right = 18, top = 0, bottom = 0 }, gap = 6, pair_item_ratio = 0.82 },
        button = { h = 30, radius = 15, min_w = 40 },
    },
    c480 = {
        content = { padding = { left = 44, right = 44, top = 28, bottom = 24 }, row_gap = 8, min_w = 120 },
        text = { font_h = 16, char_w = 7 },
        top_zone = { h = 74, gap = 8, padding = { left = 0, right = 0, top = 0, bottom = 0 } },
        status = { h = 28, w_ratio = 0.48, stack_w_ratio = 0.66, radius = 14, min_w = 64, min_right_space = 56 },
        log_zone = { min_h = 114, radius = 14, padding = { left = 10, right = 10, top = 8, bottom = 8 } },
        button_zone = { h = 80, padding = { left = 20, right = 20, top = 0, bottom = 0 }, gap = 6, pair_item_ratio = 0.82 },
        button = { h = 30, radius = 15, min_w = 40 },
    },
    p192 = {
        content = { padding = { left = 10, right = 10, top = 8, bottom = 8 }, row_gap = 6, min_w = 120 },
        text = { font_h = 14, char_w = 6 },
        top_zone = { h = 70, gap = 8, padding = { left = 0, right = 0, top = 4, bottom = 0 } },
        status = { h = 22, w_ratio = 0.46, stack_w_ratio = 0.74, radius = 11, min_w = 64, min_right_space = 56 },
        log_zone = { min_h = 90, radius = 10, padding = { left = 8, right = 8, top = 6, bottom = 6 } },
        button_zone = { h = 128, padding = { left = 18, right = 18, top = 0, bottom = 0 }, gap = 4 },
        button = { h = 34, radius = 15, min_w = 40 },
    },
    p212 = {
        content = { padding = { left = 10, right = 10, top = 8, bottom = 8 }, row_gap = 6, min_w = 120 },
        text = { font_h = 14, char_w = 6 },
        top_zone = { h = 74, gap = 8, padding = { left = 0, right = 0, top = 4, bottom = 0 } },
        status = { h = 24, w_ratio = 0.46, stack_w_ratio = 0.76, radius = 12, min_w = 64, min_right_space = 56 },
        log_zone = { min_h = 96, radius = 10, padding = { left = 8, right = 8, top = 6, bottom = 6 } },
        button_zone = { h = 136, padding = { left = 20, right = 20, top = 0, bottom = 0 }, gap = 4 },
        button = { h = 34, radius = 15, min_w = 40 },
    },
}

local function clamp_int(v, min_v, max_v, fallback)
    local n = tonumber(v)
    if not n then return fallback end
    n = math.floor(n)
    if n < min_v then return min_v end
    if n > max_v then return max_v end
    return n
end

local function read_box(box, defaults)
    local d = defaults or {}
    local src = box
    if type(src) == "number" then
        return { left = src, right = src, top = src, bottom = src }
    end
    if type(src) ~= "table" then src = {} end
    local left = src.left
    local right = src.right
    local top = src.top
    local bottom = src.bottom
    if left == nil then left = d.left or 0 end
    if right == nil then right = d.right or 0 end
    if top == nil then top = d.top or 0 end
    if bottom == nil then bottom = d.bottom or 0 end
    return {
        left = tonumber(left) or 0,
        right = tonumber(right) or 0,
        top = tonumber(top) or 0,
        bottom = tonumber(bottom) or 0,
    }
end

function M.detect_bucket_key(w, h)
    for key, size in pairs(BUCKET_BG_SIZE) do
        if size.width == w and size.height == h then
            return key
        end
    end
    for key, size in pairs(BUCKET_BG_SIZE) do
        if size.width == h and size.height == w then
            return key
        end
    end

    local best_key = "r432"
    local best_score = nil
    for key, size in pairs(BUCKET_BG_SIZE) do
        local d1 = math.abs(size.width - w) + math.abs(size.height - h)
        local d2 = math.abs(size.width - h) + math.abs(size.height - w)
        local score = math.min(d1, d2)
        if best_score == nil or score < best_score then
            best_score = score
            best_key = key
        end
    end
    return best_key
end

function M.compute(screen_w, screen_h)
    local bucket_key = M.detect_bucket_key(screen_w, screen_h)
    local cfg = BUCKET_LAYOUT[bucket_key] or BUCKET_LAYOUT.r432
    local shape_prefix = bucket_key:sub(1, 1)
    local is_pill_screen = bucket_key:sub(1, 1) == "p"
    local is_circle_screen = shape_prefix == "c"

    local ui = {
        screen_w = screen_w,
        screen_h = screen_h,
        bucket_key = bucket_key,
        is_pill_screen = is_pill_screen,
        is_circle_screen = is_circle_screen,
    }

    local content_padding = read_box(cfg.content.padding, { left = 0, right = 0, top = 0, bottom = 0 })
    local min_content_w = clamp_int(cfg.content.min_w or 120, 80, screen_w, 120)

    ui.content_pad_left = clamp_int(content_padding.left, 0, math.floor(screen_w / 2), 0)
    ui.content_pad_right = clamp_int(content_padding.right, 0, math.floor(screen_w / 2), 0)
    ui.content_pad_top = clamp_int(content_padding.top, 0, math.floor(screen_h / 2), 0)
    ui.content_pad_bottom = clamp_int(content_padding.bottom, 0, math.floor(screen_h / 2), 0)
    ui.content_row_gap = clamp_int(cfg.content.row_gap, 0, 40, 8)

    ui.content_w = screen_w - ui.content_pad_left - ui.content_pad_right
    if ui.content_w < min_content_w then
        local side = math.max(0, math.floor((screen_w - min_content_w) / 2))
        ui.content_pad_left = side
        ui.content_pad_right = side
        ui.content_w = screen_w - side * 2
    end

    ui.font_h = clamp_int(cfg.text.font_h, 10, 24, 16)
    ui.char_w = clamp_int(cfg.text.char_w, 5, 12, 7)
    ui.top_vertical = is_pill_screen or is_circle_screen
    ui.button_vertical = is_pill_screen
    ui.button_circle_split = is_circle_screen

    ui.top_zone_h = clamp_int(cfg.top_zone.h, 24, screen_h, 40)
    ui.top_gap = clamp_int(cfg.top_zone.gap, 0, 20, 4)
    local top_padding = read_box(cfg.top_zone.padding, { left = 0, right = 0, top = 0, bottom = 0 })
    ui.top_pad_left = clamp_int(top_padding.left, 0, ui.content_w, 0)
    ui.top_pad_right = clamp_int(top_padding.right, 0, ui.content_w, 0)
    ui.top_pad_top = clamp_int(top_padding.top, 0, ui.top_zone_h, 0)
    ui.top_pad_bottom = clamp_int(top_padding.bottom, 0, ui.top_zone_h, 0)

    local top_inner_w = ui.content_w - ui.top_pad_left - ui.top_pad_right
    if top_inner_w < 96 then
        ui.top_pad_left = 0
        ui.top_pad_right = 0
        top_inner_w = ui.content_w
    end

    ui.status_h = clamp_int(cfg.status.h, 16, ui.top_zone_h, 24)
    ui.status_radius = clamp_int(cfg.status.radius, 0, 40, 12)
    local status_ratio = tonumber(cfg.status.w_ratio) or 0.48
    local status_stack_ratio = tonumber(cfg.status.stack_w_ratio) or 0.86
    local status_min_w = clamp_int(cfg.status.min_w, 48, math.max(48, top_inner_w), 64)
    if ui.top_vertical then
        ui.status_w = math.floor(top_inner_w * status_stack_ratio)
        if ui.status_w < status_min_w then ui.status_w = status_min_w end
        if ui.status_w > top_inner_w then ui.status_w = top_inner_w end
    else
        local status_min_right_space = clamp_int(cfg.status.min_right_space, 24, math.max(24, top_inner_w), 56)
        local status_max_w = math.max(status_min_w, top_inner_w - status_min_right_space)
        ui.status_w = math.floor(top_inner_w * status_ratio)
        if ui.status_w < status_min_w then ui.status_w = status_min_w end
        if ui.status_w > status_max_w then ui.status_w = status_max_w end
        if ui.status_w > top_inner_w then ui.status_w = top_inner_w end
    end

    ui.log_radius = clamp_int(cfg.log_zone.radius, 0, 30, 12)
    ui.log_min_h = clamp_int(cfg.log_zone.min_h, 32, screen_h, 120)
    local log_padding = read_box(cfg.log_zone.padding, { left = 10, right = 10, top = 8, bottom = 8 })
    ui.log_pad_left = clamp_int(log_padding.left, 0, ui.content_w, 10)
    ui.log_pad_right = clamp_int(log_padding.right, 0, ui.content_w, 10)
    ui.log_pad_top = clamp_int(log_padding.top, 0, ui.log_min_h, 8)
    ui.log_pad_bottom = clamp_int(log_padding.bottom, 0, ui.log_min_h, 8)

    ui.btn_zone_h = clamp_int(cfg.button_zone.h, 24, screen_h, 56)
    local btn_zone_padding = read_box(cfg.button_zone.padding, { left = 0, right = 0, top = 0, bottom = 0 })
    ui.btn_zone_pad_left = clamp_int(btn_zone_padding.left, 0, ui.content_w, 0)
    ui.btn_zone_pad_right = clamp_int(btn_zone_padding.right, 0, ui.content_w, 0)
    ui.btn_zone_pad_top = clamp_int(btn_zone_padding.top, 0, ui.btn_zone_h, 0)
    ui.btn_zone_pad_bottom = clamp_int(btn_zone_padding.bottom, 0, ui.btn_zone_h, 0)
    ui.btn_gap = clamp_int(cfg.button_zone.gap, 2, 16, 6)

    ui.btn_h = clamp_int(cfg.button.h, 22, ui.btn_zone_h, 34)
    ui.btn_radius = clamp_int(cfg.button.radius, 0, 30, 16)
    local btn_min_w = clamp_int(cfg.button.min_w, 24, ui.content_w, 40)

    local btn_inner_w = ui.content_w - ui.btn_zone_pad_left - ui.btn_zone_pad_right
    local btn_inner_h = ui.btn_zone_h - ui.btn_zone_pad_top - ui.btn_zone_pad_bottom
    if btn_inner_w < 120 then
        ui.btn_zone_pad_left = 0
        ui.btn_zone_pad_right = 0
        btn_inner_w = ui.content_w
    end
    if btn_inner_h < 20 then
        ui.btn_zone_pad_top = 0
        ui.btn_zone_pad_bottom = 0
        btn_inner_h = ui.btn_zone_h
    end

    if ui.btn_h > btn_inner_h then
        ui.btn_h = math.max(20, btn_inner_h)
    end

    if ui.button_vertical then
        ui.btn_w = btn_inner_w
        if ui.btn_w < btn_min_w then ui.btn_w = btn_min_w end
        if ui.btn_w > btn_inner_w then ui.btn_w = btn_inner_w end
        local total_h = ui.btn_h * 3 + ui.btn_gap * 2
        if total_h > btn_inner_h then
            ui.btn_h = math.max(20, math.floor((btn_inner_h - ui.btn_gap * 2) / 3))
        end
        ui.btn_single_w = ui.btn_w
        ui.btn_pair_w = ui.btn_w
    elseif ui.button_circle_split then
        ui.btn_w = math.floor((btn_inner_w - ui.btn_gap) / 2)
        if ui.btn_w < btn_min_w then
            ui.btn_gap = 2
            ui.btn_w = math.floor((btn_inner_w - ui.btn_gap) / 2)
        end
        if ui.btn_w < btn_min_w then
            ui.btn_w = math.max(24, math.floor(btn_inner_w / 2))
            ui.btn_gap = math.max(0, btn_inner_w - ui.btn_w * 2)
        end
        if ui.btn_w > btn_inner_w then ui.btn_w = btn_inner_w end
        local total_h = ui.btn_h * 2 + ui.btn_gap
        if total_h > btn_inner_h then
            ui.btn_h = math.max(20, math.floor((btn_inner_h - ui.btn_gap) / 2))
        end
        local pair_ratio = tonumber(cfg.button_zone.pair_item_ratio) or 0.88
        local pair_item_w = math.floor(ui.btn_w * pair_ratio)
        if pair_item_w < btn_min_w then pair_item_w = btn_min_w end
        if pair_item_w > ui.btn_w then pair_item_w = ui.btn_w end

        local pair_row_w = pair_item_w * 2 + ui.btn_gap
        if pair_row_w > btn_inner_w then
            pair_item_w = math.max(btn_min_w, math.floor((btn_inner_w - ui.btn_gap) / 2))
            pair_row_w = pair_item_w * 2 + ui.btn_gap
        end

        ui.btn_single_w = ui.btn_w
        ui.btn_pair_item_w = pair_item_w
        ui.btn_pair_w = pair_row_w
    else
        ui.btn_w = math.floor((btn_inner_w - ui.btn_gap * 2) / 3)
        if ui.btn_w < btn_min_w then
            ui.btn_gap = 2
            ui.btn_w = math.floor((btn_inner_w - ui.btn_gap * 2) / 3)
        end
        if ui.btn_w < btn_min_w then
            ui.btn_w = math.max(24, math.floor(btn_inner_w / 3))
            ui.btn_gap = math.max(0, math.floor((btn_inner_w - ui.btn_w * 3) / 2))
        end
        if ui.btn_w > btn_inner_w then ui.btn_w = btn_inner_w end
        ui.btn_single_w = ui.btn_w
        ui.btn_pair_w = ui.btn_w
    end

    local available_h = screen_h - ui.content_pad_top - ui.content_pad_bottom - ui.content_row_gap * 2
    local fit_log_min = available_h - ui.top_zone_h - ui.btn_zone_h
    if fit_log_min < 32 then
        local deficit = 32 - fit_log_min
        local reduce_top = math.min(deficit, math.max(0, ui.top_zone_h - 24))
        ui.top_zone_h = ui.top_zone_h - reduce_top
        local remain = deficit - reduce_top
        if remain > 0 then
            local reduce_btn = math.min(remain, math.max(0, ui.btn_zone_h - 30))
            ui.btn_zone_h = ui.btn_zone_h - reduce_btn
        end
        fit_log_min = available_h - ui.top_zone_h - ui.btn_zone_h
    end
    if fit_log_min < 32 then fit_log_min = 32 end
    if ui.log_min_h > fit_log_min then ui.log_min_h = fit_log_min end

    ui.log_w = ui.content_w
    ui.log_text_w = math.max(20, ui.log_w - ui.log_pad_left - ui.log_pad_right)
    ui.log_text_h_min = math.max(20, ui.log_min_h - ui.log_pad_top - ui.log_pad_bottom)

    return ui
end

return M
