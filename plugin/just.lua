-- just.nvim 用户命令
if vim.g.loaded_just_nvim then
    return
end
vim.g.loaded_just_nvim = 1

if vim.fn.has('nvim-0.10') == 0 then
    vim.notify('just.nvim 需要 Neovim 0.10 及以上版本', vim.log.levels.ERROR)
    return
end

vim.api.nvim_create_user_command('Just', function()
    require('just').open()
end, { desc = '打开 just recipe 选择窗口' })

vim.api.nvim_create_user_command('JustClose', function()
    require('just').close()
end, { desc = '关闭 just recipe 选择窗口' })

vim.api.nvim_create_user_command('JustLog', function()
    require('just').openLog()
end, { desc = '查看上一次 just 命令的终端输出' })
