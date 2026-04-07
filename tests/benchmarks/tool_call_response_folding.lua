local ChatFolds = require("agentic.ui.chat_folds")
local Config = require("agentic.config")
local MessageWriter = require("agentic.ui.message_writer")
local Theme = require("agentic.theme")

local M = {}

local uv = vim.uv or vim.loop

local EXECUTE_MIN_LINES = 12
local FETCH_MIN_LINES = 8

--- @param count integer
--- @param prefix string|nil
--- @return string[] lines
local function make_lines(count, prefix)
    local lines = {}

    for i = 1, count do
        lines[i] = string.format("%s %d", prefix or "line", i)
    end

    return lines
end

--- @param tool_call_id string
--- @param kind agentic.acp.ToolKind
--- @param status agentic.acp.ToolCallStatus
--- @param body_line_count integer
--- @return agentic.ui.MessageWriter.ToolCallBlock block
local function make_block(tool_call_id, kind, status, body_line_count)
    --- @type agentic.ui.MessageWriter.ToolCallBlock
    local block = {
        tool_call_id = tool_call_id,
        status = status,
        kind = kind,
        argument = "printf benchmark",
        body = make_lines(body_line_count, tool_call_id),
    }

    return block
end

--- @param count integer
--- @return string[] ids
local function make_ids(count)
    local ids = {}

    for i = 1, count do
        ids[i] = string.format("tool-%03d", i)
    end

    return ids
end

--- @param start_ns integer
--- @return number elapsed_ms
local function elapsed_ms(start_ns)
    return (uv.hrtime() - start_ns) / 1e6
end

--- @param fn fun(bufnr: integer, winid: integer, writer: agentic.ui.MessageWriter, folds: agentic.ui.ChatFolds): table
--- @return table result
local function with_chat_context(fn)
    local tabpage = vim.api.nvim_get_current_tabpage()
    local previous_winid = vim.api.nvim_get_current_win()
    local bufnr = vim.api.nvim_create_buf(false, true)
    local winid = vim.api.nvim_open_win(bufnr, true, {
        relative = "editor",
        width = 140,
        height = 50,
        row = 0,
        col = 0,
        style = "minimal",
    })

    vim.bo[bufnr].filetype = "AgenticChat"

    local writer = MessageWriter:new(bufnr)
    local folds = ChatFolds:new(bufnr, tabpage)
    writer:set_chat_folds(folds)
    folds:on_buf_win_enter(winid)

    local ok, result = pcall(fn, bufnr, winid, writer, folds)

    if vim.api.nvim_win_is_valid(winid) then
        vim.api.nvim_win_close(winid, true)
    end

    if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end

    if vim.api.nvim_tabpage_is_valid(tabpage) then
        if previous_winid and vim.api.nvim_win_is_valid(previous_winid) then
            vim.api.nvim_set_current_win(previous_winid)
        elseif #vim.api.nvim_tabpage_list_wins(tabpage) > 0 then
            vim.api.nvim_set_current_win(
                vim.api.nvim_tabpage_list_wins(tabpage)[1]
            )
        end
    end

    if not ok then
        error(result)
    end

    return result
end

--- @param writer agentic.ui.MessageWriter
--- @param tool_call_id string
--- @return agentic.ui.MessageWriter.ToolCallBlock tracker
local function get_tracker(writer, tool_call_id)
    local tracker = writer.tool_call_blocks[tool_call_id]
    if not tracker then
        error("Missing tool call tracker: " .. tool_call_id)
    end

    return tracker
end

--- @param bufnr integer
--- @param folds agentic.ui.ChatFolds
--- @return table result
local function measure_reopen_backfill(bufnr, folds)
    local reopened_winid = vim.api.nvim_open_win(bufnr, true, {
        relative = "editor",
        width = 140,
        height = 50,
        row = 0,
        col = 0,
        style = "minimal",
    })

    local start_ns = uv.hrtime()
    folds:on_buf_win_enter(reopened_winid)
    local duration_ms = elapsed_ms(start_ns)

    --- @type table
    local result = {
        duration_ms = duration_ms,
        winid = reopened_winid,
    }

    return result
end

--- @param name string
--- @param result table
local function print_result(name, result)
    local extra = result.extra and (" - " .. result.extra) or ""
    print(string.format("%s: %.3f ms%s", name, result.duration_ms, extra))
end

--- @return table result
local function benchmark_hot_path_sync()
    return with_chat_context(function(bufnr, _winid, writer, folds)
        local iterations = 200

        for i = 1, 220 do
            writer:write_tool_call_block(
                make_block(
                    string.format("noise-%03d", i),
                    "execute",
                    "completed",
                    2
                )
            )
        end

        writer:write_tool_call_block(
            make_block("target-hot", "execute", "in_progress", 11)
        )
        writer:update_tool_call_block(
            make_block("target-hot", "execute", "completed", 12)
        )

        local tracker = get_tracker(writer, "target-hot")
        local start_ns = uv.hrtime()

        for _ = 1, iterations do
            folds:sync_tool_call(tracker)
        end

        local duration_ms = elapsed_ms(start_ns)

        --- @type table
        local result = {
            duration_ms = duration_ms,
            extra = string.format(
                "avg %.4f ms/op, %d transcript lines",
                duration_ms / iterations,
                vim.api.nvim_buf_line_count(bufnr)
            ),
        }

        return result
    end)
end

--- @return table result
local function benchmark_hidden_backfill()
    return with_chat_context(function(_bufnr, _winid, writer, folds)
        local pending_count = 6

        for i = 1, 60 do
            writer:write_tool_call_block(
                make_block(
                    string.format("visible-%03d", i),
                    "execute",
                    "completed",
                    2
                )
            )
        end

        local hidden_ids = make_ids(pending_count)

        for _, tool_call_id in ipairs(hidden_ids) do
            writer:write_tool_call_block(
                make_block(tool_call_id, "execute", "in_progress", 11)
            )
        end

        local hidden_winid = vim.fn.bufwinid(writer.bufnr)
        if hidden_winid ~= -1 then
            vim.api.nvim_win_close(hidden_winid, true)
        end

        for _, tool_call_id in ipairs(hidden_ids) do
            writer:update_tool_call_block(
                make_block(tool_call_id, "execute", "completed", 12)
            )
        end

        local measured = measure_reopen_backfill(writer.bufnr, folds)
        local duration_ms = measured.duration_ms
        local remaining_pending = folds:get_pending_count()

        vim.api.nvim_win_close(measured.winid, true)

        --- @type table
        local result = {
            duration_ms = duration_ms,
            extra = string.format(
                "%d pending -> %d remaining",
                pending_count,
                remaining_pending
            ),
        }

        return result
    end)
end

--- @return table result
local function benchmark_reopen_restored()
    return with_chat_context(function(bufnr, winid, writer, folds)
        for i = 1, 40 do
            local tool_call_id = string.format("restored-%03d", i)
            writer:write_tool_call_block(
                make_block(tool_call_id, "execute", "completed", 12)
            )
        end

        vim.api.nvim_win_close(winid, true)

        local measured = measure_reopen_backfill(bufnr, folds)
        local duration_ms = measured.duration_ms

        vim.api.nvim_win_close(measured.winid, true)

        local folds_any = folds --[[@as any]]

        --- @type table
        local result = {
            duration_ms = duration_ms,
            extra = string.format(
                "%d existing folds, %d pending",
                vim.tbl_count(folds_any._tool_call_folds),
                folds:get_pending_count()
            ),
        }

        return result
    end)
end

--- @return table result
local function benchmark_initial_visible_creation()
    return with_chat_context(function(bufnr, _winid, writer, _folds)
        local count = 120
        local tool_call_ids = make_ids(count)
        local start_ns = uv.hrtime()

        for _, tool_call_id in ipairs(tool_call_ids) do
            writer:write_tool_call_block(
                make_block(tool_call_id, "execute", "completed", 12)
            )
        end

        local duration_ms = elapsed_ms(start_ns)

        --- @type table
        local result = {
            duration_ms = duration_ms,
            extra = string.format(
                "avg %.4f ms/op, %d transcript lines",
                duration_ms / count,
                vim.api.nvim_buf_line_count(bufnr)
            ),
        }

        return result
    end)
end

local function configure_benchmark_defaults()
    --- @type agentic.UserConfig.Folding
    local folding = {
        tool_calls = {
            enabled = true,
            closed_by_default = true,
            min_lines = 20,
            kinds = {
                fetch = {
                    closed_by_default = true,
                    min_lines = FETCH_MIN_LINES,
                },
                execute = {
                    closed_by_default = true,
                    min_lines = EXECUTE_MIN_LINES,
                },
                edit = {
                    closed_by_default = false,
                },
            },
        },
    }
    Config.folding = folding
end

function M.run()
    Theme.setup()
    configure_benchmark_defaults()

    vim.cmd("enew")

    local results = {
        hot_path_sync = benchmark_hot_path_sync(),
        hidden_backfill = benchmark_hidden_backfill(),
        reopen_restored = benchmark_reopen_restored(),
        initial_visible_creation = benchmark_initial_visible_creation(),
    }

    print_result("hot-path-sync-one-updated-call", results.hot_path_sync)
    print_result("hidden-bufwinenter-backfill", results.hidden_backfill)
    print_result("reopen-with-restored-folds", results.reopen_restored)
    print_result(
        "initial-visible-many-completed",
        results.initial_visible_creation
    )
end

return M
