-- 测试入口：nvim --headless --clean -l tests/run.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())

local failures = {}

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        print('PASS ' .. name)
    else
        print('FAIL ' .. name .. '\n     ' .. tostring(err))
        failures[#failures + 1] = name
    end
end

local function eq(actual, expected, label)
    if not vim.deep_equal(actual, expected) then
        error(
            (label or '')
                .. '\n     期望: '
                .. vim.inspect(expected)
                .. '\n     实际: '
                .. vim.inspect(actual),
            2
        )
    end
end

local function names(recipes)
    local result = {}
    for _, recipe in ipairs(recipes) do
        result[#result + 1] = recipe.name
    end
    return result
end

-- 准备测试用 git 仓库
local repo = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(repo .. '/sub', 'p')
local justfilePath = repo .. '/justfile'
vim.fn.writefile({
    '# 默认任务',
    'default:',
    '    echo default',
    '',
    '# 构建项目',
    'build target="debug" *flags:',
    '    echo "{{target}} {{flags}}"',
    '',
    '_private:',
    '    echo private',
    '',
    '[private]',
    'secret:',
    '    echo secret',
    '',
    'alias b := build',
}, justfilePath)
vim.fn.writefile({ 'hello' }, repo .. '/sub/file.txt')
vim.fn.system({ 'git', '-C', repo, 'init', '-q' })

-- 无 justfile 的目录
local emptyDir = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(emptyDir, 'p')
vim.fn.writefile({ 'hello' }, emptyDir .. '/file.txt')

local parser = require('just.parser')
local runner = require('just.runner')
local justfile = require('just.justfile')
local config = require('just.config')

print('== tokenize ==')

test('普通参数', function()
    eq(runner.tokenize('a b  c'), { 'a', 'b', 'c' })
end)

test('双引号参数', function()
    eq(runner.tokenize('a "b c" d'), { 'a', 'b c', 'd' })
end)

test('单引号参数', function()
    eq(runner.tokenize("a 'b c' d"), { 'a', 'b c', 'd' })
end)

test('反斜杠转义', function()
    eq(runner.tokenize('a\\ b c'), { 'a b', 'c' })
end)

test('空输入', function()
    eq(runner.tokenize(''), {})
end)

test('空字符串参数', function()
    eq(runner.tokenize('""'), { '' })
end)

test('引号内含转义', function()
    eq(runner.tokenize('"a \\"b\\" c"'), { 'a "b" c' })
end)

print('== buildCommand ==')

test('默认命令组装', function()
    config.setup({})
    eq(runner.buildCommand({
        justfile = '/tmp/justfile',
        recipe = 'build',
        args = '--release  "hello world"',
    }), {
        'just',
        '--justfile',
        '/tmp/justfile',
        'build',
        '--release',
        'hello world',
    })
end)

test('全局 justArgs', function()
    config.setup({ justArgs = { '--dry-run' } })
    eq(runner.buildCommand({
        justfile = '/tmp/justfile',
        recipe = 'clean',
    }), { 'just', '--dry-run', '--justfile', '/tmp/justfile', 'clean' })
    config.setup({})
end)

print('== config ==')

test('按键映射可替换为单个按键', function()
    config.setup({ keys = { up = '<C-p>', down = '<C-n>' } })
    eq(config.keyList('up'), { '<C-p>' })
    eq(config.keyList('down'), { '<C-n>' })
    eq(config.keyList('run'), { '<CR>' })
    config.setup({})
end)

test('列表按键整体替换而不是按下标合并', function()
    config.setup({ keys = { up = { '<C-p>' } } })
    eq(config.keyList('up'), { '<C-p>' })
    config.setup({})
end)

test('嵌套配置合并', function()
    config.setup({ ui = { height = 5 } })
    eq(config.options.ui.height, 5)
    eq(config.options.ui.minWidth, 32)
    eq(config.options.run.height, 15)
    config.setup({})
end)

print('== justfile 定位 ==')

test('从子目录找到 git 根目录的 justfile', function()
    vim.cmd('cd ' .. vim.fn.fnameescape(repo))
    vim.cmd('edit ' .. vim.fn.fnameescape(repo .. '/sub/file.txt'))
    local path, root = justfile.find()
    eq(path, justfilePath)
    eq(root, repo)
end)

test('显式指定 justfile', function()
    vim.cmd('cd ' .. vim.fn.fnameescape(emptyDir))
    local path = justfile.find({ justfile = justfilePath })
    eq(path, justfilePath)
end)

test('找不到 justfile 时返回错误', function()
    vim.cmd('cd ' .. vim.fn.fnameescape(emptyDir))
    vim.cmd('edit ' .. vim.fn.fnameescape(emptyDir .. '/file.txt'))
    local path, _, err = justfile.find()
    eq(path, nil)
    eq(type(err), 'string')
end)

print('== 解析 justfile ==')

test('just --dump 解析', function()
    local recipes, source = parser.parse(justfilePath)
    eq(source, 'just')
    eq(names(recipes), { 'build', 'default' })
    eq(recipes[1].doc, '构建项目')
    eq(recipes[1].params, 'target=debug *flags')
    eq(recipes[2].doc, '默认任务')
end)

test('简易行解析', function()
    local recipes = parser.parseManual(justfilePath)
    eq(names(recipes), { 'build', 'default' })
    eq(recipes[1].doc, '构建项目')
    eq(recipes[1].params, 'target="debug" *flags')
    eq(recipes[2].doc, '默认任务')
end)

test('简易解析处理注释、属性和赋值', function()
    local path = repo .. '/fallback.just'
    vim.fn.writefile({
        '# 文档一',
        'alpha x="a:b" *rest:',
        '    echo x',
        '',
        '# 文档二',
        '[group("test")]',
        'beta:',
        '    echo b',
        '',
        'version := "1.0"',
        'export FOO := "bar"',
        'set shell := ["bash", "-c"]',
        'gamma: beta',
        '    echo g',
        '',
        'delta:',
        '    [ -f foo ] && echo private',
    }, path)
    local recipes = parser.parseManual(path)
    eq(names(recipes), { 'alpha', 'beta', 'delta', 'gamma' })
    eq(recipes[1].doc, '文档一')
    eq(recipes[1].params, 'x="a:b" *rest')
    eq(recipes[2].doc, '文档二')
    eq(recipes[3].doc, nil)
end)

test('没有 recipe 时返回空列表', function()
    local path = repo .. '/empty.just'
    vim.fn.writefile({ 'set shell := ["bash", "-c"]' }, path)
    eq(parser.parseManual(path), {})
end)

test('选项参数格式化', function()
    local path = repo .. '/options.just'
    vim.fn.writefile({
        'set unstable',
        'set lists',
        '',
        '# 构建',
        "[arg('release', long, flag)]",
        "[arg('target', long)]",
        "[arg('verbose', short, flag)]",
        'build $target="debug" release verbose:',
        '    echo "{{target}} {{release}} {{verbose}}"',
    }, path)
    local recipes, source = parser.parse(path)
    eq(source, 'just')
    eq(#recipes, 1)
    eq(recipes[1].params, '--target <target> --release -v')
end)

print('== UI ==')

local ui = require('just.ui')

test('浮动窗口打开、选择、执行', function()
    config.setup({})
    vim.cmd('cd ' .. vim.fn.fnameescape(repo))
    vim.cmd('edit ' .. vim.fn.fnameescape(repo .. '/file.txt'))

    local captured = nil
    local originalRun = runner.run
    runner.run = function(opts)
        captured = opts
        return true
    end

    local just = require('just')
    eq(just.open(), true)
    eq(ui.isOpen(), true)

    local state = ui.getState()
    eq(#state.recipes, 2)
    eq(state.selected, 1)
    eq(vim.api.nvim_get_current_win(), state.listWin)

    -- 注释内容从同一列开始
    local listLines = vim.api.nvim_buf_get_lines(state.listBuf, 0, -1, false)
    local docColumns = {}
    for _, line in ipairs(listLines) do
        local hashPos = line:find('#', 1, true)
        if hashPos then
            docColumns[#docColumns + 1] = vim.fn.strdisplaywidth(line:sub(1, hashPos - 1)) + 1
        end
    end
    eq(#docColumns >= 2, true)
    for i = 2, #docColumns do
        eq(docColumns[i], docColumns[1], '注释列应对齐')
    end

    local function feed(keys)
        vim.api.nvim_feedkeys(
            vim.api.nvim_replace_termcodes(keys, true, false, true),
            'x',
            false
        )
    end

    -- 方向键选择并循环
    feed('<Down>')
    eq(ui.getState().selected, 2)
    feed('<Down>')
    eq(ui.getState().selected, 1)
    feed('<Up>')
    eq(ui.getState().selected, 2)

    -- Tab 切换焦点
    feed('<Tab>')
    eq(vim.api.nvim_get_current_win(), ui.getState().inputWin)

    -- 退格映射必须是真正的退格字符，不能返回 <80>kb 内部键码
    local inputWin = ui.getState().inputWin
    local inputBuf = ui.getState().inputBuf
    local bsMap = vim.fn.maparg('<BS>', 'i', false, true)
    eq(type(bsMap.callback), 'function')
    vim.api.nvim_buf_set_lines(inputBuf, 0, 1, false, { '❯ abc' })
    vim.api.nvim_win_set_cursor(inputWin, { 1, 6 })
    eq(bsMap.callback(), '\b')
    vim.api.nvim_win_set_cursor(inputWin, { 1, 4 })
    eq(bsMap.callback(), '')

    -- 直接破坏 prompt 后，TextChangedI 应自动恢复
    vim.api.nvim_buf_set_lines(inputBuf, 0, 1, false, { 'abc' })
    vim.api.nvim_exec_autocmds('TextChangedI', { buffer = inputBuf })
    eq(vim.api.nvim_buf_get_lines(inputBuf, 0, 1, false)[1], '❯ abc')

    vim.api.nvim_buf_set_lines(inputBuf, 0, 1, false, { '❯abc' })
    vim.api.nvim_exec_autocmds('TextChangedI', { buffer = inputBuf })
    eq(vim.api.nvim_buf_get_lines(inputBuf, 0, 1, false)[1], '❯ abc')

    -- 模拟输入参数（headless 下 startinsert 不可靠，直接写入缓冲区）
    vim.api.nvim_buf_set_lines(inputBuf, 0, 1, false, { '❯ hello "world"' })
    feed('<CR>')

    eq(ui.isOpen(), false)
    eq(captured ~= nil, true)
    eq(captured.recipe, 'default')
    eq(captured.args, 'hello "world"')
    eq(captured.justfile, justfilePath)
    eq(captured.cwd, repo)

    runner.run = originalRun
end)

test('Esc 关闭窗口', function()
    config.setup({})
    vim.cmd('cd ' .. vim.fn.fnameescape(repo))
    local just = require('just')
    eq(just.open(), true)
    local listWin = ui.getState().listWin
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'x', false)
    eq(ui.isOpen(), false)
    eq(vim.api.nvim_win_is_valid(listWin), false)
end)

test('toggle 打开/关闭', function()
    config.setup({})
    vim.cmd('cd ' .. vim.fn.fnameescape(repo))
    local just = require('just')
    just.close()
    just.toggle()
    eq(ui.isOpen(), true)
    just.toggle()
    eq(ui.isOpen(), false)
end)

print('== 执行 ==')

local runnerJustfile = repo .. '/runner.just'
vim.fn.writefile({
    'noop:',
    '    true',
    '',
    'fail:',
    '    false',
    '',
    'slow:',
    '    sleep 2',
}, runnerJustfile)

test('耗时格式化', function()
    eq(runner.formatDuration(0.123, 2), '0.12s')
    eq(runner.formatDuration(5.5, 1), '5.5s')
    eq(runner.formatDuration(65, 2), '1m 05s')
    eq(runner.formatDuration(3661, 2), '1h 01m 01s')
end)

test('没有终端日志时提示', function()
    local messages = {}
    local originalNotify = vim.notify
    vim.notify = function(msg, level)
        messages[#messages + 1] = { msg = msg, level = level }
    end
    local ok = require('just').openLog()
    vim.notify = originalNotify

    eq(ok, false)
    eq(#messages, 1)
    eq(messages[1].msg:find('没有可查看', 1, true) ~= nil, true)
end)

test('默认打开终端，Esc 关闭后可重新查看日志', function()
    config.setup({})
    vim.cmd('cd ' .. vim.fn.fnameescape(repo))
    vim.cmd('edit ' .. vim.fn.fnameescape(repo .. '/file.txt'))

    local notifications = {}
    local originalNotify = vim.notify
    vim.notify = function(msg, level, opts)
        notifications[#notifications + 1] = { msg = msg, level = level, opts = opts }
    end

    local before = #vim.api.nvim_list_wins()
    eq(runner.run({ justfile = runnerJustfile, recipe = 'noop' }), true)
    eq(#vim.api.nvim_list_wins(), before + 1)

    local finished = vim.wait(5000, function()
        for _, notification in ipairs(notifications) do
            if notification.msg:find('完成', 1, true) then
                return true
            end
        end
        return false
    end, 50)
    vim.notify = originalNotify

    eq(finished, true)
    eq(#vim.api.nvim_list_wins(), before + 1)

    local running = nil
    local completed = nil
    for _, notification in ipairs(notifications) do
        if notification.msg:find('运行中', 1, true) then
            running = notification
        end
        if notification.msg:find('完成', 1, true) then
            completed = notification
        end
    end

    eq(running ~= nil, true)
    eq(running.opts.timeout, false)
    eq(completed ~= nil, true)
    eq(completed.msg:find('用时', 1, true) ~= nil, true)
    eq(completed.level, vim.log.levels.INFO)

    -- 运行结束后终端窗口保持打开
    local logWin = vim.api.nvim_get_current_win()
    local logBuf = vim.api.nvim_win_get_buf(logWin)
    eq(vim.bo[logBuf].buftype, 'terminal')

    -- 已显示时 openLog 只聚焦，不再开新窗口
    eq(require('just').openLog(), true)
    eq(#vim.api.nvim_list_wins(), before + 1)

    -- Esc 关闭终端窗口，buffer 保留
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'x', false)
    eq(#vim.api.nvim_list_wins(), before)
    eq(vim.api.nvim_buf_is_valid(logBuf), true)

    -- 关闭后可以用 openLog 重新打开
    eq(require('just').openLog(), true)
    eq(#vim.api.nvim_list_wins(), before + 1)
    logWin = vim.api.nvim_get_current_win()
    logBuf = vim.api.nvim_win_get_buf(logWin)

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'x', false)
    eq(#vim.api.nvim_list_wins(), before)
    pcall(vim.api.nvim_buf_delete, logBuf, { force = true })
    config.setup({})
end)

test('失败时终端保持打开并通知耗时', function()
    config.setup({})
    vim.cmd('cd ' .. vim.fn.fnameescape(repo))
    vim.cmd('edit ' .. vim.fn.fnameescape(repo .. '/file.txt'))

    local notifications = {}
    local originalNotify = vim.notify
    vim.notify = function(msg, level, opts)
        notifications[#notifications + 1] = { msg = msg, level = level, opts = opts }
    end

    local before = #vim.api.nvim_list_wins()
    eq(runner.run({ justfile = runnerJustfile, recipe = 'fail' }), true)
    eq(#vim.api.nvim_list_wins(), before + 1)
    local logWin = vim.api.nvim_get_current_win()
    local logBuf = vim.api.nvim_win_get_buf(logWin)

    local notified = vim.wait(5000, function()
        for _, notification in ipairs(notifications) do
            if notification.msg:find('失败', 1, true) then
                return true
            end
        end
        return false
    end, 50)
    vim.notify = originalNotify

    eq(notified, true)
    eq(#vim.api.nvim_list_wins(), before + 1)
    eq(vim.bo.buftype, 'terminal')

    local completed = nil
    for _, notification in ipairs(notifications) do
        if notification.msg:find('失败', 1, true) then
            completed = notification
        end
    end
    eq(completed ~= nil, true)
    eq(completed.msg:find('退出码 1', 1, true) ~= nil, true)
    eq(completed.msg:find('用时', 1, true) ~= nil, true)
    eq(completed.level, vim.log.levels.WARN)

    -- Esc 关闭窗口，buffer 保留
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'x', false)
    eq(#vim.api.nvim_list_wins(), before)
    eq(vim.api.nvim_buf_is_valid(logBuf), true)
    pcall(vim.api.nvim_buf_delete, logBuf, { force = true })
    config.setup({})
end)

test('运行中通过 vim.notify 原地刷新耗时', function()
    config.setup({})
    vim.cmd('cd ' .. vim.fn.fnameescape(repo))
    vim.cmd('edit ' .. vim.fn.fnameescape(repo .. '/file.txt'))

    local messages = {}
    local seq = 0
    local originalNotify = vim.notify
    vim.notify = function(msg, level, opts)
        seq = seq + 1
        messages[#messages + 1] = { msg = msg, level = level, opts = opts }
        return { id = seq }
    end

    local before = #vim.api.nvim_list_wins()
    eq(runner.run({ justfile = runnerJustfile, recipe = 'slow' }), true)
    eq(#vim.api.nvim_list_wins(), before + 1)

    -- 默认已经打开终端；openLog 只聚焦，不再开新窗口
    eq(require('just').openLog(), true)
    eq(#vim.api.nvim_list_wins(), before + 1)
    local logWin = vim.api.nvim_get_current_win()
    local logBuf = vim.api.nvim_win_get_buf(logWin)
    eq(vim.bo[logBuf].buftype, 'terminal')

    -- Esc 关闭窗口，命令继续在后台运行
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'x', false)
    eq(#vim.api.nvim_list_wins(), before)
    eq(vim.api.nvim_buf_is_valid(logBuf), true)

    -- 运行期间可以用 openLog 重新打开
    eq(require('just').openLog(), true)
    eq(#vim.api.nvim_list_wins(), before + 1)
    logWin = vim.api.nvim_get_current_win()
    logBuf = vim.api.nvim_win_get_buf(logWin)

    local finished = vim.wait(6000, function()
        for _, message in ipairs(messages) do
            if message.msg:find('完成', 1, true) then
                return true
            end
        end
        return false
    end, 100)
    vim.notify = originalNotify

    eq(finished, true)
    eq(#vim.api.nvim_list_wins(), before + 1)

    local runningCount = 0
    local updated = false
    local completed = nil
    for _, message in ipairs(messages) do
        if message.msg:find('运行中', 1, true) then
            runningCount = runningCount + 1
            if message.opts.replace then
                updated = true
            end
        end
        if message.msg:find('完成', 1, true) then
            completed = message
        end
    end

    eq(runningCount >= 2, true)
    eq(updated, true)
    eq(completed ~= nil, true)
    eq(completed.opts.replace ~= nil, true)

    -- Esc 关闭并清理 buffer
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'x', false)
    eq(#vim.api.nvim_list_wins(), before)
    pcall(vim.api.nvim_buf_delete, logBuf, { force = true })
    config.setup({})
end)

test('没有 justfile 时打开失败并提示', function()
    config.setup({})
    vim.cmd('cd ' .. vim.fn.fnameescape(emptyDir))
    vim.cmd('edit ' .. vim.fn.fnameescape(emptyDir .. '/file.txt'))
    local notifications = {}
    local originalNotify = vim.notify
    vim.notify = function(msg, level)
        notifications[#notifications + 1] = { msg = msg, level = level }
    end
    local ok = require('just').open()
    vim.notify = originalNotify
    eq(ok, false)
    eq(#notifications, 1)
    eq(notifications[1].msg:find('just.nvim', 1, true) ~= nil, true)
end)

-- 清理临时目录
vim.fn.delete(repo, 'rf')
vim.fn.delete(emptyDir, 'rf')

if #failures > 0 then
    print(('\n%d 个测试失败'):format(#failures))
    vim.cmd('cq')
else
    print('\n全部测试通过')
end
