--- @diagnostic disable: invisible
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local ACPPayloads = require("agentic.acp.acp_payloads")
local Config = require("agentic.config")
local ExtmarkBlock = require("agentic.utils.extmark_block")

local NS_TOOL_BLOCKS = vim.api.nvim_create_namespace("agentic_tool_blocks")

describe("agentic.ui.ChatFolds", function()
    --- @type agentic.ui.ChatFolds
    local ChatFolds
    --- @type agentic.ui.MessageWriter
    local MessageWriter
    --- @type integer
    local bufnr
    --- @type integer
    local winid
    --- @type agentic.ui.MessageWriter
    local writer
    --- @type agentic.ui.ChatFolds
    local chat_folds
    --- @type agentic.UserConfig.Folding|nil
    local original_folding
    --- @type agentic.UserConfig.AutoScroll|nil
    local original_auto_scroll

    --- @param count integer
    --- @param prefix string|nil
    --- @return string[] body
    local function make_body(count, prefix)
        local body = {}
        local label = prefix or "line"

        for i = 1, count do
            body[i] = string.format("%s %d", label, i)
        end

        return body
    end

    --- @param id string
    --- @param kind agentic.acp.ToolKind
    --- @param status agentic.acp.ToolCallStatus
    --- @param line_count integer
    --- @return agentic.ui.MessageWriter.ToolCallBlock
    local function make_block(id, kind, status, line_count)
        return {
            tool_call_id = id,
            kind = kind,
            argument = kind .. "-arg",
            status = status,
            body = make_body(line_count, id),
        }
    end

    --- @param tool_call_id string
    --- @return integer body_line
    --- @return integer header_line
    --- @return integer body_line_count
    local function get_body_info(tool_call_id)
        local state = chat_folds._tool_call_folds[tool_call_id]
        local pos = vim.api.nvim_buf_get_extmark_by_id(
            bufnr,
            NS_TOOL_BLOCKS,
            state.extmark_id,
            { details = true }
        )
        local body_start_row, _, body_line_count =
            chat_folds:_resolve_body_range(state.extmark_id)

        assert.is_not_nil(pos)
        assert.is_not_nil(pos[1])
        assert.is_not_nil(body_start_row)
        assert.is_not_nil(body_line_count)

        local header_start_row = pos[1]

        --- @cast header_start_row integer
        --- @cast body_start_row integer
        --- @cast body_line_count integer

        return body_start_row + 1, header_start_row + 1, body_line_count
    end

    --- @param line integer
    --- @param close_fold boolean
    local function set_fold_state(line, close_fold)
        vim.api.nvim_win_call(winid, function()
            vim.api.nvim_win_set_cursor(0, { line, 0 })
            if close_fold then
                vim.cmd("silent! normal! zc")
            else
                vim.cmd("silent! normal! zo")
            end
        end)
    end

    before_each(function()
        original_folding = Config.folding
        original_auto_scroll = Config.auto_scroll
        Config.folding = {
            tool_calls = {
                enabled = true,
                closed_by_default = true,
                min_lines = 3,
                kinds = {
                    fetch = {
                        closed_by_default = true,
                        min_lines = 2,
                    },
                    execute = {
                        closed_by_default = true,
                        min_lines = 4,
                    },
                    edit = {
                        closed_by_default = false,
                    },
                },
            },
        }
        Config.auto_scroll = { threshold = 0 }

        ChatFolds = require("agentic.ui.chat_folds")
        MessageWriter = require("agentic.ui.message_writer")

        bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})

        winid = vim.api.nvim_open_win(bufnr, true, {
            relative = "editor",
            width = 80,
            height = 40,
            row = 0,
            col = 0,
        })

        writer = MessageWriter:new(bufnr)
        chat_folds = ChatFolds:new(bufnr)
        writer:set_chat_folds(chat_folds)
        chat_folds:on_buf_win_enter(winid)
    end)

    after_each(function()
        Config.folding = original_folding --- @diagnostic disable-line: assign-type-mismatch
        Config.auto_scroll = original_auto_scroll --- @diagnostic disable-line: assign-type-mismatch

        for _, visible_winid in ipairs(vim.fn.win_findbuf(bufnr)) do
            if vim.api.nvim_win_is_valid(visible_winid) then
                vim.api.nvim_win_close(visible_winid, true)
            end
        end

        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    it("creates a body-only fold with the marker in the fold text", function()
        writer:write_tool_call_block(
            make_block("fetch-1", "fetch", "completed", 3)
        )

        local body_line, header_line, body_line_count = get_body_info("fetch-1")

        assert.equal(3, body_line_count)
        assert.equal(0, vim.fn.foldlevel(header_line))
        assert.equal(body_line, vim.fn.foldclosed(body_line))
        assert.equal(
            ExtmarkBlock.BODY_PREFIX .. "response hidden (3 lines)",
            vim.fn.foldtextresult(body_line)
        )
    end)

    it(
        "applies global enablement and per-kind closed state thresholds",
        function()
            Config.folding = {
                tool_calls = {
                    enabled = true,
                    closed_by_default = true,
                    min_lines = 20,
                    kinds = {
                        fetch = {
                            closed_by_default = true,
                            min_lines = 8,
                        },
                        execute = {
                            closed_by_default = true,
                            min_lines = 12,
                        },
                        edit = {
                            closed_by_default = false,
                        },
                    },
                },
            }

            writer:write_tool_call_block(
                make_block("fetch-8", "fetch", "completed", 8)
            )
            writer:write_tool_call_block(
                make_block("read-19", "read", "completed", 19)
            )
            writer:write_tool_call_block(
                make_block("execute-12", "execute", "completed", 12)
            )
            writer:write_tool_call_block(
                make_block("execute-11", "execute", "completed", 11)
            )
            writer:write_tool_call_block(
                make_block("edit-40", "edit", "completed", 40)
            )

            local fetch_body_line = get_body_info("fetch-8")
            local read_body_line = get_body_info("read-19")
            local execute_body_line = get_body_info("execute-12")
            local execute_open_body_line = get_body_info("execute-11")
            local edit_body_line = get_body_info("edit-40")

            assert.is_true(chat_folds:_get_fold_state(winid, fetch_body_line))
            assert.is_false(chat_folds:_get_fold_state(winid, read_body_line))
            assert.is_true(chat_folds:_get_fold_state(winid, execute_body_line))
            assert.is_false(
                chat_folds:_get_fold_state(winid, execute_open_body_line)
            )
            assert.is_false(chat_folds:_get_fold_state(winid, edit_body_line))

            Config.folding.tool_calls.enabled = false
            writer:write_tool_call_block(
                make_block("fetch-disabled", "fetch", "completed", 20)
            )

            local disabled_body_line = get_body_info("fetch-disabled")
            assert.is_nil(chat_folds:_get_fold_state(winid, disabled_body_line))

            set_fold_state(execute_open_body_line, true)
            set_fold_state(edit_body_line, true)

            assert.is_true(
                chat_folds:_get_fold_state(winid, execute_open_body_line)
            )
            assert.is_true(chat_folds:_get_fold_state(winid, edit_body_line))
            assert.is_nil(chat_folds:_get_fold_state(winid, disabled_body_line))
        end
    )

    it(
        "waits for completion and leaves failed tool calls open but foldable",
        function()
            writer:write_tool_call_block(
                make_block("execute-pending", "execute", "in_progress", 5)
            )
            writer:write_tool_call_block(
                make_block("execute-failed", "execute", "in_progress", 5)
            )

            local pending_body_line = get_body_info("execute-pending")
            local failed_body_line = get_body_info("execute-failed")

            assert.is_nil(chat_folds:_get_fold_state(winid, pending_body_line))
            assert.is_nil(chat_folds:_get_fold_state(winid, failed_body_line))

            writer:update_tool_call_block({
                tool_call_id = "execute-pending",
                status = "completed",
            })
            writer:update_tool_call_block({
                tool_call_id = "execute-failed",
                status = "failed",
            })

            pending_body_line = get_body_info("execute-pending")
            local failed_updated_body_line = get_body_info("execute-failed")

            assert.is_true(chat_folds:_get_fold_state(winid, pending_body_line))
            assert.is_false(
                chat_folds:_get_fold_state(winid, failed_updated_body_line)
            )
        end
    )

    it("keeps user-opened and user-closed folds on later updates", function()
        writer:write_tool_call_block(
            make_block("execute-open", "execute", "completed", 4)
        )
        writer:write_tool_call_block(
            make_block("execute-closed", "execute", "completed", 4)
        )

        local open_body_line = get_body_info("execute-open")
        local closed_body_line = get_body_info("execute-closed")

        set_fold_state(open_body_line, false)
        set_fold_state(closed_body_line, false)
        set_fold_state(closed_body_line, true)

        writer:update_tool_call_block({
            tool_call_id = "execute-open",
            status = "completed",
            body = { "execute-open extra" },
        })
        writer:update_tool_call_block({
            tool_call_id = "execute-closed",
            status = "completed",
            body = { "execute-closed extra" },
        })

        open_body_line = get_body_info("execute-open")
        closed_body_line = get_body_info("execute-closed")

        assert.is_false(chat_folds:_get_fold_state(winid, open_body_line))
        assert.is_true(chat_folds:_get_fold_state(winid, closed_body_line))
    end)

    it("does not move the cursor when applying a fold", function()
        vim.api.nvim_win_set_cursor(winid, { 1, 0 })

        writer:write_tool_call_block(
            make_block("fetch-cursor", "fetch", "completed", 3)
        )

        assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(winid))
    end)

    it(
        "preserves the current window view when applying a visible fold",
        function()
            writer:write_message(
                ACPPayloads.generate_agent_message(
                    table.concat(make_body(25, "intro"), "\n")
                )
            )

            vim.api.nvim_win_set_cursor(winid, { 10, 0 })
            vim.cmd("normal! zt")
            local before_view = vim.fn.winsaveview()

            writer:write_tool_call_block(
                make_block("fetch-view", "fetch", "completed", 20)
            )

            local after_view = vim.fn.winsaveview()
            assert.equal(before_view.lnum, after_view.lnum)
            assert.equal(before_view.topline, after_view.topline)
        end
    )

    it("backfills a fold when a hidden tool call completes", function()
        writer:write_tool_call_block(
            make_block("fetch-hidden-grow", "fetch", "in_progress", 1)
        )

        local initial_body_line = get_body_info("fetch-hidden-grow")
        assert.is_nil(chat_folds:_get_fold_state(winid, initial_body_line))

        vim.api.nvim_win_close(winid, true)

        writer:update_tool_call_block({
            tool_call_id = "fetch-hidden-grow",
            status = "completed",
            body = { "line 2" },
        })

        assert.is_true(chat_folds._pending_tool_call_ids["fetch-hidden-grow"])

        winid = vim.api.nvim_open_win(bufnr, true, {
            relative = "editor",
            width = 80,
            height = 40,
            row = 0,
            col = 0,
        })

        local before_view = vim.fn.winsaveview()

        chat_folds:on_buf_win_enter(winid)

        local after_view = vim.fn.winsaveview()

        local updated_body_line = get_body_info("fetch-hidden-grow")
        assert.is_true(chat_folds:_get_fold_state(winid, updated_body_line))
        assert.equal(before_view.lnum, after_view.lnum)
        assert.equal(before_view.topline, after_view.topline)
    end)

    it("preserves a user-opened fold across hidden updates", function()
        writer:write_tool_call_block(
            make_block("fetch-user-open", "fetch", "completed", 3)
        )

        local body_line = get_body_info("fetch-user-open")
        set_fold_state(body_line, false)
        chat_folds:remember_visible_window_states()

        vim.api.nvim_win_close(winid, true)

        writer:update_tool_call_block({
            tool_call_id = "fetch-user-open",
            status = "completed",
            body = { "line 4", "line 5" },
        })

        winid = vim.api.nvim_open_win(bufnr, true, {
            relative = "editor",
            width = 80,
            height = 40,
            row = 0,
            col = 0,
        })

        chat_folds:on_buf_win_enter(winid)

        body_line = get_body_info("fetch-user-open")
        assert.is_false(chat_folds:_get_fold_state(winid, body_line))
    end)

    it("recreates previously closed folds when reopening the window", function()
        writer:write_tool_call_block(
            make_block("fetch-closed-reopen", "fetch", "completed", 3)
        )

        local body_line = get_body_info("fetch-closed-reopen")
        assert.is_true(chat_folds:_get_fold_state(winid, body_line))

        chat_folds:remember_visible_window_states()
        vim.api.nvim_win_close(winid, true)

        winid = vim.api.nvim_open_win(bufnr, true, {
            relative = "editor",
            width = 80,
            height = 40,
            row = 0,
            col = 0,
        })

        chat_folds:on_buf_win_enter(winid)

        body_line = get_body_info("fetch-closed-reopen")
        assert.is_true(chat_folds:_get_fold_state(winid, body_line))
    end)

    it(
        "preserves restored fold state when reopening the chat window",
        function()
            writer:write_tool_call_block(
                make_block("fetch-reopen", "fetch", "completed", 3)
            )

            local body_line = get_body_info("fetch-reopen")
            set_fold_state(body_line, false)
            assert.is_false(chat_folds:_get_fold_state(winid, body_line))

            vim.api.nvim_win_close(winid, true)

            winid = vim.api.nvim_open_win(bufnr, true, {
                relative = "editor",
                width = 80,
                height = 40,
                row = 0,
                col = 0,
            })

            chat_folds:on_buf_win_enter(winid)

            assert.is_false(chat_folds:_get_fold_state(winid, body_line))
        end
    )

    it(
        "backfills only pending folds when the chat buffer becomes visible again",
        function()
            writer:write_tool_call_block(
                make_block("fetch-live", "fetch", "completed", 3)
            )
            local live_body_line = get_body_info("fetch-live")
            set_fold_state(live_body_line, false)

            vim.api.nvim_win_close(winid, true)

            writer:write_tool_call_block(
                make_block("fetch-pending", "fetch", "completed", 3)
            )

            assert.is_true(chat_folds._pending_tool_call_ids["fetch-pending"])
            assert.is_nil(chat_folds._pending_tool_call_ids["fetch-live"])

            winid = vim.api.nvim_open_win(bufnr, true, {
                relative = "editor",
                width = 80,
                height = 40,
                row = 0,
                col = 0,
            })

            local sync_spy = spy.on(chat_folds, "_sync_fold_to_window")
            chat_folds:on_buf_win_enter(winid)

            assert.equal(1, sync_spy.call_count)
            assert.equal("fetch-pending", sync_spy.calls[1][3].tool_call_id)

            local pending_body_line = get_body_info("fetch-pending")
            assert.is_false(chat_folds:_get_fold_state(winid, live_body_line))
            assert.is_true(chat_folds:_get_fold_state(winid, pending_body_line))
            assert.is_nil(chat_folds._pending_tool_call_ids["fetch-pending"])

            sync_spy:revert()
        end
    )
end)
