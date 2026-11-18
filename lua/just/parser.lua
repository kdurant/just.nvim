-- justfile 解析：优先使用 just 自身的 JSON dump，失败时退化为简单行解析
local M = {}

local KEYWORDS = {
    alias = true,
    export = true,
    import = true,
    mod = true,
    set = true,
    unexport = true,
}

--- 给默认值加引号（需要时）
--- @param value string
--- @return string
local function quoteValue(value)
    if value == '' then
        return '""'
    end
    if value:find('[%s\'"]') then
        local escaped = value:gsub('\\', '\\\\'):gsub('"', '\\"')
        return '"' .. escaped .. '"'
    end
    return value
end

--- vim.json 会把 null 解码成 vim.NIL，这里统一转成 nil
--- @param value any
--- @return any
local function jsonValue(value)
    if value == vim.NIL then
        return nil
    end
    return value
end

--- 格式化单个参数
--- @param param table just --dump 输出的参数结构
--- @return string
local function formatParam(param)
    local variant = ''
    if param.kind == 'star' then
        variant = '*'
    elseif param.kind == 'plus' then
        variant = '+'
    end

    local long = jsonValue(param.long)
    local short = jsonValue(param.short)
    local value = jsonValue(param.value)
    local defaultValue = jsonValue(param.default)

    -- 带 long/short 的参数是命令行选项
    if long ~= nil or short ~= nil then
        local text = long ~= nil and ('--' .. long) or ('-' .. short)
        if not param.flag and value == nil then
            text = text .. ' <' .. param.name .. '>'
        end
        return text
    end

    local text = variant .. param.name
    if defaultValue ~= nil then
        text = text .. '=' .. quoteValue(tostring(defaultValue))
    end
    return text
end

--- 格式化参数列表
--- @param params table[]
--- @return string
local function formatParams(params)
    local parts = {}
    for _, param in ipairs(params or {}) do
        parts[#parts + 1] = formatParam(param)
    end
    return table.concat(parts, ' ')
end

--- 判断 recipe 是否私有
--- @param recipe table
--- @return boolean
local function isPrivate(recipe)
    if recipe.private == true then
        return true
    end
    for _, attr in ipairs(recipe.attributes or {}) do
        if attr == 'private' then
            return true
        elseif type(attr) == 'table' then
            for key in pairs(attr) do
                if key == 'private' then
                    return true
                end
            end
        end
    end
    return false
end

--- 整理 doc 注释（多行合并为一行）
--- @param doc any
--- @return string|nil
local function normalizeDoc(doc)
    if type(doc) ~= 'string' then
        return nil
    end
    local text = vim.trim(doc:gsub('%s+', ' '))
    if text == '' then
        return nil
    end
    return text
end

--- 使用 just --dump 解析
--- @param path string
--- @return table[]|nil recipes, string|nil err
function M.parseWithJust(path)
    if vim.fn.executable('just') ~= 1 then
        return nil, 'just 未安装'
    end

    local ok, result = pcall(function()
        return vim.system(
            { 'just', '--justfile', path, '--dump', '--dump-format', 'json' },
            { text = true }
        ):wait(10000)
    end)
    if not ok or not result then
        return nil, '无法执行 just --dump'
    end
    if result.code ~= 0 then
        local err = vim.trim(result.stderr or '')
        return nil, err ~= '' and err or ('just --dump 退出码 ' .. tostring(result.code))
    end

    local decoded, data = pcall(vim.json.decode, result.stdout or '')
    if not decoded or type(data) ~= 'table' or type(data.recipes) ~= 'table' then
        return nil, 'just --dump 输出不是有效 JSON'
    end

    local recipes = {}
    for name, item in pairs(data.recipes) do
        if not isPrivate(item) then
            recipes[#recipes + 1] = {
                name = item.name or name,
                params = formatParams(item.parameters),
                doc = normalizeDoc(item.doc),
            }
        end
    end

    table.sort(recipes, function(a, b)
        return a.name:lower() < b.name:lower()
    end)
    return recipes
end

--- 找到 recipe 头部中的冒号（忽略引号内与 := 中的冒号）
--- @param line string
--- @return integer|nil
local function findHeaderColon(line)
    local quote = nil
    local escaped = false
    for i = 1, #line do
        local char = line:sub(i, i)
        if escaped then
            escaped = false
        elseif char == '\\' then
            escaped = true
        elseif quote then
            if char == quote then
                quote = nil
            end
        elseif char == '"' or char == "'" then
            quote = char
        elseif char == ':' then
            local nextChar = line:sub(i + 1, i + 1)
            if nextChar == '=' then
                return nil
            end
            return i
        end
    end
    return nil
end

--- 简单行解析（just 不可用或 dump 失败时使用）
--- @param path string
--- @return table[]
function M.parseManual(path)
    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok then
        return {}
    end

    local recipes = {}
    local pendingDoc = nil
    local pendingPrivate = false

    for _, raw in ipairs(lines) do
        local line = raw:gsub('\r$', '')
        local lineWithoutAt = line:gsub('^@', '')

        if line:match('^%s*$') then
            -- 空行会打断 doc 注释与 recipe 的关联
            pendingDoc = nil
            pendingPrivate = false
        elseif line:match('^%s*#') then
            local text = vim.trim(line:gsub('^%s*#%s?', ''))
            pendingDoc = pendingDoc and (pendingDoc .. ' ' .. text) or text
        elseif line:match('^%[') then
            if line:find('private', 1, true) then
                pendingPrivate = true
            end
        elseif line:match('^%s') then
            -- recipe body 或缩进内容，忽略
        else
            local name = lineWithoutAt:match('^([%a_][%w_%-]*)')
            local colon = name and findHeaderColon(lineWithoutAt) or nil
            if name and colon and not KEYWORDS[name] then
                if name:sub(1, 1) ~= '_' and not pendingPrivate then
                    local params = vim.trim(lineWithoutAt:sub(#name + 1, colon - 1):gsub('%s+', ' '))
                    recipes[#recipes + 1] = {
                        name = name,
                        params = params,
                        doc = pendingDoc,
                    }
                end
                pendingDoc = nil
                pendingPrivate = false
            else
                pendingDoc = nil
                pendingPrivate = false
            end
        end
    end

    table.sort(recipes, function(a, b)
        return a.name:lower() < b.name:lower()
    end)
    return recipes
end

--- 解析 justfile
--- @param path string
--- @return table[] recipes, string source, string|nil err
function M.parse(path)
    local recipes, err = M.parseWithJust(path)
    if recipes then
        return recipes, 'just', nil
    end
    return M.parseManual(path), 'manual', err
end

return M
