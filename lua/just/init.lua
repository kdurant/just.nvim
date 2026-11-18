-- just.nvim 入口
local config = require('just.config')
local justfile = require('just.justfile')
local parser = require('just.parser')
local ui = require('just.ui')
local runner = require('just.runner')

local M = {}

--- 初始化插件
--- @param opts table|nil
function M.setup(opts)
    config.setup(opts)
end

--- 打开 recipe 选择窗口
--- @param opts table|nil { justfile?: string }
--- @return boolean
function M.open(opts)
    opts = opts or {}
    local path, root, err = justfile.find({
        justfile = opts.justfile or config.options.justfile,
    })
    if not path then
        vim.notify('just.nvim: ' .. (err or '未找到 justfile'), vim.log.levels.WARN)
        return false
    end

    local recipes, source, parseErr = parser.parse(path)
    if #recipes == 0 then
        local message = 'just.nvim: justfile 中没有可用的 recipe'
        if parseErr then
            message = message .. '（' .. parseErr:gsub('%s+', ' ') .. '）'
        end
        vim.notify(message, vim.log.levels.WARN)
        return false
    end

    if source == 'manual' and parseErr then
        local reason = parseErr:gsub('%s+', ' ')
        if #reason > 160 then
            reason = reason:sub(1, 160) .. '…'
        end
        vim.notify('just.nvim: 使用简易解析：' .. reason, vim.log.levels.DEBUG)
    end

    return ui.open({
        justfile = path,
        root = root,
        recipes = recipes,
    })
end

--- 关闭选择窗口
function M.close()
    ui.close()
end

--- 查看上一次命令的终端输出
--- @return boolean
function M.openLog()
    return runner.openLastLog()
end

--- 打开/关闭切换
function M.toggle()
    if ui.isOpen() then
        ui.close()
    else
        M.open()
    end
end

return M
