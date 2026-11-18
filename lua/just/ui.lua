-- 浮动窗口 UI：recipe 列表 + 参数输入
local config = require('just.config')
local runner = require('just.runner')

local M = {}

local ns = vim.api.nvim_create_namespace('just.nvim')
local markerNs = vim.api.nvim_create_namespace('just.nvim.marker')
local promptNs = vim.api.nvim_create_namespace('just.nvim.prompt')
local augroup = 'JustNvim'

local state = {}

local HIGHLIGHTS = {
    JustNormal = { link = 'NormalFloat' },
    JustBorder = { link = 'FloatBorder' },
    JustTitle = { link = 'FloatTitle' },
    JustSelection = { link = 'CursorLine' },
    JustMarker = { link = 'Function' },
    JustRecipe = { link = 'Function' },
    JustParams = { link = 'Comment' },
    JustDoc = { link = 'Comment' },
    JustPrompt = { link = 'DiagnosticInfo' },
}

--- 定义默认高亮，用户可覆盖
local function defineHighlights()
    for name, spec in pairs(HIGHLIGHTS) do
        spec.default = true
        vim.api.nvim_set_hl(0, name, spec)
    end
end

--- 判断窗口是否有效
--- @param win integer|nil
--- @return boolean
local function winValid(win)
    return type(win) == 'number' and vim.api.nvim_win_is_valid(win)
end

--- 判断缓冲区是否有效
--- @param buf integer|nil
--- @return boolean
local function bufValid(buf)
    return type(buf) == 'number' and vim.api.nvim_buf_is_valid(buf)
end

--- 按显示宽度截断字符串
--- @param text string
--- @param maxWidth integer
--- @return string
local function truncateByWidth(text, maxWidth)
    if maxWidth <= 0 then
        return ''
    end
    if vim.fn.strdisplaywidth(text) <= maxWidth then
        return text
    end
    local result = ''
    local totalChars = vim.fn.strchars(text)
    for i = 0, totalChars - 1 do
        local char = vim.fn.strcharpart(text, i, 1)
        if vim.fn.strdisplaywidth(result .. char) > maxWidth - 1 then
            return result .. '…'
        end
        result = result .. char
    end
    return result
end

--- justfile 显示路径
--- @param path string
--- @return string
local function displayPath(path)
    local shown = vim.fn.fnamemodify(path, ':~:.')
    if vim.fn.strdisplaywidth(shown) > 60 then
        shown = '…' .. vim.fn.fnamemodify(path, ':t')
    end
    return shown
end

--- 渲染列表行
--- @param recipes table[]
--- @return string[]
local function renderLines(recipes)
    local ui = config.options.ui

    local signatures = {}
    local maxSignatureWidth = 0
    for i, recipe in ipairs(recipes) do
        local params = recipe.params or ''
        local signature = recipe.name
        if ui.showParams and params ~= '' then
            signature = signature .. ' ' .. params
        end
        signatures[i] = signature
        maxSignatureWidth = math.max(maxSignatureWidth, vim.fn.strdisplaywidth(signature))
    end

    local lines = {}
    for i, recipe in ipairs(recipes) do
        local signature = signatures[i]
        local line = '  ' .. signature
        if ui.showDoc and recipe.doc then
            -- 所有 recipe 的注释从同一列开始
            local padding = maxSignatureWidth - vim.fn.strdisplaywidth(signature)
            line = line .. string.rep(' ', padding) .. '  # ' .. recipe.doc
        end
        lines[i] = line
    end
    return lines
end

--- 计算窗口宽度
--- @param lines string[]
--- @return integer
local function computeWidth(lines)
    local ui = config.options.ui
    local columns = vim.o.columns
    local available = math.max(10, columns - 4)

    local contentWidth = 0
    for _, line in ipairs(lines) do
        contentWidth = math.max(contentWidth, vim.fn.strdisplaywidth(line))
    end

    local cap = ui.maxWidth or math.floor(columns * 0.9)
    local width = ui.width
    if type(width) == 'number' and width > 0 and width < 1 then
        width = math.floor(columns * width)
    end
    width = width or cap
    width = math.min(contentWidth + 2, cap, width)
    width = math.min(width, available)
    width = math.max(width, math.min(ui.minWidth or 32, available))
    return width
end

--- 计算浮动窗口位置（返回边框左上角行列）
--- @param totalHeight integer
--- @param width integer
--- @return integer row, integer col
local function computePosition(totalHeight, width)
    local position = config.options.ui.position or 'center'
    local lines = math.max(1, vim.o.lines - 1)
    local columns = vim.o.columns
    local totalWidth = width + 2
    local row, col

    if position == 'top' then
        row = 0
        col = math.max(0, math.floor((columns - totalWidth) / 2))
    elseif position == 'cursor' then
        local winRow, winCol = 0, 0
        local ok, winPos = pcall(vim.api.nvim_win_get_position, 0)
        if ok then
            winRow, winCol = winPos[1], winPos[2]
        end
        local cursorRow = winRow + vim.fn.winline() - 1
        row = cursorRow + 1
        if row + totalHeight > lines then
            row = cursorRow - totalHeight
        end
        row = math.max(0, row)
        col = math.max(0, math.min(winCol + vim.fn.wincol() - 1, columns - totalWidth))
    else
        row = math.max(0, math.floor((lines - totalHeight) / 2))
        col = math.max(0, math.floor((columns - totalWidth) / 2))
    end

    return row, col
end

--- 布局：重新计算两个窗口的位置
local function layout()
    if not winValid(state.listWin) or not winValid(state.inputWin) then
        return
    end
    local available = math.max(10, vim.o.columns - 4)
    state.width = math.min(state.width, available)
    state.listHeight = math.max(1, math.min(state.listHeight, vim.o.lines - 7))

    local totalHeight = state.listHeight + 5
    local borderRow, col = computePosition(totalHeight, state.width)
    local inputRow = borderRow + state.listHeight + 2

    vim.api.nvim_win_set_config(state.listWin, {
        relative = 'editor',
        row = borderRow,
        col = col,
        width = state.width,
        height = state.listHeight,
    })
    vim.api.nvim_win_set_config(state.inputWin, {
        relative = 'editor',
        row = inputRow,
        col = col,
        width = state.width,
        height = 1,
    })
end

--- 绘制 prompt 高亮
local function highlightPrompt()
    if not bufValid(state.inputBuf) then
        return
    end
    vim.api.nvim_buf_clear_namespace(state.inputBuf, promptNs, 0, -1)
    local arrow = vim.trim(state.prompt or '')
    local line = vim.api.nvim_buf_get_lines(state.inputBuf, 0, 1, false)[1] or ''
    if arrow == '' or #line < #arrow then
        return
    end
    vim.api.nvim_buf_set_extmark(state.inputBuf, promptNs, 0, 0, {
        end_col = #arrow,
        hl_group = 'JustPrompt',
    })
end

--- 读取输入窗口中的参数文本
--- @return string
local function getArgs()
    if not bufValid(state.inputBuf) then
        return ''
    end
    local line = vim.api.nvim_buf_get_lines(state.inputBuf, 0, 1, false)[1] or ''
    local prefix = state.prompt or ''
    if prefix ~= '' and vim.startswith(line, prefix) then
        return vim.trim(line:sub(#prefix + 1))
    end
    -- 容忍用户删掉了 prompt 末尾的空格
    local arrow = vim.trim(prefix)
    if arrow ~= '' and vim.startswith(line, arrow) then
        return vim.trim(line:sub(#arrow + 1))
    end
    return vim.trim(line)
end

--- 当前选中的 recipe
--- @return table|nil
local function selectedRecipe()
    return state.recipes[state.selected]
end

--- 输入窗口标题显示将要执行的命令
local function updateTitle()
    if not winValid(state.inputWin) then
        return
    end
    local recipe = selectedRecipe()
    if not recipe then
        return
    end
    local preview = 'just ' .. recipe.name
    local args = getArgs()
    if args ~= '' then
        preview = preview .. ' ' .. args
    end
    vim.api.nvim_win_set_config(state.inputWin, {
        title = ' ' .. truncateByWidth(preview, math.max(4, state.width - 4)) .. ' ',
    })
end

local adjustingPrompt = false

--- 保证输入行始终以 prompt 开头。
--- 这样无论终端如何发送退格键、或用户用鼠标/普通模式删除，prompt 都不会丢失。
local function enforcePrompt()
    if adjustingPrompt or not bufValid(state.inputBuf) then
        return
    end
    local prefix = state.prompt or ''
    if prefix == '' then
        return
    end
    local line = vim.api.nvim_buf_get_lines(state.inputBuf, 0, 1, false)[1] or ''
    if vim.startswith(line, prefix) then
        return
    end

    local arrow = vim.trim(prefix)
    local text = line
    if arrow ~= '' and vim.startswith(line, arrow) then
        text = line:sub(#arrow + 1)
    end
    local newLine = prefix .. text
    local added = #newLine - #line

    local col = 0
    if winValid(state.inputWin) then
        col = vim.api.nvim_win_get_cursor(state.inputWin)[2]
    end

    adjustingPrompt = true
    vim.api.nvim_buf_set_lines(state.inputBuf, 0, 1, false, { newLine })
    if winValid(state.inputWin) then
        vim.api.nvim_win_set_cursor(state.inputWin, { 1, math.max(0, col + added) })
    end
    highlightPrompt()
    adjustingPrompt = false
    updateTitle()
end

--- 更新选中标记
local function updateMarker()
    if not bufValid(state.listBuf) then
        return
    end
    vim.api.nvim_buf_clear_namespace(state.listBuf, markerNs, 0, -1)
    if #state.recipes == 0 then
        return
    end
    vim.api.nvim_buf_set_extmark(state.listBuf, markerNs, state.selected - 1, 0, {
        virt_text = { { '▸ ', 'JustMarker' } },
        virt_text_pos = 'overlay',
        hl_mode = 'combine',
    })
end

--- 同步选中项与光标
local function syncSelection()
    if not winValid(state.listWin) then
        return
    end
    local row = vim.api.nvim_win_get_cursor(state.listWin)[1]
    state.selected = math.max(1, math.min(row, #state.recipes))
    updateMarker()
    updateTitle()
end

--- 上/下移动（循环）
--- @param delta integer
local function move(delta)
    if #state.recipes == 0 or not winValid(state.listWin) then
        return
    end
    local current = vim.api.nvim_win_get_cursor(state.listWin)[1]
    local row = current + delta
    if row < 1 then
        row = #state.recipes
    elseif row > #state.recipes then
        row = 1
    end
    vim.api.nvim_win_set_cursor(state.listWin, { row, 0 })
    syncSelection()
end

--- 把光标移动到输入行末尾（普通模式只能停在最后一个字符上）
local function cursorToInputEnd()
    if not winValid(state.inputWin) or not bufValid(state.inputBuf) then
        return
    end
    local line = vim.api.nvim_buf_get_lines(state.inputBuf, 0, 1, false)[1] or ''
    vim.api.nvim_win_set_cursor(state.inputWin, { 1, math.max(0, #line - 1) })
end

--- 聚焦参数输入窗口
local function focusInput()
    if not winValid(state.inputWin) then
        return
    end
    vim.api.nvim_set_current_win(state.inputWin)
    cursorToInputEnd()
    -- 用 startinsert! 追加到行尾，避免插到 prompt 空格之前
    vim.cmd.startinsert({ bang = true })
end

--- 聚焦列表窗口
local function focusList()
    if not winValid(state.listWin) then
        return
    end
    vim.cmd.stopinsert()
    vim.api.nvim_set_current_win(state.listWin)
end

--- 替换参数文本
--- @param text string
local function setArgs(text)
    if not bufValid(state.inputBuf) then
        return
    end
    local line = (state.prompt or '') .. text
    vim.api.nvim_buf_set_lines(state.inputBuf, 0, 1, false, { line })
    highlightPrompt()
    if vim.api.nvim_get_mode().mode:sub(1, 1) == 'i' then
        vim.api.nvim_win_set_cursor(state.inputWin, { 1, #line })
    else
        cursorToInputEnd()
    end
    updateTitle()
end

--- 清空参数
local function clearArgs()
    setArgs('')
end

--- 执行选中的 recipe
local function run()
    local recipe = selectedRecipe()
    if not recipe then
        return
    end
    if vim.fn.executable('just') ~= 1 then
        vim.notify('just.nvim: 未找到 just 可执行文件', vim.log.levels.ERROR)
        return
    end

    local opts = {
        justfile = state.justfile,
        recipe = recipe.name,
        args = getArgs(),
        cwd = state.cwd,
    }

    -- 浮窗不能作为分割窗口的基准，先关闭
    M.close()
    runner.run(opts)
end

--- 关闭 UI
function M.close()
    pcall(vim.api.nvim_clear_autocmds, { group = augroup })

    local listWin, inputWin = state.listWin, state.inputWin
    local listBuf, inputBuf = state.listBuf, state.inputBuf

    if winValid(inputWin) then
        pcall(vim.api.nvim_win_close, inputWin, true)
    end
    if winValid(listWin) then
        pcall(vim.api.nvim_win_close, listWin, true)
    end
    for _, buf in ipairs({ inputBuf, listBuf }) do
        if bufValid(buf) then
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
    end

    state = {}
end

--- UI 是否打开
--- @return boolean
function M.isOpen()
    return winValid(state.listWin)
end

--- 获取内部状态（测试用）
--- @return table
function M.getState()
    return state
end

--- 给缓冲区设置按键映射
--- @param buf integer
--- @param keys string[]
--- @param modes string[]
--- @param rhs function
--- @param opts table|nil
local function mapKeys(buf, keys, modes, rhs, opts)
    for _, mode in ipairs(modes) do
        for _, lhs in ipairs(keys) do
            vim.keymap.set(
                mode,
                lhs,
                rhs,
                vim.tbl_extend('force', {
                    buffer = buf,
                    silent = true,
                    nowait = true,
                }, opts or {})
            )
        end
    end
end

--- 设置所有按键映射
local function setupKeymaps()
    local listBuf = state.listBuf
    local inputBuf = state.inputBuf

    -- 列表窗口
    mapKeys(listBuf, config.keyList('up'), { 'n' }, function()
        move(-1)
    end)
    mapKeys(listBuf, config.keyList('down'), { 'n' }, function()
        move(1)
    end)
    mapKeys(listBuf, config.keyList('run'), { 'n' }, run)
    mapKeys(listBuf, config.keyList('close'), { 'n' }, M.close)
    mapKeys(listBuf, config.keyList('toggleFocus'), { 'n' }, focusInput)

    -- 参数窗口
    mapKeys(inputBuf, config.keyList('up'), { 'i', 'n' }, function()
        move(-1)
    end)
    mapKeys(inputBuf, config.keyList('down'), { 'i', 'n' }, function()
        move(1)
    end)
    mapKeys(inputBuf, config.keyList('run'), { 'i', 'n' }, run)
    mapKeys(inputBuf, config.keyList('close'), { 'i', 'n' }, M.close)
    mapKeys(inputBuf, config.keyList('toggleFocus'), { 'i', 'n' }, focusList)
    mapKeys(inputBuf, config.keyList('clearArgs'), { 'i' }, clearArgs)

    -- 保护 prompt 前缀不被退格删掉
    vim.keymap.set('i', '<BS>', function()
        local col = vim.api.nvim_win_get_cursor(0)[2]
        if col <= #(state.prompt or '') then
            return ''
        end
        -- 注意：不能用 nvim_replace_termcodes('<BS>')，某些终端下它会返回
        -- 内部键码 "<80>kb"，作为 expr 映射返回值时会被当成普通文本插入。
        -- 直接返回退格控制字符（Ctrl-H），在插入模式下等价于删除前一个字符。
        return '\b'
    end, { buffer = inputBuf, expr = true, silent = true, nowait = true })

    -- Ctrl-W 只删除参数部分
    vim.keymap.set('i', '<C-w>', function()
        local args = getArgs()
        if args == '' then
            return
        end
        setArgs(vim.trim(args:gsub('%s*%S+%s*$', '')))
    end, { buffer = inputBuf, silent = true, nowait = true })
end

--- 设置自动命令
local function setupAutocmds()
    local group = vim.api.nvim_create_augroup(augroup, { clear = true })

    vim.api.nvim_create_autocmd('CursorMoved', {
        group = group,
        buffer = state.listBuf,
        callback = syncSelection,
    })
    vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
        group = group,
        buffer = state.inputBuf,
        callback = function()
            enforcePrompt()
            updateTitle()
        end,
    })
    vim.api.nvim_create_autocmd('VimResized', {
        group = group,
        callback = layout,
    })
    vim.api.nvim_create_autocmd('ColorScheme', {
        group = group,
        callback = defineHighlights,
    })
end

--- 打开 UI
--- @param opts table { justfile: string, root: string, recipes: table[] }
--- @return boolean
function M.open(opts)
    if type(opts) ~= 'table' or type(opts.recipes) ~= 'table' or #opts.recipes == 0 then
        return false
    end

    M.close()
    defineHighlights()

    local ui = config.options.ui
    local recipes = opts.recipes
    local lines = renderLines(recipes)
    local width = computeWidth(lines)
    local listHeight = math.max(1, math.min(#recipes, ui.height or 15))
    listHeight = math.min(listHeight, math.max(1, vim.o.lines - 7))

    state = {
        justfile = opts.justfile,
        root = opts.root,
        cwd = config.options.run.cwd
            or (opts.justfile and vim.fs.dirname(opts.justfile))
            or vim.fn.getcwd(),
        recipes = recipes,
        selected = 1,
        prompt = ui.promptPrefix or '❯ ',
        width = width,
        listHeight = listHeight,
    }

    -- 列表缓冲区
    local listBuf = vim.api.nvim_create_buf(false, true)
    vim.bo[listBuf].bufhidden = 'wipe'
    vim.bo[listBuf].swapfile = false
    vim.api.nvim_buf_set_lines(listBuf, 0, -1, false, lines)

    for i, recipe in ipairs(recipes) do
        local row = i - 1
        local params = recipe.params or ''
        local nameStart = 2
        vim.api.nvim_buf_set_extmark(listBuf, ns, row, nameStart, {
            end_col = nameStart + #recipe.name,
            hl_group = 'JustRecipe',
        })
        if ui.showParams and params ~= '' then
            local paramsStart = nameStart + #recipe.name + 1
            vim.api.nvim_buf_set_extmark(listBuf, ns, row, paramsStart, {
                end_col = paramsStart + #params,
                hl_group = 'JustParams',
            })
        end
        if ui.showDoc and recipe.doc then
            local docStart = lines[i]:find('  # ', 1, true)
            if docStart then
                vim.api.nvim_buf_set_extmark(listBuf, ns, row, docStart - 1, {
                    end_col = #lines[i],
                    hl_group = 'JustDoc',
                })
            end
        end
    end
    vim.bo[listBuf].modifiable = false
    state.listBuf = listBuf

    -- 参数输入缓冲区
    local inputBuf = vim.api.nvim_create_buf(false, true)
    vim.bo[inputBuf].bufhidden = 'wipe'
    vim.bo[inputBuf].swapfile = false
    vim.api.nvim_buf_set_lines(inputBuf, 0, -1, false, { state.prompt })
    vim.bo[inputBuf].modifiable = true
    state.inputBuf = inputBuf
    highlightPrompt()

    -- 列表窗口
    local totalHeight = listHeight + 5
    local borderRow, col = computePosition(totalHeight, width)
    local inputRow = borderRow + listHeight + 2

    local hints = ' ↑↓ 选择 · ⏎ 运行 · Tab 参数 · Esc 关闭 '
    if vim.fn.strdisplaywidth(hints) > width then
        hints = ' ↑↓ ⏎ Tab Esc '
    end

    local listTitle = truncateByWidth(' just · ' .. displayPath(opts.justfile) .. ' ', width - 2)
    local listWin = vim.api.nvim_open_win(listBuf, true, {
        relative = 'editor',
        row = borderRow,
        col = col,
        width = width,
        height = listHeight,
        style = 'minimal',
        border = ui.border,
        title = listTitle,
        title_pos = 'center',
        footer = hints,
        footer_pos = 'center',
        zindex = ui.zindex or 50,
    })
    state.listWin = listWin

    -- 参数窗口
    local inputWin = vim.api.nvim_open_win(inputBuf, false, {
        relative = 'editor',
        row = inputRow,
        col = col,
        width = width,
        height = 1,
        style = 'minimal',
        border = ui.border,
        title = ' ' .. truncateByWidth('just ' .. recipes[1].name, math.max(4, width - 4)) .. ' ',
        title_pos = 'center',
        zindex = (ui.zindex or 50) + 1,
    })
    state.inputWin = inputWin
    vim.api.nvim_win_set_cursor(inputWin, { 1, math.max(0, #state.prompt - 1) })

    vim.wo[listWin].winhl = 'Normal:JustNormal,FloatBorder:JustBorder,FloatTitle:JustTitle,CursorLine:JustSelection'
    vim.wo[listWin].winblend = ui.winblend or 0
    vim.wo[listWin].wrap = false
    vim.wo[listWin].cursorline = true
    vim.wo[listWin].cursorlineopt = 'line'

    vim.wo[inputWin].winhl = 'Normal:JustNormal,FloatBorder:JustBorder,FloatTitle:JustTitle'
    vim.wo[inputWin].winblend = ui.winblend or 0
    vim.wo[inputWin].wrap = false

    vim.api.nvim_win_set_cursor(listWin, { 1, 0 })

    setupKeymaps()
    setupAutocmds()
    syncSelection()

    return true
end

return M
