local Config = require("agentic.config")
local Theme = require("agentic.theme")

--- @alias agentic.ui.ChatFoldType
--- | "tool_call"
--- | "thought"

--- @class agentic.ui.ChatFoldBlock
--- @field id? string
--- @field type agentic.ui.ChatFoldType
--- @field kind? string
--- @field status? string
--- @field summary? string
--- @field initial_state? agentic.UserConfig.FoldState
--- @field start_row integer
--- @field end_row integer

--- @class agentic.ui.ChatFolds
local ChatFolds = {}

--- @class agentic.ui.ChatFoldWindowState
--- @field block agentic.ui.ChatFoldBlock
--- @field is_closed boolean

local FOLDEXPR = "v:lua.require'agentic.ui.chat_folds'.foldexpr()"
local FOLDTEXT = "v:lua.require'agentic.ui.chat_folds'.foldtext()"

--- @private
--- @param winid integer
--- @param block agentic.ui.ChatFoldBlock
local function apply_initial_state(winid, block)
    local command = block.initial_state == "expanded" and "foldopen"
        or "foldclose"

    pcall(vim.api.nvim_win_call, winid, function()
        vim.cmd(string.format("%d%s", block.start_row + 1, command))
    end)
end

--- @private
--- @param winid integer
--- @return boolean uses_agentic_folds
local function window_uses_agentic_folds(winid)
    return vim.wo[winid].foldmethod == "expr"
        and vim.wo[winid].foldexpr == FOLDEXPR
end

--- @private
--- @param winid integer
--- @return table<string, boolean> applied_blocks
local function get_applied_blocks(winid)
    vim.w[winid].agentic_chat_fold_initial_states = vim.w[winid].agentic_chat_fold_initial_states
        or {}
    return vim.w[winid].agentic_chat_fold_initial_states
end

--- @private
--- @param winid integer
--- @param block agentic.ui.ChatFoldBlock
--- @return boolean is_closed
local function is_fold_closed(winid, block)
    return vim.api.nvim_win_call(winid, function()
        return vim.fn.foldclosed(block.start_row + 1) ~= -1
    end)
end

--- @private
--- @param winid integer
--- @param block agentic.ui.ChatFoldBlock
--- @param is_closed boolean
local function restore_fold_state(winid, block, is_closed)
    local command = is_closed and "foldclose" or "foldopen"

    pcall(vim.api.nvim_win_call, winid, function()
        vim.cmd(string.format("%d%s", block.start_row + 1, command))
    end)
end

--- @private
--- @param bufnr integer
--- @param winid integer
--- @param new_block_id string
--- @return agentic.ui.ChatFoldWindowState[] states
local function capture_existing_fold_states(bufnr, winid, new_block_id)
    --- @type agentic.ui.ChatFoldWindowState[]
    local states = {}

    for _, existing_block in ipairs(ChatFolds.get_blocks(bufnr)) do
        if existing_block.id ~= new_block_id then
            table.insert(states, {
                block = existing_block,
                is_closed = is_fold_closed(winid, existing_block),
            })
        end
    end

    return states
end

--- @private
--- @param bufnr integer
--- @param id string
--- @param block agentic.ui.ChatFoldBlock
--- @param force boolean|nil
local function apply_initial_state_to_visible_windows(bufnr, id, block, force)
    for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
        if window_uses_agentic_folds(winid) then
            local applied_blocks = get_applied_blocks(winid)
            if force or not applied_blocks[id] then
                local existing_fold_states =
                    capture_existing_fold_states(bufnr, winid, id)

                vim.api.nvim_win_call(winid, function()
                    vim.cmd("silent! normal! zx")
                end)

                for _, fold_state in ipairs(existing_fold_states) do
                    restore_fold_state(
                        winid,
                        fold_state.block,
                        fold_state.is_closed
                    )
                end

                apply_initial_state(winid, block)
                applied_blocks[id] = true
                vim.w[winid].agentic_chat_fold_initial_states = applied_blocks
            end
        end
    end
end

--- @private
--- @param bufnr integer
--- @param winid integer
local function reapply_initial_states(bufnr, winid)
    vim.api.nvim_win_call(winid, function()
        vim.cmd("silent! normal! zx")
    end)

    for _, block in ipairs(ChatFolds.get_blocks(bufnr)) do
        apply_initial_state(winid, block)
    end
end

--- @private
--- @param bufnr integer
--- @return table<string, agentic.ui.ChatFoldBlock> store
local function get_store(bufnr)
    vim.b[bufnr].agentic_chat_folds = vim.b[bufnr].agentic_chat_folds or {}
    return vim.b[bufnr].agentic_chat_folds
end

--- @param bufnr integer
--- @param id string
--- @param force boolean|nil
function ChatFolds.apply_initial_state(bufnr, id, force)
    local block = get_store(bufnr)[id]
    if block == nil then
        return
    end

    apply_initial_state_to_visible_windows(bufnr, id, block, force)
end

--- @private
--- @param bufnr integer
--- @return agentic.ui.ChatFoldBlock[]|nil blocks
local function get_cached_blocks(bufnr)
    return vim.b[bufnr].agentic_chat_fold_blocks_cache
end

--- @private
--- @param bufnr integer
--- @param row integer
--- @return agentic.ui.ChatFoldBlock|nil block
local function find_block_at_row(bufnr, row)
    for _, block in ipairs(ChatFolds.get_blocks(bufnr)) do
        if block.start_row > row then
            return nil
        end

        if block.start_row <= row and row <= block.end_row then
            return block
        end
    end

    return nil
end

--- @private
--- @param block agentic.ui.ChatFoldBlock
--- @return integer line_count
local function get_line_count(block)
    return (block.end_row - block.start_row) + 1
end

--- @param block_type "tool_call"|"thought"
--- @param kind string|nil
--- @return agentic.UserConfig.FoldState state
function ChatFolds.get_initial_state(block_type, kind)
    if block_type == "thought" then
        return Config.folds.thoughts.initial_state
    end

    if kind ~= nil then
        local tool_kind_state = Config.folds.tool_calls.by_kind[kind]
        if tool_kind_state ~= nil then
            return tool_kind_state
        end
    end

    return Config.folds.tool_calls.initial_state
end

--- @param bufnr integer
--- @param id string
--- @param block agentic.ui.ChatFoldBlock
function ChatFolds.upsert_block(bufnr, id, block)
    local store = get_store(bufnr)
    local is_new_block = store[id] == nil
    local merged_block =
        vim.tbl_extend("force", store[id] or {}, vim.deepcopy(block)) --[[@as agentic.ui.ChatFoldBlock]]
    store[id] = merged_block
    vim.b[bufnr].agentic_chat_folds = store
    vim.b[bufnr].agentic_chat_fold_blocks_cache = nil

    if is_new_block then
        apply_initial_state_to_visible_windows(bufnr, id, merged_block)
    end
end

--- @param bufnr integer
--- @return agentic.ui.ChatFoldBlock[] blocks
function ChatFolds.get_blocks(bufnr)
    local cached_blocks = get_cached_blocks(bufnr)
    if cached_blocks ~= nil then
        return cached_blocks
    end

    local store = get_store(bufnr)
    --- @type agentic.ui.ChatFoldBlock[]
    local items = {}

    for id, block in pairs(store) do
        local item = vim.tbl_extend("force", block, { id = id }) --[[@as agentic.ui.ChatFoldBlock]]
        table.insert(items, item)
    end

    table.sort(items, function(a, b)
        if a.start_row == b.start_row then
            return a.end_row < b.end_row
        end

        return a.start_row < b.start_row
    end)

    vim.b[bufnr].agentic_chat_fold_blocks_cache = items

    return items
end

--- @param bufnr integer
function ChatFolds.clear(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    vim.b[bufnr].agentic_chat_folds = {}
    vim.b[bufnr].agentic_chat_fold_blocks_cache = nil

    for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
        if window_uses_agentic_folds(winid) then
            vim.w[winid].agentic_chat_fold_initial_states = {}
            pcall(vim.api.nvim_win_call, winid, function()
                vim.cmd("silent! normal! zx")
            end)
        end
    end
end

--- @param block agentic.ui.ChatFoldBlock
--- @return string|table chunks
function ChatFolds.build_foldtext(block)
    local line_count = get_line_count(block)

    if block.type == "thought" then
        --- @type table
        local chunks = {
            { " Thought ", Theme.HL_GROUPS.THOUGHT },
            { block.summary or "reasoning hidden", Theme.HL_GROUPS.THOUGHT },
            { string.format("  %d lines ", line_count), "Comment" },
        }
        return chunks
    end

    local status = block.status or "pending"
    local icon = Config.status_icons[status] or ""
    local label = block.kind or "tool"
    if icon ~= "" then
        label = string.format("%s %s", icon, label)
    end

    --- @type table
    local chunks = {
        { string.format(" %s ", label), Theme.get_status_hl_group(status) },
        { block.summary or "", "Comment" },
        { string.format("  %d lines ", line_count), "Comment" },
    }
    return chunks
end

--- @param bufnr integer
--- @param row integer
--- @return integer|string fold_level
function ChatFolds.get_fold_level(bufnr, row)
    local block = find_block_at_row(bufnr, row)
    if block == nil then
        return 0
    end

    if block.start_row == block.end_row then
        return ">1"
    end

    if row == block.start_row then
        return ">1"
    end

    if row == block.end_row then
        return "<1"
    end

    return 1
end

--- @return integer|string fold_level
function ChatFolds.foldexpr()
    return ChatFolds.get_fold_level(
        vim.api.nvim_get_current_buf(),
        vim.v.lnum - 1
    )
end

--- @return string|table foldtext
function ChatFolds.foldtext()
    local bufnr = vim.api.nvim_get_current_buf()
    local block = find_block_at_row(bufnr, vim.v.foldstart - 1)
    if block == nil then
        return vim.fn.foldtext()
    end

    return ChatFolds.build_foldtext(block)
end

--- @param bufnr integer
--- @param winid integer
function ChatFolds.setup_window(bufnr, winid)
    get_store(bufnr)
    vim.w[winid].agentic_chat_fold_initial_states = {}
    vim.api.nvim_set_option_value("foldmethod", "expr", { win = winid })
    vim.api.nvim_set_option_value("foldexpr", FOLDEXPR, { win = winid })
    vim.api.nvim_set_option_value("foldtext", FOLDTEXT, { win = winid })
    vim.api.nvim_set_option_value("foldenable", true, { win = winid })
    reapply_initial_states(bufnr, winid)
end

--- @param winid integer
--- @param bufnr integer
function ChatFolds.set_window_options(winid, bufnr)
    ChatFolds.setup_window(bufnr, winid)
end

return ChatFolds
