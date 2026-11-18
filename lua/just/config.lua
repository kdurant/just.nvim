-- just.nvim 配置管理
local M = {}

M.defaults = {
    -- 显式指定 justfile 路径（默认自动查找 git 根目录）
    justfile = nil,
    -- 追加给 just 的全局选项，例如 { '--dry-run' }
    justArgs = {},
    -- 按键映射，值可以是字符串或字符串列表
    keys = {
        up = { '<Up>', 'k' },
        down = { '<Down>', 'j' },
        run = { '<CR>' },
        close = { '<Esc>', '<C-c>' },
        toggleFocus = { '<Tab>' },
        clearArgs = { '<C-u>' },
    },
    ui = {
        border = 'rounded',
        -- 列表最大高度
        height = 15,
        -- 宽度上限：<1 时按编辑器宽度比例，>=1 时按列数
        width = 0.6,
        minWidth = 32,
        maxWidth = 100,
        -- center | cursor | top
        position = 'center',
        promptPrefix = '❯ ',
        showParams = true,
        showDoc = true,
        winblend = 0,
        zindex = 50,
    },
    run = {
        -- 终端窗口高度
        height = 15,
        -- 用 vim.notify 显示运行中耗时，结束后通知总耗时（nvim-notify 会原地刷新）
        notifyDuration = true,
        -- 执行目录，默认 justfile 所在目录
        cwd = nil,
    },
}

M.options = vim.deepcopy(M.defaults)

--- 合并用户配置：列表整体替换，非列表 table 递归合并
--- @param base table
--- @param user table
--- @return table
local function merge(base, user)
    if type(user) ~= 'table' then
        return base
    end
    local out = base
    for key, value in pairs(user) do
        local current = out[key]
        local bothTables = type(current) == 'table' and type(value) == 'table'
        if bothTables and not vim.islist(current) and not vim.islist(value) then
            out[key] = merge(vim.deepcopy(current), value)
        else
            out[key] = vim.deepcopy(value)
        end
    end
    return out
end

--- 初始化配置
--- @param opts table|nil
function M.setup(opts)
    M.options = merge(vim.deepcopy(M.defaults), opts or {})
end

--- 取某个动作的按键列表
--- @param action string
--- @return string[]
function M.keyList(action)
    local value = M.options.keys[action]
    if type(value) == 'string' then
        return { value }
    end
    if type(value) == 'table' then
        return value
    end
    return {}
end

return M
