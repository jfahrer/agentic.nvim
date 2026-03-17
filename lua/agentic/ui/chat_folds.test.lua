local assert = require("tests.helpers.assert")
local Config = require("agentic.config")
local Theme = require("agentic.theme")
local spy = require("tests.helpers.spy")

describe("agentic.ui.ChatFolds", function()
    --- @type agentic.ui.ChatFolds
    local ChatFolds
    local original_folds

    before_each(function()
        ChatFolds = require("agentic.ui.chat_folds")
        original_folds = Config.folds
    end)

    after_each(function()
        Config.folds = original_folds
    end)

    it("prefers tool kind override over default", function()
        Config.folds = {
            thoughts = { initial_state = "expanded" },
            tool_calls = {
                initial_state = "collapsed",
                by_kind = { edit = "expanded" },
            },
        }

        assert.equal(
            "expanded",
            ChatFolds.get_initial_state("tool_call", "edit")
        )
        assert.equal(
            "collapsed",
            ChatFolds.get_initial_state("tool_call", "read")
        )
        assert.equal("expanded", ChatFolds.get_initial_state("thought", nil))
    end)

    it("uses the tool call default when kind is nil", function()
        Config.folds = {
            thoughts = { initial_state = "expanded" },
            tool_calls = {
                initial_state = "collapsed",
                by_kind = { edit = "expanded" },
            },
        }

        assert.equal("collapsed", ChatFolds.get_initial_state("tool_call", nil))
    end)

    it("stores and returns collapsible blocks per buffer", function()
        local bufnr = vim.api.nvim_create_buf(false, true)

        local ok, err = pcall(function()
            ChatFolds.upsert_block(bufnr, "thought:1", {
                type = "thought",
                start_row = 0,
                end_row = 2,
                summary = "reasoning hidden",
                initial_state = "collapsed",
            })

            local blocks = ChatFolds.get_blocks(bufnr)
            assert.equal(1, #blocks)
            assert.equal("thought", blocks[1].type)
            assert.equal(0, blocks[1].start_row)
            assert.equal(2, blocks[1].end_row)
        end)

        vim.api.nvim_buf_delete(bufnr, { force = true })
        if not ok then
            error(err, 0)
        end
    end)

    it(
        "reuses the sorted block list until the buffer registry changes",
        function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            local sort_spy = spy.on(table, "sort")

            local ok, err = pcall(function()
                ChatFolds.upsert_block(bufnr, "thought:2", {
                    type = "thought",
                    start_row = 4,
                    end_row = 5,
                    summary = "second",
                    initial_state = "collapsed",
                })
                ChatFolds.upsert_block(bufnr, "thought:1", {
                    type = "thought",
                    start_row = 1,
                    end_row = 3,
                    summary = "first",
                    initial_state = "collapsed",
                })

                local blocks = ChatFolds.get_blocks(bufnr)
                ChatFolds.get_blocks(bufnr)

                assert.equal(1, sort_spy.call_count)
                assert.equal("thought:1", blocks[1].id)
                assert.equal("thought:2", blocks[2].id)

                ChatFolds.upsert_block(bufnr, "thought:3", {
                    type = "thought",
                    start_row = 6,
                    end_row = 7,
                    summary = "third",
                    initial_state = "collapsed",
                })

                local refreshed_blocks = ChatFolds.get_blocks(bufnr)
                assert.equal(2, sort_spy.call_count)
                assert.equal(3, #refreshed_blocks)
            end)

            sort_spy:revert()
            vim.api.nvim_buf_delete(bufnr, { force = true })
            if not ok then
                error(err, 0)
            end
        end
    )

    it("builds highlighted foldtext for tool calls", function()
        local chunks = ChatFolds.build_foldtext({
            type = "tool_call",
            kind = "read",
            summary = "lua/agentic/ui/message_writer.lua",
            status = "completed",
            start_row = 1,
            end_row = 4,
        })

        assert.is_table(chunks)
        assert.equal(" ✔ read ", chunks[1][1])
        assert.equal(Theme.HL_GROUPS.STATUS_COMPLETED, chunks[1][2])
        assert.equal("lua/agentic/ui/message_writer.lua", chunks[2][1])
        assert.equal("Comment", chunks[2][2])
        assert.equal("  4 lines ", chunks[3][1])
        assert.equal("Comment", chunks[3][2])
    end)

    it("resolves fold levels from registered blocks", function()
        local bufnr = vim.api.nvim_create_buf(false, true)

        local ok, err = pcall(function()
            ChatFolds.upsert_block(bufnr, "thought:1", {
                type = "thought",
                start_row = 1,
                end_row = 3,
                summary = "reasoning hidden",
                initial_state = "collapsed",
            })

            assert.equal(0, ChatFolds.get_fold_level(bufnr, 0))
            assert.equal(">1", ChatFolds.get_fold_level(bufnr, 1))
            assert.equal(1, ChatFolds.get_fold_level(bufnr, 2))
            assert.equal("<1", ChatFolds.get_fold_level(bufnr, 3))
            assert.equal(0, ChatFolds.get_fold_level(bufnr, 4))
        end)

        vim.api.nvim_buf_delete(bufnr, { force = true })
        if not ok then
            error(err, 0)
        end
    end)

    it(
        "stops scanning once sorted blocks start past the requested row",
        function()
            local get_blocks_stub = spy.stub(ChatFolds, "get_blocks")

            local ok, err = pcall(function()
                local blocks = {
                    setmetatable({}, {
                        __index = {
                            id = "thought:1",
                            type = "thought",
                            start_row = 0,
                            end_row = 0,
                            summary = "first",
                        },
                    }),
                    setmetatable({}, {
                        __index = {
                            id = "thought:2",
                            type = "thought",
                            start_row = 5,
                            end_row = 7,
                            summary = "second",
                        },
                    }),
                    setmetatable({}, {
                        __index = function(_, key)
                            local values = {
                                id = "thought:3",
                                type = "thought",
                                end_row = 12,
                                summary = "third",
                            }

                            if key == "start_row" then
                                error(
                                    "lookup scanned past sorted early-exit point"
                                )
                            end

                            return values[key]
                        end,
                    }),
                }

                get_blocks_stub:returns(blocks)

                assert.equal(0, ChatFolds.get_fold_level(1, 1))
                assert.equal(1, get_blocks_stub.call_count)
            end)

            get_blocks_stub:revert()
            if not ok then
                error(err, 0)
            end
        end
    )

    it("configures fold options for a chat window", function()
        local bufnr = vim.api.nvim_create_buf(false, true)
        local winid = vim.api.nvim_get_current_win()
        local previous_bufnr = vim.api.nvim_win_get_buf(winid)
        local original_foldmethod = vim.wo[winid].foldmethod
        local original_foldexpr = vim.wo[winid].foldexpr
        local original_foldtext = vim.wo[winid].foldtext
        local original_foldenable = vim.wo[winid].foldenable

        local ok, err = pcall(function()
            vim.api.nvim_win_set_buf(winid, bufnr)
            ChatFolds.set_window_options(winid, bufnr)

            assert.equal("expr", vim.wo[winid].foldmethod)
            assert.equal(true, vim.wo[winid].foldenable)
            assert.truthy(
                string.find(vim.wo[winid].foldexpr, "chat_folds", 1, true)
            )
            assert.truthy(
                string.find(vim.wo[winid].foldtext, "chat_folds", 1, true)
            )
        end)

        vim.api.nvim_set_option_value(
            "foldmethod",
            original_foldmethod,
            { win = winid }
        )
        vim.api.nvim_set_option_value(
            "foldexpr",
            original_foldexpr,
            { win = winid }
        )
        vim.api.nvim_set_option_value(
            "foldtext",
            original_foldtext,
            { win = winid }
        )
        vim.api.nvim_set_option_value(
            "foldenable",
            original_foldenable,
            { win = winid }
        )
        vim.api.nvim_win_set_buf(winid, previous_bufnr)

        assert.equal(original_foldmethod, vim.wo[winid].foldmethod)
        assert.equal(original_foldexpr, vim.wo[winid].foldexpr)
        assert.equal(original_foldtext, vim.wo[winid].foldtext)
        assert.equal(original_foldenable, vim.wo[winid].foldenable)

        vim.api.nvim_buf_delete(bufnr, { force = true })
        if not ok then
            error(err, 0)
        end
    end)

    it("keeps fold blocks isolated per buffer", function()
        local first_bufnr = vim.api.nvim_create_buf(false, true)
        local second_bufnr = vim.api.nvim_create_buf(false, true)

        local ok, err = pcall(function()
            ChatFolds.upsert_block(first_bufnr, "thought:1", {
                type = "thought",
                start_row = 0,
                end_row = 1,
                summary = "first buffer",
                initial_state = "collapsed",
            })
            ChatFolds.upsert_block(second_bufnr, "thought:2", {
                type = "thought",
                start_row = 2,
                end_row = 3,
                summary = "second buffer",
                initial_state = "collapsed",
            })

            local first_blocks = ChatFolds.get_blocks(first_bufnr)
            local second_blocks = ChatFolds.get_blocks(second_bufnr)

            assert.equal(1, #first_blocks)
            assert.equal(1, #second_blocks)
            assert.equal("thought:1", first_blocks[1].id)
            assert.equal("thought:2", second_blocks[1].id)
        end)

        vim.api.nvim_buf_delete(first_bufnr, { force = true })
        vim.api.nvim_buf_delete(second_bufnr, { force = true })
        if not ok then
            error(err, 0)
        end
    end)
end)
