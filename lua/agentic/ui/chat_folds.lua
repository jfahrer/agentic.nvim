local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")

local NS_TOOL_BLOCKS = vim.api.nvim_create_namespace("agentic_tool_blocks")
local FOLD_TEXT_PREFIXES_VAR = "_agentic_fold_text_prefixes"

--- @class agentic.ui.ChatFolds.Policy
--- @field enabled boolean
--- @field min_lines integer

--- @class agentic.ui.ChatFolds.ToolCallFold
--- @field tool_call_id string
--- @field extmark_id integer
--- @field kind agentic.acp.ToolKind
--- @field status agentic.acp.ToolCallStatus
--- @field policy agentic.ui.ChatFolds.Policy
--- @field fold_text_prefix string
--- @field should_render_fold? boolean
--- @field default_closed? boolean
--- @field last_known_fold_state? boolean

--- @class agentic.ui.ChatFolds
--- @field bufnr integer
--- @field _tool_call_folds table<string, agentic.ui.ChatFolds.ToolCallFold>
--- @field _pending_tool_call_ids table<string, boolean>
--- @field _reopen_restore_tool_call_ids table<string, boolean>
--- @field _captured_window_states? table<integer, table<string, boolean|nil>>
local ChatFolds = {}
ChatFolds.__index = ChatFolds

--- @param line_nr integer
--- @return string line_key
local function line_key(line_nr)
    return tostring(line_nr)
end

--- @param bufnr integer
--- @return table<string, string> fold_text_prefixes
local function get_fold_text_prefixes(bufnr)
    local fold_text_prefixes = vim.b[bufnr][FOLD_TEXT_PREFIXES_VAR]
    if type(fold_text_prefixes) ~= "table" then
        fold_text_prefixes = {}
        vim.b[bufnr][FOLD_TEXT_PREFIXES_VAR] = fold_text_prefixes
    end

    return fold_text_prefixes
end

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
        _reopen_restore_tool_call_ids = {},
    }

    setmetatable(instance, self)
    vim.b[bufnr][FOLD_TEXT_PREFIXES_VAR] = {}
    return instance
end

--- @return string fold_text
function ChatFolds.foldtext()
    local bufnr = vim.api.nvim_get_current_buf()
    local line_count = vim.v.foldend - vim.v.foldstart + 1
    local prefix = get_fold_text_prefixes(bufnr)[line_key(vim.v.foldstart)]
        or ""
    return string.format("%sresponse hidden (%d lines)", prefix, line_count)
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
            fold_text_prefix = tracker.fold_text_prefix or "",
        }

        self._tool_call_folds[tracker.tool_call_id] = new_tool_call_fold
        tool_call_fold = new_tool_call_fold
    else
        tool_call_fold.extmark_id = tracker.extmark_id
        tool_call_fold.kind = tracker.kind
        tool_call_fold.status = tracker.status
        tool_call_fold.fold_text_prefix = tracker.fold_text_prefix or ""
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
            local fold_state = self:_get_fold_state(winid, body_start_row + 1)
            fold_states[tool_call_id] = fold_state

            if fold_state ~= nil then
                tool_call_fold.last_known_fold_state = fold_state
            end
        end
    end

    return fold_states
end

--- @param winid integer
--- @param line_nr integer
--- @param is_closed boolean
function ChatFolds:_set_fold_state(winid, line_nr, is_closed)
    vim.api.nvim_win_call(winid, function()
        if is_closed then
            vim.cmd(string.format("silent keepjumps %dfoldclose", line_nr))
        else
            vim.cmd(string.format("silent keepjumps %dfoldopen", line_nr))
        end
    end)
end

--- @param line_nr integer
--- @param prefix string
function ChatFolds:_set_fold_text_prefix(line_nr, prefix)
    local fold_text_prefixes = get_fold_text_prefixes(self.bufnr)
    fold_text_prefixes[line_key(line_nr)] = prefix
    vim.b[self.bufnr][FOLD_TEXT_PREFIXES_VAR] = fold_text_prefixes
end

--- @param line_nr integer
function ChatFolds:_clear_fold_text_prefix(line_nr)
    local fold_text_prefixes = get_fold_text_prefixes(self.bufnr)
    fold_text_prefixes[line_key(line_nr)] = nil
    vim.b[self.bufnr][FOLD_TEXT_PREFIXES_VAR] = fold_text_prefixes
end

--- @param tool_call_fold agentic.ui.ChatFolds.ToolCallFold
function ChatFolds:_clear_tool_call_fold_text_prefix(tool_call_fold)
    local body_start_row =
        select(1, self:_resolve_body_range(tool_call_fold.extmark_id))
    if body_start_row then
        self:_clear_fold_text_prefix(body_start_row + 1)
    end
end

function ChatFolds:remember_visible_window_states()
    for _, winid in ipairs(self:_get_visible_windows()) do
        self:_capture_window_fold_states(winid)
    end
end

--- @param tool_call_id string
function ChatFolds:capture_visible_tool_call_state(tool_call_id)
    local tool_call_fold = self._tool_call_folds[tool_call_id]
    if not tool_call_fold then
        return
    end

    --- @type table<integer, table<string, boolean|nil>>
    local captured_window_states = {}

    for _, winid in ipairs(self:_get_visible_windows()) do
        local body_start_row, _, body_line_count =
            self:_resolve_body_range(tool_call_fold.extmark_id)

        if body_start_row and body_line_count and body_line_count > 0 then
            local fold_state = self:_get_fold_state(winid, body_start_row + 1)
            captured_window_states[winid] = {
                [tool_call_id] = fold_state,
            }

            if fold_state ~= nil then
                tool_call_fold.last_known_fold_state = fold_state
            end
        end
    end

    self._captured_window_states = captured_window_states
end

--- @param winid integer
--- @param tool_call_id string
--- @return boolean|nil fold_state
function ChatFolds:_get_captured_fold_state(winid, tool_call_id)
    local fold_states = self._captured_window_states
        and self._captured_window_states[winid]

    if not fold_states then
        return nil
    end

    return fold_states[tool_call_id]
end

--- @param tool_call_id string
function ChatFolds:_clear_captured_fold_state(tool_call_id)
    if not self._captured_window_states then
        return
    end

    for winid, fold_states in pairs(self._captured_window_states) do
        fold_states[tool_call_id] = nil
        if vim.tbl_isempty(fold_states) then
            self._captured_window_states[winid] = nil
        end
    end

    if vim.tbl_isempty(self._captured_window_states) then
        self._captured_window_states = nil
    end
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
    self:_set_fold_text_prefix(start_line, tool_call_fold.fold_text_prefix)
    local should_close = self:_get_fold_state(winid, start_line)
    if should_close == nil then
        should_close =
            self:_get_captured_fold_state(winid, tool_call_fold.tool_call_id)
    end
    if should_close == nil then
        should_close = tool_call_fold.last_known_fold_state
    end
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
end

--- @param tool_call_fold agentic.ui.ChatFolds.ToolCallFold
function ChatFolds:_decide_default_state(tool_call_fold)
    local _, _, body_line_count =
        self:_resolve_body_range(tool_call_fold.extmark_id)
    local meets_threshold = body_line_count ~= nil
        and body_line_count > 0
        and tool_call_fold.policy.enabled
        and body_line_count >= tool_call_fold.policy.min_lines

    tool_call_fold.should_render_fold = false

    if tool_call_fold.status == "failed" then
        tool_call_fold.should_render_fold = meets_threshold
        tool_call_fold.default_closed = false
        return
    end

    if tool_call_fold.status ~= "completed" then
        tool_call_fold.default_closed = nil
        return
    end

    tool_call_fold.should_render_fold = meets_threshold

    if tool_call_fold.last_known_fold_state ~= nil then
        tool_call_fold.default_closed = tool_call_fold.last_known_fold_state
        return
    end

    tool_call_fold.default_closed = meets_threshold
end

--- @param tracker agentic.ui.MessageWriter.ToolCallBlock
function ChatFolds:sync_tool_call(tracker)
    local tool_call_fold = self:_ensure_tool_call_fold(tracker)
    self:_decide_default_state(tool_call_fold)

    if tool_call_fold.should_render_fold ~= true then
        self:_clear_tool_call_fold_text_prefix(tool_call_fold)
        self._pending_tool_call_ids[tracker.tool_call_id] = nil
        self._reopen_restore_tool_call_ids[tracker.tool_call_id] = nil
        return
    end

    local winids = self:_get_visible_windows()
    if #winids == 0 then
        if tool_call_fold.last_known_fold_state ~= nil then
            self._pending_tool_call_ids[tracker.tool_call_id] = nil
            self._reopen_restore_tool_call_ids[tracker.tool_call_id] = true
        else
            self._pending_tool_call_ids[tracker.tool_call_id] = true
            self._reopen_restore_tool_call_ids[tracker.tool_call_id] = nil
        end
        return
    end

    self._pending_tool_call_ids[tracker.tool_call_id] = nil
    self._reopen_restore_tool_call_ids[tracker.tool_call_id] = nil
    for _, winid in ipairs(winids) do
        self:_sync_fold_to_window(winid, tool_call_fold)
    end

    self:_clear_captured_fold_state(tracker.tool_call_id)
end

--- @param winid integer
function ChatFolds:sync_pending(winid)
    for tool_call_id, _ in pairs(self._pending_tool_call_ids) do
        local tool_call_fold = self._tool_call_folds[tool_call_id]
        if tool_call_fold and tool_call_fold.should_render_fold then
            self:_sync_fold_to_window(winid, tool_call_fold)
        end
        self._pending_tool_call_ids[tool_call_id] = nil
    end
end

--- @param winid integer
function ChatFolds:sync_reopen_states(winid)
    for tool_call_id, _ in pairs(self._reopen_restore_tool_call_ids) do
        local tool_call_fold = self._tool_call_folds[tool_call_id]
        if tool_call_fold then
            local body_start_row, _, body_line_count =
                self:_resolve_body_range(tool_call_fold.extmark_id)

            if body_start_row and body_line_count and body_line_count > 0 then
                local existing_fold_state =
                    self:_get_fold_state(winid, body_start_row + 1)

                if existing_fold_state == nil then
                    self:_sync_fold_to_window(winid, tool_call_fold)
                end
            end
        end

        self._reopen_restore_tool_call_ids[tool_call_id] = nil
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
    self:sync_reopen_states(winid)
    self:sync_pending(winid)
end

--- @param winid integer
--- @param tool_call_id string
--- @return boolean|nil fold_state
function ChatFolds:get_fold_state_for_tool_call(winid, tool_call_id)
    local tool_call_fold = self._tool_call_folds[tool_call_id]
    if not tool_call_fold then
        return nil
    end

    local body_start_row =
        select(1, self:_resolve_body_range(tool_call_fold.extmark_id))
    if not body_start_row then
        return nil
    end

    return self:_get_fold_state(winid, body_start_row + 1)
end

--- @return integer pending_count
function ChatFolds:get_pending_count()
    return vim.tbl_count(self._pending_tool_call_ids)
end

function ChatFolds:reset()
    self._tool_call_folds = {}
    self._pending_tool_call_ids = {}
    self._reopen_restore_tool_call_ids = {}
    self._captured_window_states = nil
    vim.b[self.bufnr][FOLD_TEXT_PREFIXES_VAR] = {}
end

return ChatFolds
