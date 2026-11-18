-- justfile 定位：优先 git 根目录，其次从当前文件向上查找
local M = {}

local NAMES = { 'justfile', 'Justfile', '.justfile' }

--- 规范化路径为绝对路径
--- @param path string
--- @return string
local function normalize(path)
    return vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(path), ':p'))
end

--- 判断文件是否可读
--- @param path string|nil
--- @return boolean
local function isReadable(path)
    return type(path) == 'string' and path ~= '' and vim.fn.filereadable(path) == 1
end

--- 在指定目录下查找 justfile
--- @param dir string
--- @return string|nil
function M.findInDir(dir)
    for _, name in ipairs(NAMES) do
        local path = normalize(dir .. '/' .. name)
        if isReadable(path) then
            return path
        end
    end
    return nil
end

--- 获取 git 仓库根目录
--- @param start integer|string|nil 缓冲区编号或目录
--- @return string|nil
function M.gitRoot(start)
    local ok, root = pcall(vim.fs.root, start or 0, '.git')
    if ok then
        return root
    end
    return nil
end

--- 当前文件所在目录（非文件缓冲区返回 nil）
--- @return string|nil
local function bufferDir()
    local name = vim.api.nvim_buf_get_name(0)
    if name ~= '' and vim.bo.buftype == '' then
        return vim.fs.dirname(name)
    end
    return nil
end

--- 查找 justfile
--- @param opts table|nil { justfile?: string }
--- @return string|nil path, string|nil root, string|nil err
function M.find(opts)
    opts = opts or {}
    local cwd = vim.fn.getcwd()

    if opts.justfile and opts.justfile ~= '' then
        local path = normalize(opts.justfile)
        if isReadable(path) then
            return path, M.gitRoot(vim.fs.dirname(path)) or vim.fs.dirname(path)
        end
        return nil, nil, ('指定的 justfile 不可读: %s'):format(opts.justfile)
    end

    -- 优先使用 git 根目录下的 justfile
    local root = M.gitRoot(0) or M.gitRoot(cwd)
    if root then
        local found = M.findInDir(root)
        if found then
            return found, root
        end
    end

    -- 非 git 仓库时，从当前文件所在目录向上查找
    local start = bufferDir() or cwd
    local found = vim.fs.find(NAMES, {
        upward = true,
        path = start,
        type = 'file',
        limit = 1,
    })[1]
    if found then
        found = normalize(found)
        return found, root or vim.fs.dirname(found)
    end

    return nil, nil, '未找到 justfile（已查找 git 根目录与父目录）'
end

return M
