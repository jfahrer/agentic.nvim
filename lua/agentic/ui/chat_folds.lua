local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")

local NS_TOOL_BLOCKS = vim.api.nvim_create_namespace("agentic_tool_blocks")

--- @class agentic.ui.ChatFolds.Policy
--- @field enabled boolean
--- @field min_lines integer

--- @class agentic.ui.ChatFolds.ToolCallFold
--- @field tool_call_id string
--- @field extmark_id integer
--- @field kind agentic.acp.ToolKind
--- @field status agentic.acp.ToolCallStatus
--- @field policy agentic.ui.ChatFolds.Policy
--- @field default_closed? boolean

--- @class agentic.ui.ChatFolds
--- @field bufnr integer
--- @field _tool_call_folds table<string, agentic.ui.ChatFolds.ToolCallFold>
--- @field _pending_tool_call_ids table<string, boolean>
--- @field _captured_window_states? table<integer, table<string, boolean|nil>>
local ChatFolds = {}
ChatFolds.__index = ChatFolds

--- @param kind agentic.acp.ToolKind
--- @return agentic.ui.ChatFolds.Policy policy
local function resolve_policy(kind)
    --- @type agentic.UserConfig.ToolCallFolding
    local tool_call_config = Config.folding and Config.folding.tool_calls
        or {
            enabled = true,
            min_lines = 20,
            kinds = {},
        }
    local family_enabled = tool_call_config.enabled ~= false
    --- @type agentic.UserConfig.ToolCallFoldingKind|nil
    local kind_config = tool_call_config.kinds[kind]

    --- @type boolean
    local enabled = family_enabled
    if family_enabled and kind_config and kind_config.enabled ~= nil then
        enabled = kind_config.enabled
    end

    --- @type integer
    local min_lines = tool_call_config.min_lines or 20
    if kind_config and kind_config.min_lines ~= nil then
        min_lines = kind_config.min_lines
    end

    --- @type agentic.ui.ChatFolds.Policy
    local policy = {
        enabled = enabled == true,
        min_lines = min_lines or 20,
    }
    return policy
end

--- @param bufnr integer
--- @return agentic.ui.ChatFolds chat_folds
function ChatFolds:new(bufnr)
    --- @type agentic.ui.ChatFolds
    local instance = {
        bufnr = bufnr,
        _tool_call_folds = {},
        _pending_tool_call_ids = {},
    }

    setmetatable(instance, self)
    return instance
end

--- @return string fold_text
function ChatFolds.foldtext()
    local line_count = vim.v.foldend - vim.v.foldstart + 1
    return string.format("response hidden (%d lines)", line_count)
end

--- @param tracker agentic.ui.MessageWriter.ToolCallBlock
--- @return agentic.ui.ChatFolds.ToolCallFold tool_call_fold
function ChatFolds:_ensure_tool_call_fold(tracker)
    local tool_call_fold = self._tool_call_folds[tracker.tool_call_id]

    if not tool_call_fold then
        --- @type agentic.ui.ChatFolds.ToolCallFold
        local new_tool_call_fold = {
            tool_call_id = tracker.tool_call_id,
            extmark_id = tracker.extmark_id,
            kind = tracker.kind,
            status = tracker.status,
            policy = resolve_policy(tracker.kind),
        }

        self._tool_call_folds[tracker.tool_call_id] = new_tool_call_fold
        tool_call_fold = new_tool_call_fold
    else
        tool_call_fold.extmark_id = tracker.extmark_id
        tool_call_fold.kind = tracker.kind
        tool_call_fold.status = tracker.status
    end

    return tool_call_fold
end

--- @param extmark_id integer
--- @return integer|nil body_start_row
--- @return integer|nil body_end_row
--- @return integer|nil body_line_count
function ChatFolds:_resolve_body_range(extmark_id)
    local pos = vim.api.nvim_buf_get_extmark_by_id(
        self.bufnr,
        NS_TOOL_BLOCKS,
        extmark_id,
        { details = true }
    )

    if not pos or not pos[1] then
        return nil, nil, nil
    end

    local details = pos[3]
    local end_row = details and details.end_row
    if end_row == nil then
        return nil, nil, nil
    end

    local body_start_row = pos[1]
    local start_line =
        vim.api.nvim_buf_get_lines(self.bufnr, pos[1], pos[1] + 1, false)[1]

    if start_line and start_line:match("^ .-%b() $") then
        body_start_row = body_start_row + 1
    end

    local body_end_row = end_row - 1
    local body_line_count = math.max(0, body_end_row - body_start_row + 1)

    return body_start_row, body_end_row, body_line_count
end

--- @return integer[] winids
function ChatFolds:_get_visible_windows()
    local winids = {}

    for _, winid in ipairs(vim.fn.win_findbuf(self.bufnr)) do
        if vim.api.nvim_win_is_valid(winid) then
            table.insert(winids, winid)
        end
    end

    return winids
end

--- @param winid integer
function ChatFolds:_configure_window(winid)
    vim.api.nvim_set_option_value("foldmethod", "manual", { win = winid })
    vim.api.nvim_set_option_value("foldenable", true, { win = winid })
    vim.api.nvim_set_option_value("foldlevel", 99, { win = winid })
    vim.api.nvim_set_option_value(
        "foldtext",
        "v:lua.require'agentic.ui.chat_folds'.foldtext()",
        { win = winid }
    )
end

--- @param winid integer
--- @param line_nr integer
--- @return boolean|nil is_closed
function ChatFolds:_get_fold_state(winid, line_nr)
    return vim.api.nvim_win_call(winid, function()
        if vim.fn.foldlevel(line_nr) == 0 then
            return nil
        end

        return vim.fn.foldclosed(line_nr) ~= -1
    end)
end

--- @param winid integer
--- @return table<string, boolean|nil> fold_states
function ChatFolds:_capture_window_fold_states(winid)
    local fold_states = {}

    for tool_call_id, tool_call_fold in pairs(self._tool_call_folds) do
        local body_start_row, _, body_line_count =
            self:_resolve_body_range(tool_call_fold.extmark_id)

        if body_start_row and body_line_count and body_line_count > 0 then
            fold_states[tool_call_id] =
                self:_get_fold_state(winid, body_start_row + 1)
        end
    end

    return fold_states
end

--- @param winid integer
--- @param line_nr integer
--- @param is_closed boolean
function ChatFolds:_set_fold_state(winid, line_nr, is_closed)
    vim.api.nvim_win_call(winid, function()
        local view = vim.fn.winsaveview()

        vim.api.nvim_win_set_cursor(0, { line_nr, 0 })
        if is_closed then
            vim.cmd("silent! normal! zc")
        else
            vim.cmd("silent! normal! zo")
        end

        vim.fn.winrestview(view)
    end)
end

--- @param winid integer
--- @param fold_states table<string, boolean|nil>
function ChatFolds:_restore_window_fold_states(winid, fold_states)
    for tool_call_id, fold_state in pairs(fold_states) do
        if fold_state ~= nil then
            local tool_call_fold = self._tool_call_folds[tool_call_id]
            if tool_call_fold then
                local body_start_row, _, body_line_count =
                    self:_resolve_body_range(tool_call_fold.extmark_id)

                if
                    body_start_row
                    and body_line_count
                    and body_line_count > 0
                then
                    self:_set_fold_state(winid, body_start_row + 1, fold_state)
                end
            end
        end
    end
end

function ChatFolds:capture_visible_window_states()
    --- @type table<integer, table<string, boolean|nil>>
    local captured_window_states = {}

    for _, winid in ipairs(self:_get_visible_windows()) do
        captured_window_states[winid] = self:_capture_window_fold_states(winid)
    end

    self._captured_window_states = captured_window_states
end

function ChatFolds:restore_visible_window_states()
    if not self._captured_window_states then
        return
    end

    for winid, fold_states in pairs(self._captured_window_states) do
        if vim.api.nvim_win_is_valid(winid) then
            self:_restore_window_fold_states(winid, fold_states)
        end
    end

    self._captured_window_states = nil
end

--- @param winid integer
--- @param tool_call_fold agentic.ui.ChatFolds.ToolCallFold
function ChatFolds:_sync_fold_to_window(winid, tool_call_fold)
    self:_configure_window(winid)

    local body_start_row, body_end_row, body_line_count =
        self:_resolve_body_range(tool_call_fold.extmark_id)

    if not body_start_row or not body_end_row or not body_line_count then
        Logger.debug(
            "Could not resolve body range for tool call fold",
            tool_call_fold.tool_call_id
        )
        return
    end

    if body_line_count < 1 then
        return
    end

    local start_line = body_start_row + 1
    local end_line = body_end_row + 1
    local fold_states = self:_capture_window_fold_states(winid)
    local fold_state = fold_states[tool_call_fold.tool_call_id]
    local should_close = fold_state
    if should_close == nil then
        should_close = tool_call_fold.default_closed == true
    end

    vim.api.nvim_win_call(winid, function()
        local view = vim.fn.winsaveview()

        vim.api.nvim_win_set_cursor(0, { start_line, 0 })
        vim.cmd("silent! normal! zD")
        vim.cmd(
            string.format("silent keepjumps %d,%dfold", start_line, end_line)
        )

        vim.fn.winrestview(view)
    end)

    self:_set_fold_state(winid, start_line, should_close)

    fold_states[tool_call_fold.tool_call_id] = nil
    self:_restore_window_fold_states(winid, fold_states)
end

--- @param tool_call_fold agentic.ui.ChatFolds.ToolCallFold
function ChatFolds:_decide_default_state(tool_call_fold)
    if tool_call_fold.default_closed ~= nil then
        return
    end

    if tool_call_fold.status == "failed" then
        tool_call_fold.default_closed = false
        return
    end

    if tool_call_fold.status ~= "completed" then
        return
    end

    local _, _, body_line_count =
        self:_resolve_body_range(tool_call_fold.extmark_id)
    tool_call_fold.default_closed = body_line_count ~= nil
        and body_line_count > 0
        and tool_call_fold.policy.enabled
        and body_line_count >= tool_call_fold.policy.min_lines
end

--- @param tracker agentic.ui.MessageWriter.ToolCallBlock
function ChatFolds:sync_tool_call(tracker)
    local tool_call_fold = self:_ensure_tool_call_fold(tracker)
    self:_decide_default_state(tool_call_fold)

    if tool_call_fold.default_closed ~= true then
        self._pending_tool_call_ids[tracker.tool_call_id] = nil
        return
    end

    local winids = self:_get_visible_windows()
    if #winids == 0 then
        self._pending_tool_call_ids[tracker.tool_call_id] = true
        return
    end

    self._pending_tool_call_ids[tracker.tool_call_id] = nil
    for _, winid in ipairs(winids) do
        self:_sync_fold_to_window(winid, tool_call_fold)
    end
end

--- @param winid integer
function ChatFolds:sync_pending(winid)
    for tool_call_id, _ in pairs(self._pending_tool_call_ids) do
        local tool_call_fold = self._tool_call_folds[tool_call_id]
        if tool_call_fold and tool_call_fold.default_closed then
            self:_sync_fold_to_window(winid, tool_call_fold)
        end
        self._pending_tool_call_ids[tool_call_id] = nil
    end
end

--- @param winid integer
function ChatFolds:on_buf_win_enter(winid)
    if not vim.api.nvim_win_is_valid(winid) then
        return
    end

    if vim.api.nvim_win_get_buf(winid) ~= self.bufnr then
        return
    end

    self:_configure_window(winid)
    self:sync_pending(winid)
end

return ChatFolds
