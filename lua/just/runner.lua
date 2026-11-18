-- 命令组装与执行
local config = require('just.config')

local M = {}

-- 上一次命令的终端 buffer（窗口关闭后仍然保留，用于重新查看日志）
local lastTerminalBuf = nil
local lastTerminalRunning = false

--- 把输入字符串切分为参数（支持单/双引号与反斜杠转义）
--- @param input string
--- @return string[]
function M.tokenize(input)
    local tokens = {}
    local current = {}
    local quote = nil
    local hasContent = false
    local i = 1

    while i <= #input do
        local char = input:sub(i, i)
        if quote then
            if char == quote then
                quote = nil
            elseif char == '\\' and quote == '"' and i < #input then
                i = i + 1
                current[#current + 1] = input:sub(i, i)
            else
                current[#current + 1] = char
            end
        elseif char == '"' or char == "'" then
            quote = char
            hasContent = true
        elseif char:match('%s') then
            if #current > 0 or hasContent then
                tokens[#tokens + 1] = table.concat(current)
                current = {}
                hasContent = false
            end
        elseif char == '\\' and i < #input then
            i = i + 1
            current[#current + 1] = input:sub(i, i)
            hasContent = true
        else
            current[#current + 1] = char
            hasContent = true
        end
        i = i + 1
    end

    if #current > 0 or hasContent then
        tokens[#tokens + 1] = table.concat(current)
    end
    return tokens
end

--- 组装 just 命令
--- @param opts table { justfile: string, recipe: string, args?: string }
--- @return string[]
function M.buildCommand(opts)
    local cmd = { 'just' }
    vim.list_extend(cmd, config.options.justArgs or {})
    cmd[#cmd + 1] = '--justfile'
    cmd[#cmd + 1] = opts.justfile
    cmd[#cmd + 1] = opts.recipe
    vim.list_extend(cmd, M.tokenize(opts.args or ''))
    return cmd
end

--- 格式化耗时
--- @param seconds number
--- @param decimals integer|nil 小于 60 秒时的小数位数
--- @return string
function M.formatDuration(seconds, decimals)
    if seconds < 60 then
        return string.format('%.' .. tostring(decimals or 2) .. 'fs', seconds)
    end
    local total = math.floor(seconds)
    local hours = math.floor(total / 3600)
    local minutes = math.floor((total % 3600) / 60)
    local remain = total % 60
    if hours > 0 then
        return string.format('%dh %02dm %02ds', hours, minutes, remain)
    end
    return string.format('%dm %02ds', minutes, remain)
end

--- 获取 nvim-notify 对应级别的图标（未使用 nvim-notify 时返回 nil）
--- @param levelName string
--- @return string|nil
local function nvimNotifyIcon(levelName)
    local ok, notify = pcall(require, 'notify')
    if not ok or type(notify) ~= 'table' or type(notify._config) ~= 'function' then
        return nil
    end
    local configOk, config = pcall(notify._config)
    if not configOk or type(config) ~= 'table' or type(config.icons) ~= 'function' then
        return nil
    end
    local iconsOk, icons = pcall(config.icons)
    if not iconsOk or type(icons) ~= 'table' then
        return nil
    end
    return icons[levelName]
end

--- 给终端 buffer 设置 Esc 关闭窗口（保留 buffer）
--- @param buf integer
local function mapCloseWindow(buf)
    vim.keymap.set({ 'n', 't' }, '<Esc>', function()
        if #vim.api.nvim_list_wins() > 1 then
            pcall(vim.api.nvim_win_close, 0, true)
        end
    end, {
        buffer = buf,
        silent = true,
        nowait = true,
        desc = '关闭 just 终端窗口',
    })
end

--- 在窗口中显示终端 buffer
--- @param buf integer
--- @param running boolean
--- @return boolean
local function openBuffer(buf, running)
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        vim.notify('just.nvim: 没有可查看的终端日志', vim.log.levels.WARN)
        return false
    end

    mapCloseWindow(buf)

    local wins = vim.fn.win_findbuf(buf)
    if #wins > 0 then
        vim.fn.win_gotoid(wins[1])
        if running then
            vim.cmd.startinsert()
        end
        return true
    end

    local height = math.max(1, math.floor(tonumber(config.options.run.height) or 15))
    vim.cmd(('botright %dsplit'):format(height))
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)

    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = 'no'
    vim.wo[win].foldcolumn = '0'
    vim.wo[win].wrap = false
    vim.wo[win].list = false

    -- 定位到最后一行，方便直接看到最新日志
    local lineCount = vim.api.nvim_buf_line_count(buf)
    pcall(vim.api.nvim_win_set_cursor, win, { lineCount, 0 })

    if running then
        vim.cmd.startinsert()
    end
    return true
end

--- 在底部终端窗口中执行命令
--- @param jobCmd string[]
--- @param cwd string
--- @param recipe string
local function runInTerminal(jobCmd, cwd, recipe)
    local run = config.options.run
    local startHr = vim.uv.hrtime()

    -- 只保留最近一次命令的日志；上一次的日志如果已经不在窗口中显示且已结束，就清掉
    if
        lastTerminalBuf
        and vim.api.nvim_buf_is_valid(lastTerminalBuf)
        and not lastTerminalRunning
        and #vim.fn.win_findbuf(lastTerminalBuf) == 0
    then
        pcall(vim.api.nvim_buf_delete, lastTerminalBuf, { force = true })
    end

    -- 默认在底部打开终端窗口
    local height = math.max(1, math.floor(tonumber(run.height) or 15))
    vim.cmd(('botright %dnew'):format(height))
    local win = vim.api.nvim_get_current_win()
    local buffer = vim.api.nvim_get_current_buf()
    vim.bo[buffer].bufhidden = 'hide'
    vim.bo[buffer].swapfile = false
    mapCloseWindow(buffer)

    local timer = nil
    local timerDone = false
    local function stopTimer()
        if timerDone then
            return
        end
        timerDone = true
        if timer then
            pcall(timer.stop, timer)
            pcall(timer.close, timer)
        end
    end

    -- 运行中耗时通过 vim.notify 展示。
    -- nvim-notify 支持用 replace 原地刷新同一条通知，不会每秒弹一条新通知。
    local liveNotification = nil
    local liveOpen = false
    local lastNotifiedSecond = 0

    local function liveOptions(extra)
        return vim.tbl_extend('force', {
            hide_from_history = true,
            on_close = function()
                liveOpen = false
            end,
        }, extra or {})
    end

    local function startLiveNotification()
        if not run.notifyDuration then
            return
        end
        local ok, record = pcall(
            vim.notify,
            ('just.nvim: %s 运行中 · %s'):format(recipe, M.formatDuration(0, 0)),
            vim.log.levels.INFO,
            liveOptions({ timeout = false })
        )
        if ok and type(record) == 'table' and record.id then
            liveNotification = record
            liveOpen = true
        end
    end

    local function updateLiveNotification(seconds)
        if not liveOpen or not liveNotification then
            return
        end
        local ok, record = pcall(
            vim.notify,
            ('just.nvim: %s 运行中 · %s'):format(recipe, M.formatDuration(seconds, 0)),
            vim.log.levels.INFO,
            liveOptions({ timeout = false, replace = liveNotification })
        )
        if ok and type(record) == 'table' and record.id then
            liveNotification = record
        else
            liveOpen = false
        end
    end

    local function finishNotification(code, duration)
        if not run.notifyDuration then
            liveOpen = false
            return
        end
        local text
        local level
        if code == 0 then
            text = ('%s 完成，用时 %s'):format(recipe, duration)
            level = vim.log.levels.INFO
        else
            text = ('%s 失败（退出码 %d），用时 %s'):format(recipe, code, duration)
            level = vim.log.levels.WARN
        end
        local opts = {
            timeout = code == 0 and 2500 or 5000,
            hide_from_history = false,
        }
        if liveOpen and liveNotification then
            opts.replace = liveNotification
            -- replace 会沿用旧通知（INFO）的图标，失败时显式换成对应级别的图标
            local icon = nvimNotifyIcon(code == 0 and 'INFO' or 'WARN')
            if icon then
                opts.icon = icon
            end
        end
        pcall(vim.notify, 'just.nvim: ' .. text, level, opts)
        liveOpen = false
    end

    local ok, job = pcall(vim.fn.termopen, jobCmd, {
        cwd = cwd,
        on_exit = function(_, code)
            local seconds = (vim.uv.hrtime() - startHr) / 1e9
            if lastTerminalBuf == buffer then
                lastTerminalRunning = false
            end
            stopTimer()
            vim.schedule(function()
                local duration = M.formatDuration(seconds, 2)
                if run.notifyDuration then
                    finishNotification(code, duration)
                end
                -- 终端窗口保持打开，按 Esc 关闭；日志 buffer 一直保留
            end)
        end,
    })

    if not ok or job <= 0 then
        stopTimer()
        if vim.api.nvim_win_is_valid(win) then
            pcall(vim.api.nvim_win_close, win, true)
        end
        if vim.api.nvim_buf_is_valid(buffer) then
            pcall(vim.api.nvim_buf_delete, buffer, { force = true })
        end
        vim.notify('just.nvim: 无法启动终端任务', vim.log.levels.ERROR)
        return false
    end

    lastTerminalBuf = buffer
    lastTerminalRunning = true

    startLiveNotification()
    if liveOpen then
        timer = vim.uv.new_timer()
        if timer then
            timer:start(0, 200, vim.schedule_wrap(function()
                if timerDone then
                    return
                end
                local seconds = (vim.uv.hrtime() - startHr) / 1e9
                local whole = math.floor(seconds)
                if liveOpen and whole > lastNotifiedSecond and whole > 0 then
                    lastNotifiedSecond = whole
                    updateLiveNotification(seconds)
                end
                if not liveOpen then
                    stopTimer()
                end
            end))
        end
    end

    vim.cmd.startinsert()
    return true
end

--- 重新打开上一次命令的终端输出
--- @return boolean
function M.openLastLog()
    return openBuffer(lastTerminalBuf, lastTerminalRunning)
end

--- 执行 recipe
--- @param opts table { justfile: string, recipe: string, args?: string, cwd?: string }
--- @return boolean
function M.run(opts)
    if vim.fn.executable('just') ~= 1 then
        vim.notify('just.nvim: 未找到 just 可执行文件', vim.log.levels.ERROR)
        return false
    end

    local cwd = config.options.run.cwd or opts.cwd or vim.fs.dirname(opts.justfile) or vim.fn.getcwd()
    local cmd = M.buildCommand(opts)

    local ok, result = pcall(function()
        return runInTerminal(cmd, cwd, opts.recipe)
    end)
    if not ok then
        vim.notify('just.nvim: 执行失败: ' .. tostring(result), vim.log.levels.ERROR)
        return false
    end
    return result == true
end

return M
