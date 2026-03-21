local assert = require("tests.helpers.assert")
local Config = require("agentic.config")
local MessageWriter = require("agentic.ui.message_writer")
local spy = require("tests.helpers.spy")

describe("agentic.ui.chat_folds", function()
    local ChatFolds
    local Logger
    local bufnr
    local winid
    local writer
    local original_folding_config
    local logger_debug_stub

    --- @param count integer
    --- @param prefix string|nil
    --- @return string[]
    local function make_lines(count, prefix)
        local lines = {}

        for i = 1, count do
            table.insert(lines, string.format("%s %d", prefix or "line", i))
        end

        return lines
    end

    --- @param id string
    --- @param status agentic.acp.ToolCallStatus
    --- @param body? string[]
    --- @return agentic.ui.MessageWriter.ToolCallBlock
    local function make_execute_block(id, status, body)
        return {
            tool_call_id = id,
            status = status,
            kind = "execute",
            argument = "ls",
            body = body or { "output" },
        }
    end

    --- @return agentic.ui.MessageWriter.ToolCallBlock
    local function make_edit_block()
        return {
            tool_call_id = "edit-1",
            status = "completed",
            kind = "edit",
            argument = "/tmp/example.lua",
            diff = {
                old = { "local value = 1" },
                new = { "local value = 2", "print(value)" },
            },
        }
    end

    before_each(function()
        package.loaded["agentic.ui.chat_folds"] = nil
        ChatFolds = require("agentic.ui.chat_folds")
        Logger = require("agentic.utils.logger")
        original_folding_config = vim.deepcopy(Config.folding)

        bufnr = vim.api.nvim_create_buf(false, true)
        winid = vim.api.nvim_open_win(bufnr, true, {
            relative = "editor",
            width = 100,
            height = 40,
            row = 0,
            col = 0,
        })
        writer = MessageWriter:new(bufnr)
    end)

    after_each(function()
        if logger_debug_stub then
            logger_debug_stub:revert()
            logger_debug_stub = nil
        end

        Config.folding = original_folding_config

        if winid and vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_win_close(winid, true)
        end
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    describe("live sync", function()
        local function set_execute_threshold(min_lines)
            Config.folding = {
                tool_calls = {
                    enabled = true,
                    min_lines = 99,
                    kinds = {
                        execute = {
                            enabled = true,
                            min_lines = min_lines,
                        },
                    },
                },
            }
        end

        it("does not auto-fold pending or in-progress tool calls", function()
            set_execute_threshold(3)

            writer:write_tool_call_block(
                make_execute_block(
                    "tool-live-pending",
                    "pending",
                    make_lines(4)
                )
            )

            local folds = ChatFolds:new(bufnr, writer)

            assert.is_false(folds:sync_tool_call("tool-live-pending"))
            assert.is_nil(
                vim.b[bufnr].agentic_chat_folds.by_tool_call_id["tool-live-pending"]
            )
            assert.equal(-1, vim.fn.foldclosed(2))

            writer:update_tool_call_block({
                tool_call_id = "tool-live-pending",
                status = "in_progress",
                body = make_lines(5, "progress"),
            })

            assert.is_false(folds:sync_tool_call("tool-live-pending"))
            assert.is_nil(
                vim.b[bufnr].agentic_chat_folds.by_tool_call_id["tool-live-pending"]
            )
            assert.equal(-1, vim.fn.foldclosed(2))
        end)

        it(
            "auto-folds completed tool calls once they reach the threshold",
            function()
                set_execute_threshold(3)

                writer:write_tool_call_block(
                    make_execute_block(
                        "tool-live-completed",
                        "in_progress",
                        make_lines(2)
                    )
                )

                local folds = ChatFolds:new(bufnr, writer)

                assert.is_false(folds:sync_tool_call("tool-live-completed"))
                assert.equal(-1, vim.fn.foldclosed(2))

                writer:update_tool_call_block({
                    tool_call_id = "tool-live-completed",
                    status = "completed",
                    body = make_lines(3, "done"),
                })

                assert.is_true(folds:sync_tool_call("tool-live-completed"))

                local metadata =
                    vim.b[bufnr].agentic_chat_folds.by_tool_call_id["tool-live-completed"]
                assert.is_not_nil(metadata)
                if metadata == nil then
                    return
                end

                assert.equal(9, metadata.body_line_count)
                assert.equal(
                    metadata.fold_start,
                    vim.fn.foldclosed(metadata.fold_start)
                )
                assert.equal(
                    metadata.fold_end,
                    vim.fn.foldclosedend(metadata.fold_start)
                )
            end
        )

        it(
            "preserves a user-opened completed fold when syncing an unchanged range",
            function()
                set_execute_threshold(3)

                writer:write_tool_call_block(
                    make_execute_block(
                        "tool-live-open-preserved",
                        "completed",
                        make_lines(3, "done")
                    )
                )

                local folds = ChatFolds:new(bufnr, writer)
                local create_fold_spy = spy.on(folds, "create_fold")

                assert.is_true(folds:sync_tool_call("tool-live-open-preserved"))
                assert.equal(1, create_fold_spy.call_count)

                vim.api.nvim_win_set_cursor(winid, { 2, 0 })
                vim.cmd("silent keepjumps normal! zo")
                assert.equal(-1, vim.fn.foldclosed(2))

                create_fold_spy:reset()

                assert.is_true(folds:sync_tool_call("tool-live-open-preserved"))
                assert.equal(0, create_fold_spy.call_count)
                assert.equal(-1, vim.fn.foldclosed(2))

                create_fold_spy:revert()
            end
        )

        it(
            "preserves a user-closed completed fold when syncing an unchanged range",
            function()
                set_execute_threshold(3)

                writer:write_tool_call_block(
                    make_execute_block(
                        "tool-live-closed-preserved",
                        "completed",
                        make_lines(3, "done")
                    )
                )

                local folds = ChatFolds:new(bufnr, writer)
                local create_fold_spy = spy.on(folds, "create_fold")

                assert.is_true(
                    folds:sync_tool_call("tool-live-closed-preserved")
                )
                assert.equal(1, create_fold_spy.call_count)

                vim.api.nvim_win_set_cursor(winid, { 2, 0 })
                vim.cmd("silent keepjumps normal! zo")
                vim.cmd("silent keepjumps normal! zc")
                assert.equal(2, vim.fn.foldclosed(2))

                create_fold_spy:reset()

                assert.is_true(
                    folds:sync_tool_call("tool-live-closed-preserved")
                )
                assert.equal(0, create_fold_spy.call_count)
                assert.equal(2, vim.fn.foldclosed(2))

                create_fold_spy:revert()
            end
        )

        it("keeps failed tool calls open", function()
            set_execute_threshold(3)

            writer:write_tool_call_block(
                make_execute_block(
                    "tool-live-failed",
                    "in_progress",
                    make_lines(2)
                )
            )

            local folds = ChatFolds:new(bufnr, writer)

            writer:update_tool_call_block({
                tool_call_id = "tool-live-failed",
                status = "failed",
                body = make_lines(3, "failed"),
            })

            assert.is_false(folds:sync_tool_call("tool-live-failed"))
            assert.is_nil(
                vim.b[bufnr].agentic_chat_folds.by_tool_call_id["tool-live-failed"]
            )
            assert.equal(-1, vim.fn.foldclosed(2))
        end)
    end)

    describe("debug logging", function()
        it("logs when tool call tracking is missing", function()
            logger_debug_stub = spy.stub(Logger, "debug")

            local folds = ChatFolds:new(bufnr, writer)

            assert.is_false(folds:sync_tool_call("tool-missing-tracker"))
            assert.equal(1, logger_debug_stub.call_count)
            assert.equal(
                "[ChatFolds] Unable to resolve fold rows: tool call tracker missing",
                logger_debug_stub.calls[1][1]
            )
            assert.same(
                { tool_call_id = "tool-missing-tracker" },
                logger_debug_stub.calls[1][2]
            )
        end)

        it("logs when the tool call extmark is missing", function()
            logger_debug_stub = spy.stub(Logger, "debug")

            writer:write_tool_call_block(
                make_execute_block("tool-missing-extmark", "completed", {
                    "body one",
                    "body two",
                    "body three",
                })
            )
            writer.tool_call_blocks["tool-missing-extmark"].extmark_id = nil

            local folds = ChatFolds:new(bufnr, writer)

            assert.is_false(folds:sync_tool_call("tool-missing-extmark"))
            assert.equal(1, logger_debug_stub.call_count)
            assert.equal(
                "[ChatFolds] Unable to resolve fold rows: tool call extmark missing",
                logger_debug_stub.calls[1][1]
            )
            assert.same(
                { tool_call_id = "tool-missing-extmark" },
                logger_debug_stub.calls[1][2]
            )
        end)

        it("logs when the tool call body range is empty", function()
            logger_debug_stub = spy.stub(Logger, "debug")

            writer:write_tool_call_block(
                make_execute_block("tool-empty-body", "completed", {})
            )

            local folds = ChatFolds:new(bufnr, writer)

            assert.is_false(folds:sync_tool_call("tool-empty-body"))
            assert.equal(1, logger_debug_stub.call_count)
            assert.equal(
                "[ChatFolds] Unable to resolve fold rows: tool call body range is empty",
                logger_debug_stub.calls[1][1]
            )
            assert.same(
                { tool_call_id = "tool-empty-body" },
                logger_debug_stub.calls[1][2]
            )
        end)
    end)

    it("resolves shipped execute defaults", function()
        local config = require("agentic.config_default")

        local policy = ChatFolds.resolve_policy_for_test("EXECUTE", config)

        assert.is_true(policy.enabled)
        assert.equal(12, policy.min_lines)
    end)

    it("uses default project config when config is nil", function()
        local policy = ChatFolds.resolve_policy_for_test("execute")

        assert.is_true(policy.enabled)
        assert.equal(12, policy.min_lines)
    end)

    it("lets per-kind overrides beat family defaults", function()
        local policy = ChatFolds.resolve_policy_for_test("EDIT", {
            folding = {
                tool_calls = {
                    enabled = true,
                    min_lines = 20,
                    kinds = {
                        edit = {
                            enabled = false,
                        },
                    },
                },
            },
        })

        assert.is_false(policy.enabled)
        assert.equal(20, policy.min_lines)
    end)

    describe("manual folds", function()
        local function get_fold_metadata(tool_call_id)
            return vim.b[bufnr].agentic_chat_folds.by_tool_call_id[tool_call_id]
        end

        it("records completed hidden tool calls in the pending set", function()
            Config.folding = {
                tool_calls = {
                    enabled = true,
                    min_lines = 99,
                    kinds = {
                        execute = {
                            enabled = true,
                            min_lines = 3,
                        },
                    },
                },
            }

            writer:write_tool_call_block(
                make_execute_block("tool-hidden-pending", "completed", {
                    "body one",
                    "body two",
                    "body three",
                })
            )

            local folds = ChatFolds:new(bufnr, writer)

            vim.api.nvim_win_close(winid, true)
            winid = nil

            assert.is_false(folds:sync_tool_call("tool-hidden-pending"))
            assert.is_true(
                folds._pending_tool_call_ids["tool-hidden-pending"] == true
            )
            assert.is_nil(get_fold_metadata("tool-hidden-pending"))
        end)

        it(
            "does not backfill a hidden pending fold after the tool call fails",
            function()
                Config.folding = {
                    tool_calls = {
                        enabled = true,
                        min_lines = 99,
                        kinds = {
                            execute = {
                                enabled = true,
                                min_lines = 3,
                            },
                        },
                    },
                }

                writer:write_tool_call_block(
                    make_execute_block("tool-hidden-failed", "completed", {
                        "body one",
                        "body two",
                        "body three",
                    })
                )

                local folds = ChatFolds:new(bufnr, writer)

                vim.api.nvim_win_close(winid, true)
                winid = nil

                assert.is_false(folds:sync_tool_call("tool-hidden-failed"))
                assert.is_true(
                    folds._pending_tool_call_ids["tool-hidden-failed"] == true
                )

                writer:update_tool_call_block({
                    tool_call_id = "tool-hidden-failed",
                    status = "failed",
                    body = {
                        "body one",
                        "body two",
                        "body three",
                    },
                })

                assert.is_false(folds:sync_tool_call("tool-hidden-failed"))
                assert.is_nil(
                    folds._pending_tool_call_ids["tool-hidden-failed"]
                )

                winid = vim.api.nvim_open_win(bufnr, true, {
                    relative = "editor",
                    width = 100,
                    height = 40,
                    row = 0,
                    col = 0,
                })

                folds:backfill_pending_for_current_window()

                assert.is_nil(get_fold_metadata("tool-hidden-failed"))
                assert.equal(-1, vim.fn.foldclosed(2))
            end
        )

        it("creates a fold over the tool-call body only", function()
            writer:write_tool_call_block(
                make_execute_block("tool-1", "completed", {
                    "line one",
                    "line two",
                    "line three",
                })
            )

            local folds = ChatFolds:new(bufnr, writer)
            folds:create_fold("tool-1")

            local metadata = get_fold_metadata("tool-1")
            assert.is_not_nil(metadata)
            if metadata == nil then
                return
            end

            assert.same({
                fold_start = 2,
                fold_end = 4,
                body_line_count = 3,
            }, metadata)
        end)

        it("keeps the header line visible", function()
            writer:write_tool_call_block(
                make_execute_block("tool-2", "completed", {
                    "body one",
                    "body two",
                })
            )

            local folds = ChatFolds:new(bufnr, writer)
            folds:create_fold("tool-2")

            assert.equal(-1, vim.fn.foldclosed(1))
            assert.equal(2, vim.fn.foldclosed(2))
        end)

        it("keeps the footer status line outside the fold", function()
            writer:write_tool_call_block(
                make_execute_block("tool-3", "completed", {
                    "line one",
                    "line two",
                })
            )

            local folds = ChatFolds:new(bufnr, writer)
            folds:create_fold("tool-3")

            assert.equal(-1, vim.fn.foldclosedend(4))
        end)

        it("returns foldtext from buffer-local metadata", function()
            writer:write_tool_call_block(
                make_execute_block("tool-4", "completed", {
                    "one",
                    "two",
                    "three",
                })
            )

            local folds = ChatFolds:new(bufnr, writer)
            folds:create_fold("tool-4")

            assert.equal("response hidden (3 lines)", vim.fn.foldtextresult(2))
        end)

        it(
            "keeps diff block header visible and footer outside the fold",
            function()
                writer:write_tool_call_block(make_edit_block())

                local folds = ChatFolds:new(bufnr, writer)
                folds:create_fold("edit-1")

                local metadata = get_fold_metadata("edit-1")
                assert.is_not_nil(metadata)
                if metadata == nil then
                    return
                end

                assert.equal(-1, vim.fn.foldclosed(1))
                assert.equal(
                    metadata.fold_start,
                    vim.fn.foldclosed(metadata.fold_start)
                )
                assert.equal(-1, vim.fn.foldclosedend(metadata.fold_end + 1))
            end
        )

        it(
            "keeps foldtext working after module reload using buffer metadata",
            function()
                writer:write_tool_call_block(
                    make_execute_block("tool-5", "completed", {
                        "one",
                        "two",
                    })
                )

                local folds = ChatFolds:new(bufnr, writer)
                folds:create_fold("tool-5")

                package.loaded["agentic.ui.chat_folds"] = nil
                ChatFolds = require("agentic.ui.chat_folds")
                vim.wo[winid].foldtext =
                    "v:lua.require'agentic.ui.chat_folds'.foldtext()"

                assert.equal(
                    "response hidden (2 lines)",
                    vim.fn.foldtextresult(2)
                )
            end
        )

        it(
            "refreshes fold range and foldtext after update and recreate",
            function()
                writer:write_tool_call_block(
                    make_execute_block("tool-6", "pending", {
                        "before one",
                        "before two",
                    })
                )

                local folds = ChatFolds:new(bufnr, writer)
                folds:create_fold("tool-6")

                assert.equal(2, vim.fn.foldclosed(2))
                assert.equal(3, vim.fn.foldclosedend(2))
                assert.equal(
                    "response hidden (2 lines)",
                    vim.fn.foldtextresult(2)
                )

                writer:update_tool_call_block({
                    tool_call_id = "tool-6",
                    status = "completed",
                    body = {
                        "after one",
                        "after two",
                        "after three",
                    },
                })

                folds:create_fold("tool-6")

                local metadata = get_fold_metadata("tool-6")
                assert.is_not_nil(metadata)
                if metadata == nil then
                    return
                end

                assert.same({
                    fold_start = 2,
                    fold_end = 10,
                    body_line_count = 9,
                }, metadata)
                assert.equal(2, vim.fn.foldclosed(2))
                assert.equal(10, vim.fn.foldclosedend(2))
                assert.equal(-1, vim.fn.foldclosed(11))
                assert.equal(
                    "response hidden (9 lines)",
                    vim.fn.foldtextresult(2)
                )
            end
        )

        it("recreates correctly after the original fold was opened", function()
            writer:write_tool_call_block(
                make_execute_block("tool-7", "pending", {
                    "before one",
                    "before two",
                })
            )

            local folds = ChatFolds:new(bufnr, writer)
            folds:create_fold("tool-7")

            vim.api.nvim_win_set_cursor(winid, { 2, 0 })
            vim.cmd("silent keepjumps normal! zo")
            assert.equal(-1, vim.fn.foldclosed(2))

            vim.api.nvim_win_set_cursor(winid, { 1, 0 })

            writer:update_tool_call_block({
                tool_call_id = "tool-7",
                status = "completed",
                body = {
                    "after one",
                    "after two",
                    "after three",
                },
            })

            folds:create_fold("tool-7")

            local metadata = get_fold_metadata("tool-7")
            assert.is_not_nil(metadata)
            if metadata == nil then
                return
            end

            assert.same({
                fold_start = 2,
                fold_end = 10,
                body_line_count = 9,
            }, metadata)
            assert.equal(1, vim.api.nvim_win_get_cursor(winid)[1])
            assert.equal(2, vim.fn.foldclosed(2))
            assert.equal(10, vim.fn.foldclosedend(2))
            assert.equal(-1, vim.fn.foldclosed(11))
            assert.equal("response hidden (9 lines)", vim.fn.foldtextresult(2))
        end)
    end)
end)
