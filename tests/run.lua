-- Run with: nvim --headless -u NONE -l tests/run.lua
local script = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
vim.opt.rtp:prepend(vim.fn.fnamemodify(script, ":h:h"))

local function run(args, cwd)
    local command = { "git", "-C", cwd }
    vim.list_extend(command, args)
    local result = vim.system(command, { text = true }):wait()
    assert(result.code == 0, result.stderr)
    return result
end

local temp = vim.fn.tempname()
local main = vim.fs.joinpath(temp, "main repo")
local linked = vim.fs.joinpath(temp, "linked repo")
local created = vim.fs.joinpath(temp, "created repo")
local unrelated = vim.fs.joinpath(temp, "unrelated directory")
vim.fn.mkdir(main, "p")
run({ "init", "-b", "main" }, main)
run({ "config", "user.email", "test@example.com" }, main)
run({ "config", "user.name", "Test" }, main)
vim.fn.writefile({ "initial" }, vim.fs.joinpath(main, "file.txt"))
run({ "add", "file.txt" }, main)
run({ "commit", "-m", "initial" }, main)
run({ "worktree", "add", "-b", "feature", linked }, main)

vim.cmd("cd " .. vim.fn.fnameescape(main))
local worktrees = require("worktrees")
local switched, opened, created_count, activated = 0, 0, 0, 0
local chosen
worktrees.setup({
    open_mode = "tab",
    picker = function(items, on_choice) on_choice(chosen(items)) end,
    on_switch = function() switched = switched + 1 end,
    on_tab_open = function() opened = opened + 1 end,
    on_create = function() created_count = created_count + 1 end,
})
vim.api.nvim_create_autocmd("User", {
    pattern = "WorktreeActivated",
    callback = function(event)
        assert(event.data.path ~= nil)
        activated = activated + 1
    end,
})

local listed = require("worktrees.git").get_worktrees(main)
assert(listed[main] and listed[linked], "worktree discovery failed")
assert(listed[linked].name == "feature", "branch parsing failed")

chosen = function(items)
    for _, item in ipairs(items) do if item.path == linked then return item end end
end
worktrees.browse()
local linked_tab = vim.api.nvim_get_current_tabpage()
assert(vim.fn.getcwd() == linked, "new tab cwd is not the target worktree")
assert(vim.t.name == "feature", "new tab was not named")
assert(opened == 1 and switched == 1 and activated == 1, "new-tab hooks/events incorrect")

vim.cmd("tabfirst")
local tab_count = #vim.api.nvim_list_tabpages()
worktrees.browse()
assert(#vim.api.nvim_list_tabpages() == tab_count, "reopening created a duplicate tab")
assert(vim.api.nvim_get_current_tabpage() == linked_tab, "existing tab was not focused")
assert(opened == 1 and switched == 2 and activated == 2, "reuse hooks/events incorrect")

vim.cmd("tabfirst")
chosen = function(items) return items[#items] end
local old_input = vim.ui.input
vim.ui.input = function(_, callback) callback(created) end
worktrees.browse()
vim.ui.input = old_input
assert(vim.fn.isdirectory(created) == 1, "new path was not created")
assert(vim.fn.getcwd() == created, "created worktree was not opened")
assert(require("worktrees.git").get_worktrees(main)[created], "created checkout not registered")
assert(created_count == 1 and opened == 2 and switched == 3, "creation hooks incorrect")

vim.fn.mkdir(unrelated, "p")
vim.cmd("tabfirst")
local tabs_before_invalid = #vim.api.nvim_list_tabpages()
vim.ui.input = function(_, callback) callback(unrelated) end
worktrees.browse()
assert(#vim.api.nvim_list_tabpages() == tabs_before_invalid, "existing directory opened as worktree")
vim.ui.input = function(_, callback) callback(nil) end
worktrees.browse()
vim.ui.input = old_input
assert(#vim.api.nvim_list_tabpages() == tabs_before_invalid, "canceling path prompt opened a tab")
assert(require("worktrees.git").get_worktrees(temp) == nil, "non-repository discovery should return nil")

vim.fn.delete(temp, "rf")
print("worktrees.nvim tests passed")
