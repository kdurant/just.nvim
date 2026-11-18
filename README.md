# just.nvim

在 Neovim 里浏览并运行 git 根目录下 `justfile` 中的 recipe。

```
╭──────────── just · justfile ─────────────╮
│  build target=debug *flags  # 构建项目    │
│▸ test filter="" *flags      # 运行测试    │
│  clean                      # 清理        │
╰──────── ↑↓ 选择 · ⏎ 运行 · Tab 参数 ──────╯
╭──────────── just test --filter foo ──────╮
│❯ --filter foo                            │
╰───────────────────────────────────────────╯
```

## 功能

- 自动定位 git 根目录下的 `justfile` / `Justfile` / `.justfile`
- 使用 `just --dump --dump-format json` 解析命令；`just` 不可用或解析失败时退化为简单行解析
- 浮动窗口列出所有公开 recipe，显示参数默认值与 `#` 注释
- 方向键（默认同时支持 `j` / `k`）选择，`<Enter>` 执行
- 输入行的内容作为选中 recipe 的参数传递给 `just`
- 执行 recipe 时默认在底部打开终端窗口显示输出；命令结束后终端窗口保持打开
- 终端窗口中按 `<Esc>` 关闭窗口（日志 buffer 保留），`<space>jl` / `:JustLog` 可重新打开
- 运行期间通过 vim.notify 通知实时显示耗时，结束后通知总耗时
- 按键、浮窗尺寸、位置等均可配置

## 依赖

- Neovim >= 0.10
- [just](https://github.com/casey/just)（运行时需要）

## 安装

lazy.nvim:

```lua
{
    'yourname/just.nvim',
    config = function()
        require('just').setup()
        vim.keymap.set('n', '<leader>jj', function()
            require('just').open()
        end, { desc = 'Just recipes' })
        vim.keymap.set('n', '<leader>jl', function()
            require('just').openLog()
        end, { desc = 'Just last log' })
    end,
}
```

vim-plug:

```vim
Plug 'yourname/just.nvim'
```

手动安装：把仓库放到 `~/.local/share/nvim/site/pack/plugins/start/just.nvim`。

## 使用

```vim
:Just        " 打开选择窗口
:JustLog     " 查看上一次命令的终端输出
:JustClose   " 关闭选择窗口
```

或者调用 Lua API：

```lua
require('just').open()
require('just').openLog()
require('just').toggle()
require('just').close()
```

默认操作：

| 按键      | 作用                                        |
| --------- | ------------------------------------------- |
| `<Up>`/`k`   | 上一个 recipe                            |
| `<Down>`/`j` | 下一个 recipe                            |
| `<Enter>` | 执行选中的 recipe                           |
| `<Tab>`   | 在列表和参数输入行之间切换                  |
| `<Esc>`   | 关闭窗口                                    |
| `<C-u>`   | 清空参数输入行                              |

在参数输入行里，`<Up>` / `<Down>` 仍然用于切换 recipe，不影响输入。`<Tab>` 回到列表。

终端窗口中按 `<Esc>` 关闭窗口；日志 buffer 会保留，可用 `<space>jl` / `:JustLog` 重新打开。

## 参数如何传递

输入行内容会被追加到 recipe 名之后。例如选中 `build`，输入 `--release "hello world"`：

```
just --justfile /path/to/justfile build --release "hello world"
```

支持单引号、双引号和反斜杠转义。需要传给 `just` 本身的全局选项（如 `--dry-run`）请用配置里的 `justArgs`，不要写在输入行里（`just` 只接受位于 recipe 名之前的全局选项）。

## 配置

```lua
require('just').setup({
    -- 手动指定 justfile；默认自动查找
    justfile = nil,
    -- 追加给 just 的全局选项
    justArgs = {},
    -- 按键可以是字符串或字符串列表；列表整体替换默认值
    keys = {
        up = { '<Up>', 'k' },
        down = { '<Down>', 'j' },
        run = { '<CR>' },
        close = { '<Esc>', '<C-c>' },
        toggleFocus = { '<Tab>' },
        clearArgs = { '<C-u>' },
    },
    ui = {
        border = 'rounded',       -- 边框样式
        height = 15,             -- 列表最大高度
        width = 0.6,             -- 宽度上限；<1 为编辑器宽度比例，>=1 为列数
        minWidth = 32,
        maxWidth = 100,
        position = 'center',     -- center | cursor | top
        promptPrefix = '❯ ',
        showParams = true,       -- 显示参数
        showDoc = true,          -- 显示 # 注释
        winblend = 0,
        zindex = 50,
    },
    run = {
        height = 15,             -- 终端窗口高度
        notifyDuration = true,   -- 用 vim.notify 显示运行中/总耗时
        cwd = nil,               -- 默认 justfile 所在目录
    },
})
```

例如改成 `<C-p>` / `<C-n>` 选择：

```lua
require('just').setup({
    keys = { up = '<C-p>', down = '<C-n>' },
})
```

## 说明与限制

- 只列出公开 recipe，跳过 `_` 前缀和 `[private]` 的 recipe
- recipe 的 alias 和子模块（`mod`）暂不显示
- 执行目录默认为 justfile 所在目录；可用 `run.cwd` 覆盖
- 命令结束后终端窗口保持打开；按 `<Esc>` 关闭窗口（日志 buffer 保留）
- 终端日志只保留最近一次命令的；运行新命令时，旧的隐藏日志 buffer 会被清理
- 运行中的通知原地刷新依赖 nvim-notify；使用普通 `vim.notify` 时只会显示开始和结束两条消息
- 没有 git 仓库时会从当前文件所在目录向上查找 justfile
- 浮窗打开期间如果当前目录变化，不影响已经打开的选择窗口

## 开发

```sh
make test
```

测试使用独立的临时 git 仓库，不会修改项目本身的文件。
