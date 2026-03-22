local Logger = require("agentic.utils.logger")

--- @class agentic.ui.ChatFoldsPolicy
--- @field enabled boolean
--- @field min_lines number

--- @class agentic.ui.ChatFoldsBufferFoldMetadata
--- @field fold_start integer
--- @field fold_end integer
--- @field body_line_count integer

--- @class agentic.ui.ChatFoldsBufferFoldLookup
--- @field tool_call_id string
--- @field body_line_count integer

--- @class agentic.ui.ChatFoldsBufferState
--- @field by_tool_call_id table<string, agentic.ui.ChatFoldsBufferFoldMetadata>
--- @field by_fold_start table<integer, agentic.ui.ChatFoldsBufferFoldLookup>

--- @class agentic.ui.ChatFoldsToolCallDecision
--- @field kind string
--- @field enabled boolean
--- @field min_lines number
--- @field decided boolean
--- @field should_close boolean
--- @field body_line_count integer

--- @class agentic.ui.ChatFolds
--- @field bufnr integer
--- @field writer agentic.ui.MessageWriter
--- @field tool_calls table<string, agentic.ui.ChatFoldsBufferFoldMetadata>
--- @field _tool_call_decisions table<string, agentic.ui.ChatFoldsToolCallDecision>
--- @field _pending_tool_call_ids table<string, boolean>
local ChatFolds = {}
ChatFolds.__index = ChatFolds

local FOLDTEXT_EXPR = "v:lua.require'agentic.ui.chat_folds'.foldtext()"
local NS_TOOL_BLOCKS = vim.api.nvim_create_namespace("agentic_tool_blocks")

--- @param reason string
--- @param tool_call_id string
local function log_row_resolution_failure(reason, tool_call_id)
    Logger.debug(
        "[ChatFolds] Unable to resolve fold rows: " .. reason,
        { tool_call_id = tool_call_id }
    )
end

--- @param bufnr integer
--- @param state agentic.ui.ChatFoldsBufferState
local function set_buffer_state(bufnr, state)
    vim.b[bufnr].agentic_chat_folds = state
end

--- @param bufnr integer
--- @return agentic.ui.ChatFoldsBufferState state
local function ensure_buffer_state(bufnr)
    local state = vim.b[bufnr].agentic_chat_folds

    if state == nil then
        --- @type agentic.ui.ChatFoldsBufferState
        local new_state = {
            by_tool_call_id = {},
            by_fold_start = {},
        }
        set_buffer_state(bufnr, new_state)
        return new_state
    end

    if state.by_tool_call_id == nil then
        state.by_tool_call_id = {}
    end

    if state.by_fold_start == nil then
        state.by_fold_start = {}
    end

    set_buffer_state(bufnr, state)

    return state
end

--- @param kind string
--- @param config agentic.UserConfig|table|nil
--- @return agentic.ui.ChatFoldsPolicy policy
function ChatFolds.resolve_policy_for_test(kind, config)
    config = config or require("agentic.config")

    local normalized_kind = string.lower(kind)
    local family = config.folding.tool_calls
    local per_kind = family.kinds[normalized_kind] or {}

    --- @type agentic.ui.ChatFoldsPolicy
    local policy = {
        enabled = per_kind.enabled,
        min_lines = per_kind.min_lines,
    }

    if policy.enabled == nil then
        policy.enabled = family.enabled
    end

    if policy.min_lines == nil then
        policy.min_lines = family.min_lines
    end

    return policy
end

--- @param bufnr integer
--- @param writer agentic.ui.MessageWriter
--- @return agentic.ui.ChatFolds folds
function ChatFolds:new(bufnr, writer)
    local state = ensure_buffer_state(bufnr)

    --- @type agentic.ui.ChatFolds
    local folds = setmetatable({
        bufnr = bufnr,
        writer = writer,
        tool_calls = state.by_tool_call_id,
        _tool_call_decisions = {},
        _pending_tool_call_ids = {},
    }, self)

    return folds
end

--- @return string
function ChatFolds.foldtext()
    local bufnr = vim.api.nvim_get_current_buf()
    local state = vim.b[bufnr].agentic_chat_folds

    if state == nil or state.by_fold_start == nil then
        return "response hidden"
    end

    local metadata = state.by_fold_start[vim.v.foldstart]
    if metadata == nil then
        return "response hidden"
    end

    return string.format("response hidden (%d lines)", metadata.body_line_count)
end

function ChatFolds:_apply_window_fold_options()
    local wins = vim.fn.win_findbuf(self.bufnr)

    for _, winid in ipairs(wins) do
        if vim.api.nvim_win_is_valid(winid) then
            vim.wo[winid].foldmethod = "manual"
            vim.wo[winid].foldenable = true
            vim.wo[winid].foldtext = FOLDTEXT_EXPR
        end
    end
end

function ChatFolds:_apply_current_window_fold_options()
    local winid = vim.api.nvim_get_current_win()

    if vim.api.nvim_win_get_buf(winid) ~= self.bufnr then
        return
    end

    vim.wo[winid].foldmethod = "manual"
    vim.wo[winid].foldenable = true
    vim.wo[winid].foldtext = FOLDTEXT_EXPR
end

--- @return agentic.ui.ChatFoldsBufferState state
function ChatFolds:_get_buffer_state()
    local state = ensure_buffer_state(self.bufnr)
    self.tool_calls = state.by_tool_call_id
    return state
end

--- @param tool_call_id string
--- @return integer|nil body_start
--- @return integer|nil body_end
--- @return agentic.ui.MessageWriter.ToolCallBlock|nil tracker
function ChatFolds:_resolve_body_rows(tool_call_id)
    local tracker = self.writer.tool_call_blocks[tool_call_id]
    if tracker == nil then
        log_row_resolution_failure("tool call tracker missing", tool_call_id)
        return nil, nil, nil
    end

    if tracker.extmark_id == nil then
        log_row_resolution_failure("tool call extmark missing", tool_call_id)
        return nil, nil, tracker
    end

    local pos = vim.api.nvim_buf_get_extmark_by_id(
        self.bufnr,
        NS_TOOL_BLOCKS,
        tracker.extmark_id,
        { details = true }
    )
    if
        pos == nil
        or pos[1] == nil
        or pos[3] == nil
        or pos[3].end_row == nil
    then
        log_row_resolution_failure(
            "tool call extmark could not be resolved",
            tool_call_id
        )
        return nil, nil, tracker
    end

    local rows = {
        start_row = pos[1],
        end_row = pos[3].end_row,
        tracker = tracker,
    }

    local body_start = rows.start_row + 1
    local body_end = rows.end_row

    if body_end < body_start then
        log_row_resolution_failure(
            "tool call body range is empty",
            tool_call_id
        )
        return nil, nil, rows.tracker
    end

    return body_start, body_end, rows.tracker
end

--- @param tool_call_id string
--- @param fold_start integer
--- @param fold_end integer
--- @return boolean has_same_range
function ChatFolds:_has_existing_fold_range(tool_call_id, fold_start, fold_end)
    local state = self:_get_buffer_state()
    local existing = state.by_tool_call_id[tool_call_id]

    if existing == nil then
        return false
    end

    return existing.fold_start == fold_start and existing.fold_end == fold_end
end

--- @param fold_start integer
--- @return boolean folds_exist
function ChatFolds:_all_visible_windows_have_fold(fold_start)
    local wins = vim.fn.win_findbuf(self.bufnr)

    if #wins == 0 then
        return false
    end

    for _, winid in ipairs(wins) do
        if vim.api.nvim_win_is_valid(winid) then
            local has_fold = vim.api.nvim_win_call(winid, function()
                return vim.fn.foldlevel(fold_start) > 0
            end)

            if not has_fold then
                return false
            end
        end
    end

    return true
end

--- @param tool_call_id string
--- @param fold_start integer
--- @param fold_end integer
function ChatFolds:_store_fold_metadata(tool_call_id, fold_start, fold_end)
    local state = self:_get_buffer_state()
    local previous = state.by_tool_call_id[tool_call_id]

    if previous ~= nil then
        state.by_fold_start[previous.fold_start] = nil
    end

    local body_line_count = fold_end - fold_start + 1

    --- @type agentic.ui.ChatFoldsBufferFoldMetadata
    local by_tool_call_id = {
        fold_start = fold_start,
        fold_end = fold_end,
        body_line_count = body_line_count,
    }
    state.by_tool_call_id[tool_call_id] = by_tool_call_id

    --- @type agentic.ui.ChatFoldsBufferFoldLookup
    local by_fold_start = {
        tool_call_id = tool_call_id,
        body_line_count = body_line_count,
    }
    state.by_fold_start[fold_start] = by_fold_start

    set_buffer_state(self.bufnr, state)
end

--- @param tool_call_id string
function ChatFolds:_clear_existing_fold(tool_call_id)
    local state = self:_get_buffer_state()
    local previous = state.by_tool_call_id[tool_call_id]

    if previous == nil then
        return
    end

    local line_count = vim.api.nvim_buf_line_count(self.bufnr)
    if previous.fold_start > line_count then
        state.by_tool_call_id[tool_call_id] = nil
        state.by_fold_start[previous.fold_start] = nil
        set_buffer_state(self.bufnr, state)
        return
    end

    local wins = vim.fn.win_findbuf(self.bufnr)
    for _, winid in ipairs(wins) do
        if vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_win_call(winid, function()
                local view = vim.fn.winsaveview()

                vim.api.nvim_win_set_cursor(winid, { previous.fold_start, 0 })
                pcall(function()
                    vim.cmd("silent keepjumps normal! zd")
                end)

                vim.fn.winrestview(view)
            end)
        end
    end

    state.by_tool_call_id[tool_call_id] = nil
    state.by_fold_start[previous.fold_start] = nil
    set_buffer_state(self.bufnr, state)
end

--- @param tool_call_id string
function ChatFolds:_clear_pending_tool_call(tool_call_id)
    self._pending_tool_call_ids[tool_call_id] = nil
end

--- @param tracker agentic.ui.MessageWriter.ToolCallBlock
--- @param body_line_count integer
--- @return agentic.ui.ChatFoldsToolCallDecision decision
function ChatFolds:_get_tool_call_decision(tracker, body_line_count)
    local tool_call_id = tracker.tool_call_id
    local kind = string.lower(tracker.kind)
    local policy = ChatFolds.resolve_policy_for_test(kind)
    local existing = self._tool_call_decisions[tool_call_id]

    if existing ~= nil then
        existing.kind = kind
        existing.enabled = policy.enabled
        existing.min_lines = policy.min_lines

        if not existing.decided then
            existing.body_line_count = body_line_count
        end

        if tracker.status == "completed" and not existing.decided then
            existing.decided = true
            existing.body_line_count = body_line_count
            existing.should_close = policy.enabled
                and body_line_count >= policy.min_lines
        elseif tracker.status ~= "completed" then
            existing.should_close = false
        end

        return existing
    end

    --- @type agentic.ui.ChatFoldsToolCallDecision
    local decision = {
        kind = kind,
        enabled = policy.enabled,
        min_lines = policy.min_lines,
        decided = false,
        should_close = false,
        body_line_count = body_line_count,
    }

    if tracker.status == "completed" then
        decision.decided = true
        decision.should_close = policy.enabled
            and body_line_count >= policy.min_lines
    end

    self._tool_call_decisions[tool_call_id] = decision

    return decision
end

--- @param fold_start integer
--- @param fold_end integer
function ChatFolds:_create_manual_fold(fold_start, fold_end)
    local wins = vim.fn.win_findbuf(self.bufnr)

    for _, winid in ipairs(wins) do
        if vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_win_call(winid, function()
                vim.cmd(
                    string.format(
                        "silent keepjumps %d,%dfold",
                        fold_start,
                        fold_end
                    )
                )
            end)
        end
    end
end

--- @param fold_start integer
function ChatFolds:_open_fold(fold_start)
    local wins = vim.fn.win_findbuf(self.bufnr)

    for _, winid in ipairs(wins) do
        if vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_win_call(winid, function()
                local view = vim.fn.winsaveview()

                vim.api.nvim_win_set_cursor(winid, { fold_start, 0 })
                pcall(function()
                    vim.cmd("silent keepjumps normal! zo")
                end)

                vim.fn.winrestview(view)
            end)
        end
    end
end

--- @param tool_call_id string
--- @return boolean created
function ChatFolds:create_fold(tool_call_id)
    local fold_start, fold_end = self:_resolve_body_rows(tool_call_id)
    if fold_start == nil or fold_end == nil then
        return false
    end

    local wins = vim.fn.win_findbuf(self.bufnr)
    if #wins == 0 then
        return false
    end

    self:_apply_window_fold_options()

    if self:_has_existing_fold_range(tool_call_id, fold_start, fold_end) then
        return self:_all_visible_windows_have_fold(fold_start)
    end

    self:_clear_existing_fold(tool_call_id)
    self:_create_manual_fold(fold_start, fold_end)
    self:_store_fold_metadata(tool_call_id, fold_start, fold_end)
    return true
end

function ChatFolds:backfill_pending_for_current_window()
    self:_apply_current_window_fold_options()

    local pending_tool_call_ids = vim.tbl_keys(self._pending_tool_call_ids)
    for _, tool_call_id in ipairs(pending_tool_call_ids) do
        self:sync_tool_call(tool_call_id)
    end
end

function ChatFolds:reset()
    --- @type agentic.ui.ChatFoldsBufferState
    local state = {
        by_tool_call_id = {},
        by_fold_start = {},
    }

    set_buffer_state(self.bufnr, state)
    self.tool_calls = state.by_tool_call_id
    self._tool_call_decisions = {}
    self._pending_tool_call_ids = {}
end

--- @param tool_call_id string
--- @return boolean synced
function ChatFolds:sync_tool_call(tool_call_id)
    local fold_start, fold_end, tracker = self:_resolve_body_rows(tool_call_id)
    if fold_start == nil or fold_end == nil or tracker == nil then
        self:_clear_pending_tool_call(tool_call_id)
        self:_clear_existing_fold(tool_call_id)
        return false
    end

    local body_line_count = fold_end - fold_start + 1
    local decision = self:_get_tool_call_decision(tracker, body_line_count)
    local can_create_fold = decision.enabled
        and body_line_count >= decision.min_lines

    if tracker.status == "failed" and can_create_fold then
        if vim.fn.bufwinid(self.bufnr) == -1 then
            self._pending_tool_call_ids[tool_call_id] = true
            return false
        end

        self:_clear_pending_tool_call(tool_call_id)

        local had_existing_fold =
            self:_has_existing_fold_range(tool_call_id, fold_start, fold_end)
        local created = self:create_fold(tool_call_id)

        if created and not had_existing_fold then
            self:_open_fold(fold_start)
        end

        return created
    end

    if tracker.status ~= "completed" or not decision.should_close then
        self:_clear_pending_tool_call(tool_call_id)
        self:_clear_existing_fold(tool_call_id)
        return false
    end

    if vim.fn.bufwinid(self.bufnr) == -1 then
        self._pending_tool_call_ids[tool_call_id] = true
        return false
    end

    self:_clear_pending_tool_call(tool_call_id)

    if self:_has_existing_fold_range(tool_call_id, fold_start, fold_end) then
        return self:_all_visible_windows_have_fold(fold_start)
    end

    return self:create_fold(tool_call_id)
end

return ChatFolds
