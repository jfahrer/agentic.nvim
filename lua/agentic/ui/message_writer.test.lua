--- @diagnostic disable: invisible
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local Config = require("agentic.config")

describe("agentic.ui.MessageWriter", function()
    --- @type agentic.ui.MessageWriter
    local MessageWriter
    --- @type number
    local bufnr
    --- @type number
    local winid
    --- @type agentic.ui.MessageWriter
    local writer

    --- @type agentic.UserConfig.AutoScroll|nil
    local original_auto_scroll

    before_each(function()
        original_auto_scroll = Config.auto_scroll
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
    end)

    after_each(function()
        Config.auto_scroll = original_auto_scroll --- @diagnostic disable-line: assign-type-mismatch
        if winid and vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_win_close(winid, true)
        end
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    --- @param line_count integer
    --- @param cursor_line integer
    local function setup_buffer(line_count, cursor_line)
        local lines = {}
        for i = 1, line_count do
            lines[i] = "line " .. i
        end
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.api.nvim_win_set_cursor(winid, { cursor_line, 0 })
    end

    --- @param text string
    --- @return agentic.acp.SessionUpdateMessage
    local function make_message_update(text)
        return {
            sessionUpdate = "agent_message_chunk",
            content = { type = "text", text = text },
        }
    end

    --- @param id string
    --- @param status agentic.acp.ToolCallStatus
    --- @param body? string[]
    --- @return agentic.ui.MessageWriter.ToolCallBlock
    local function make_tool_call_block(id, status, body)
        return {
            tool_call_id = id,
            status = status,
            kind = "execute",
            argument = "ls",
            body = body or { "output" },
        }
    end

    describe("_check_auto_scroll", function()
        it(
            "returns true when cursor is within threshold of buffer end",
            function()
                setup_buffer(20, 15)
                assert.is_true(writer:_check_auto_scroll(bufnr))
            end
        )

        it("returns false when cursor is far from buffer end", function()
            setup_buffer(50, 1)
            assert.is_false(writer:_check_auto_scroll(bufnr))
        end)

        it("returns false when threshold is disabled (zero or nil)", function()
            setup_buffer(1, 1)

            Config.auto_scroll = { threshold = 0 }
            assert.is_false(writer:_check_auto_scroll(bufnr))

            Config.auto_scroll = nil
            assert.is_false(writer:_check_auto_scroll(bufnr))
        end)

        it("returns true when window is not visible", function()
            local hidden_buf = vim.api.nvim_create_buf(false, true)
            local hidden_writer = MessageWriter:new(hidden_buf)
            assert.is_true(hidden_writer:_check_auto_scroll(hidden_buf))
            vim.api.nvim_buf_delete(hidden_buf, { force = true })
        end)

        it("uses win_findbuf to check cursor across tabpages", function()
            setup_buffer(50, 1)

            vim.cmd("tabnew")
            local tab2 = vim.api.nvim_get_current_tabpage()

            assert.is_false(writer:_check_auto_scroll(bufnr))

            vim.api.nvim_set_current_tabpage(tab2)
            vim.cmd("tabclose")
        end)
    end)

    describe("_auto_scroll", function()
        it("evaluates _check_auto_scroll eagerly on first call", function()
            local check_scroll_spy = spy.on(writer, "_check_auto_scroll")
            writer:_auto_scroll(bufnr)

            assert.equal(1, check_scroll_spy.call_count)
            check_scroll_spy:revert()
        end)

        it("coalesces multiple calls into a single scheduled scroll", function()
            setup_buffer(20, 20)

            writer:_auto_scroll(bufnr)
            assert.is_true(writer._scroll_scheduled)

            local check_spy = spy.on(writer, "_check_auto_scroll")
            writer:_auto_scroll(bufnr)
            writer:_auto_scroll(bufnr)

            assert.equal(0, check_spy.call_count)
            check_spy:revert()
        end)
    end)

    describe("_should_auto_scroll sticky field", function()
        it(
            "remains true after buffer growth despite cursor exceeding threshold",
            function()
                setup_buffer(20, 20)
                writer:_auto_scroll(bufnr)
                assert.is_true(writer._should_auto_scroll)

                local lines = {}
                for i = 1, 30 do
                    lines[i] = "tool output " .. i
                end
                vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, lines)

                local check_spy = spy.on(writer, "_check_auto_scroll")
                writer:_auto_scroll(bufnr)
                assert.is_true(writer._should_auto_scroll)
                assert.equal(0, check_spy.call_count)
                check_spy:revert()
            end
        )

        it(
            "scheduled callback resets field and moves cursor to last line",
            function()
                local schedule_stub = spy.stub(vim, "schedule")
                schedule_stub:invokes(function(fn)
                    fn()
                end)

                setup_buffer(50, 1)
                writer._should_auto_scroll = true
                writer:_auto_scroll(bufnr)

                assert.is_nil(writer._should_auto_scroll)
                assert.equal(50, vim.api.nvim_win_get_cursor(winid)[1])

                schedule_stub:revert()
            end
        )

        it(
            "scheduled callback scrolls when user is on a different tabpage",
            function()
                local schedule_stub = spy.stub(vim, "schedule")
                schedule_stub:invokes(function(fn)
                    fn()
                end)

                setup_buffer(20, 20)

                local new_lines = {}
                for i = 1, 30 do
                    new_lines[i] = "streamed line " .. i
                end
                vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, new_lines)

                vim.cmd("tabnew")
                local tab2 = vim.api.nvim_get_current_tabpage()

                writer._should_auto_scroll = true
                writer:_auto_scroll(bufnr)

                assert.equal(50, vim.api.nvim_win_get_cursor(winid)[1])

                vim.api.nvim_set_current_tabpage(tab2)
                vim.cmd("tabclose")

                schedule_stub:revert()
            end
        )

        it(
            "after reset, re-evaluates and returns false when user scrolled up",
            function()
                local schedule_stub = spy.stub(vim, "schedule")
                schedule_stub:invokes(function(fn)
                    fn()
                end)

                setup_buffer(50, 50)
                writer:_auto_scroll(bufnr)
                assert.is_nil(writer._should_auto_scroll)
                assert.is_false(writer._scroll_scheduled)

                schedule_stub:revert()

                schedule_stub = spy.stub(vim, "schedule")

                vim.api.nvim_win_set_cursor(winid, { 1, 0 })

                writer:_auto_scroll(bufnr)
                assert.is_false(writer._should_auto_scroll)

                schedule_stub:revert()
            end
        )
    end)

    describe("auto-scroll with public write methods", function()
        --- @type TestStub
        local schedule_stub

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
        end)

        after_each(function()
            schedule_stub:revert()
        end)

        it(
            "write_message captures scroll decision before buffer grows",
            function()
                setup_buffer(10, 10)

                local long_text = {}
                for i = 1, 50 do
                    long_text[i] = "message line " .. i
                end

                writer:write_message(
                    make_message_update(table.concat(long_text, "\n"))
                )

                assert.is_true(writer._should_auto_scroll)
            end
        )

        it(
            "write_tool_call_block captures scroll decision before buffer grows",
            function()
                setup_buffer(10, 10)

                local body = {}
                for i = 1, 15 do
                    body[i] = "file" .. i .. ".lua"
                end

                --- @type agentic.ui.MessageWriter.ToolCallBlock
                local block = {
                    tool_call_id = "test-1",
                    status = "pending",
                    kind = "execute",
                    argument = "ls -la",
                    body = body,
                }
                writer:write_tool_call_block(block)

                assert.is_true(writer._should_auto_scroll)
                assert.is_true(vim.api.nvim_buf_line_count(bufnr) > 20)
            end
        )

        it("write_message does not scroll when user has scrolled up", function()
            setup_buffer(50, 1)

            writer:write_message(
                make_message_update("new content\nmore content")
            )

            assert.is_false(writer._should_auto_scroll)
        end)
    end)

    describe("on_content_changed callback", function()
        --- @type TestStub
        local schedule_stub

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
        end)

        after_each(function()
            schedule_stub:revert()
        end)

        it("stores and fires callback via set_on_content_changed", function()
            local callback_spy = spy.new(function() end)
            writer:set_on_content_changed(callback_spy --[[@as function]])

            writer:_notify_content_changed()

            assert.spy(callback_spy).was.called(1)
        end)

        it("clears callback when set to nil", function()
            local callback_spy = spy.new(function() end)
            writer:set_on_content_changed(callback_spy --[[@as function]])
            writer:set_on_content_changed(nil)

            writer:_notify_content_changed()

            assert.spy(callback_spy).was.called(0)
        end)

        it(
            "fires callback for each write method that produces content",
            function()
                local block = make_tool_call_block("cb-setup", "pending")
                writer:write_tool_call_block(block)

                local callback_spy = spy.new(function() end)
                writer:set_on_content_changed(callback_spy --[[@as function]])

                writer:write_message(make_message_update("hello"))
                writer:write_message_chunk(make_message_update("chunk"))
                writer:write_tool_call_block(
                    make_tool_call_block("cb-1", "pending")
                )
                writer:update_tool_call_block({
                    tool_call_id = "cb-setup",
                    status = "completed",
                    body = { "done" },
                })

                assert.spy(callback_spy).was.called(4)
            end
        )

        it("does not fire callback when content is empty", function()
            local callback_spy = spy.new(function() end)
            writer:set_on_content_changed(callback_spy --[[@as function]])

            writer:write_message(make_message_update(""))
            writer:write_message_chunk(make_message_update(""))

            assert.spy(callback_spy).was.called(0)
        end)
    end)

    describe("thought chunks", function()
        it(
            "tracks a streamed thought block as one collapsible region",
            function()
                writer:write_message_chunk({
                    sessionUpdate = "agent_thought_chunk",
                    content = { type = "text", text = "first line" },
                })

                local first_block = writer._thought_block
                assert.is_not_nil(first_block)
                --- @cast first_block agentic.ui.ChatFoldBlock
                assert.equal(0, first_block.start_row)
                assert.equal(0, first_block.end_row)

                writer:write_message_chunk({
                    sessionUpdate = "agent_thought_chunk",
                    content = { type = "text", text = "\nsecond line" },
                })

                assert.is_not_nil(writer._thought_block)
                local second_block = writer._thought_block
                --- @cast second_block agentic.ui.ChatFoldBlock
                assert.equal(first_block.id, second_block.id)
                assert.equal(first_block.start_row, second_block.start_row)
                assert.equal(1, second_block.end_row)
                assert.equal("agent_thought_chunk", writer._last_message_type)
            end
        )

        it(
            "adds thought highlight extmarks for streamed thought lines",
            function()
                writer:write_message_chunk({
                    sessionUpdate = "agent_thought_chunk",
                    content = { type = "text", text = "first line" },
                })

                writer:write_message_chunk({
                    sessionUpdate = "agent_thought_chunk",
                    content = { type = "text", text = "\nsecond line" },
                })

                local ns_id =
                    vim.api.nvim_get_namespaces().agentic_thought_highlights
                local extmarks = vim.api.nvim_buf_get_extmarks(
                    bufnr,
                    ns_id,
                    { 0, 0 },
                    { 1, 0 },
                    { details = true }
                )

                assert.equal(2, #extmarks)
                assert.equal(0, extmarks[1][2])
                assert.equal(1, extmarks[2][2])
                assert.equal("AgenticThought", extmarks[1][4].hl_group)
                assert.equal("AgenticThought", extmarks[2][4].hl_group)
            end
        )

        it(
            "finalizes the active thought block when a full agent message is written",
            function()
                writer:write_message_chunk({
                    sessionUpdate = "agent_thought_chunk",
                    content = {
                        type = "text",
                        text = "first line\nsecond line",
                    },
                })

                local active_block = writer._thought_block
                assert.is_not_nil(active_block)
                --- @cast active_block agentic.ui.ChatFoldBlock

                writer:write_message({
                    sessionUpdate = "agent_message_chunk",
                    content = { type = "text", text = "final message" },
                })

                assert.is_nil(writer._thought_block)

                local ChatFolds = require("agentic.ui.chat_folds")
                local blocks = ChatFolds.get_blocks(bufnr)

                assert.equal(1, #blocks)
                local block = blocks[1]
                assert.equal(active_block.id, block.id)
                assert.equal(0, block.start_row)
                assert.equal(1, block.end_row)
            end
        )

        it(
            "adds the same blank-line separation before write_message after a thought",
            function()
                writer:write_message_chunk({
                    sessionUpdate = "agent_thought_chunk",
                    content = {
                        type = "text",
                        text = "first line\nsecond line",
                    },
                })

                writer:write_message({
                    sessionUpdate = "agent_message_chunk",
                    content = { type = "text", text = "final message" },
                })

                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

                assert.equal("first line", lines[1])
                assert.equal("second line", lines[2])
                assert.equal("", lines[3])
                assert.equal("final message", lines[4])
                assert.equal("", lines[5])
                assert.equal("", lines[6])
            end
        )

        it(
            "resets last message type after finalizing through write_message",
            function()
                writer:write_message_chunk({
                    sessionUpdate = "agent_thought_chunk",
                    content = { type = "text", text = "first line" },
                })

                writer:write_message({
                    sessionUpdate = "agent_message_chunk",
                    content = { type = "text", text = "full message" },
                })

                writer:write_message_chunk({
                    sessionUpdate = "agent_message_chunk",
                    content = { type = "text", text = " streamed" },
                })

                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                assert.equal(5, #lines)
                assert.equal("", lines[2])
                assert.equal("full message", lines[3])
                assert.equal("", lines[4])
                assert.equal(" streamed", lines[5])
                assert.equal("agent_message_chunk", writer._last_message_type)
            end
        )

        it(
            "finalizes the active thought block before writing a tool call",
            function()
                writer:write_message_chunk({
                    sessionUpdate = "agent_thought_chunk",
                    content = {
                        type = "text",
                        text = "first line\nsecond line",
                    },
                })

                local active_block = writer._thought_block
                assert.is_not_nil(active_block)
                --- @cast active_block agentic.ui.ChatFoldBlock

                writer:write_tool_call_block({
                    tool_call_id = "thought-transition-tool",
                    status = "pending",
                    kind = "execute",
                    argument = "ls",
                    body = { "output" },
                })

                assert.is_nil(writer._thought_block)

                local ChatFolds = require("agentic.ui.chat_folds")
                local blocks = ChatFolds.get_blocks(bufnr)

                assert.equal(2, #blocks)
                local block = blocks[1]
                assert.equal(active_block.id, block.id)
                assert.equal(0, block.start_row)
                assert.equal(1, block.end_row)
            end
        )

        it(
            "registers an active thought block even without a later transition",
            function()
                writer:write_message_chunk({
                    sessionUpdate = "agent_thought_chunk",
                    content = {
                        type = "text",
                        text = "first line\nsecond line",
                    },
                })

                local active_block = writer._thought_block
                assert.is_not_nil(active_block)
                --- @cast active_block agentic.ui.ChatFoldBlock

                local ChatFolds = require("agentic.ui.chat_folds")
                local blocks = ChatFolds.get_blocks(bufnr)

                assert.equal(1, #blocks)
                local block = blocks[1]
                assert.equal(active_block.id, block.id)
                assert.equal(0, block.start_row)
                assert.equal(1, block.end_row)
            end
        )

        it("keeps thought state isolated per buffer", function()
            local other_bufnr = vim.api.nvim_create_buf(false, true)
            local other_winid = vim.api.nvim_open_win(other_bufnr, true, {
                relative = "editor",
                width = 80,
                height = 40,
                row = 0,
                col = 0,
            })
            local other_writer = MessageWriter:new(other_bufnr)

            local ok, err = pcall(function()
                writer:write_message_chunk({
                    sessionUpdate = "agent_thought_chunk",
                    content = {
                        type = "text",
                        text = "first line\nsecond line",
                    },
                })

                local ns_id =
                    vim.api.nvim_get_namespaces().agentic_thought_highlights
                local ChatFolds = require("agentic.ui.chat_folds")

                local first_extmarks = vim.api.nvim_buf_get_extmarks(
                    bufnr,
                    ns_id,
                    { 0, 0 },
                    { -1, -1 },
                    { details = true }
                )
                local second_extmarks = vim.api.nvim_buf_get_extmarks(
                    other_bufnr,
                    ns_id,
                    { 0, 0 },
                    { -1, -1 },
                    { details = true }
                )

                local first_blocks = ChatFolds.get_blocks(bufnr)
                local second_blocks = ChatFolds.get_blocks(other_bufnr)

                assert.equal(2, #first_extmarks)
                assert.equal(0, #second_extmarks)
                assert.equal(1, #first_blocks)
                assert.equal(0, #second_blocks)

                other_writer:write_message_chunk({
                    sessionUpdate = "agent_thought_chunk",
                    content = { type = "text", text = "other thought" },
                })

                second_extmarks = vim.api.nvim_buf_get_extmarks(
                    other_bufnr,
                    ns_id,
                    { 0, 0 },
                    { -1, -1 },
                    { details = true }
                )
                second_blocks = ChatFolds.get_blocks(other_bufnr)

                assert.equal(1, #second_extmarks)
                assert.equal(1, #second_blocks)
                assert.are_not.equal(first_blocks[1].id, second_blocks[1].id)
            end)

            if vim.api.nvim_win_is_valid(other_winid) then
                vim.api.nvim_win_close(other_winid, true)
            end
            if vim.api.nvim_buf_is_valid(other_bufnr) then
                vim.api.nvim_buf_delete(other_bufnr, { force = true })
            end

            if not ok then
                error(err, 0)
            end
        end)
    end)

    describe("tool call folds", function()
        it(
            "registers tool calls as collapsible blocks with per-kind state",
            function()
                writer:write_tool_call_block({
                    tool_call_id = "tool-1",
                    status = "pending",
                    kind = "read",
                    argument = "lua/agentic/ui/message_writer.lua",
                    body = { "line 1", "line 2" },
                })

                local ChatFolds = require("agentic.ui.chat_folds")
                local blocks = ChatFolds.get_blocks(bufnr)

                assert.equal(1, #blocks)
                assert.equal("tool_call", blocks[1].type)
                assert.equal("read", blocks[1].kind)
                assert.equal("pending", blocks[1].status)
                assert.equal(
                    "lua/agentic/ui/message_writer.lua",
                    blocks[1].summary
                )
                assert.equal(
                    ChatFolds.get_initial_state("tool_call", "read"),
                    blocks[1].initial_state
                )
            end
        )

        it("refreshes stored tool fold status and summary on update", function()
            writer:write_tool_call_block({
                tool_call_id = "tool-1",
                status = "pending",
                kind = "read",
                argument = "lua/agentic/ui/message_writer.lua",
                body = { "line 1" },
            })

            writer:update_tool_call_block({
                tool_call_id = "tool-1",
                status = "completed",
                body = { "line 1", "line 2", "line 3" },
            })

            local ChatFolds = require("agentic.ui.chat_folds")
            local blocks = ChatFolds.get_blocks(bufnr)

            assert.equal(1, #blocks)
            assert.equal("completed", blocks[1].status)
            assert.equal("lua/agentic/ui/message_writer.lua", blocks[1].summary)
        end)

        it(
            "anchors the first tool call in an empty buffer to the rendered header row",
            function()
                writer:write_tool_call_block({
                    tool_call_id = "tool-empty-1",
                    status = "pending",
                    kind = "read",
                    argument = "line1\nline2.lua",
                    body = { "line 1", "line 2" },
                })

                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                local ChatFolds = require("agentic.ui.chat_folds")
                local blocks = ChatFolds.get_blocks(bufnr)

                assert.equal(" read(line1\\nline2.lua) ", lines[1])
                assert.equal("Read 2 lines", lines[2])
                assert.equal("", lines[3])
                assert.equal(1, #blocks)
                assert.equal(0, blocks[1].start_row)
                assert.equal(2, blocks[1].end_row)
                assert.equal("line1\\nline2.lua", blocks[1].summary)
            end
        )

        it(
            "updates the first tool call in an empty buffer without duplicating the header",
            function()
                writer:write_tool_call_block({
                    tool_call_id = "tool-empty-2",
                    status = "pending",
                    kind = "read",
                    argument = "line1\nline2.lua",
                    body = { "line 1" },
                })

                writer:update_tool_call_block({
                    tool_call_id = "tool-empty-2",
                    status = "completed",
                    body = { "line 1", "line 2", "line 3" },
                })

                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                local ChatFolds = require("agentic.ui.chat_folds")
                local blocks = ChatFolds.get_blocks(bufnr)

                assert.equal(" read(line1\\nline2.lua) ", lines[1])
                assert.equal("Read 7 lines", lines[2])
                assert.are_not.equal(" read(line1\\nline2.lua) ", lines[2])
                assert.equal(1, #blocks)
                assert.equal(0, blocks[1].start_row)
                assert.equal(2, blocks[1].end_row)
                assert.equal("completed", blocks[1].status)
                assert.equal("line1\\nline2.lua", blocks[1].summary)
            end
        )

        it(
            "anchors permission buttons directly after a tool call without an extra gap",
            function()
                writer:write_tool_call_block({
                    tool_call_id = "tool-permission-1",
                    status = "pending",
                    kind = "read",
                    argument = "lua/agentic/ui/message_writer.lua",
                    body = { "line 1" },
                })

                local button_start_row, button_end_row, option_mapping =
                    writer:display_permission_buttons("tool-permission-1", {
                        {
                            optionId = "allow-once",
                            name = "Allow once",
                            kind = "allow_once",
                        },
                        {
                            optionId = "reject-once",
                            name = "Reject once",
                            kind = "reject_once",
                        },
                    })

                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                local prompt_row
                local separator_count = 0

                for idx, line in ipairs(lines) do
                    if line == "### Waiting for your response: " then
                        prompt_row = idx
                        break
                    end
                end

                assert.is_not_nil(prompt_row)
                --- @cast prompt_row integer

                for idx = 4, prompt_row - 1 do
                    if lines[idx] == "" then
                        separator_count = separator_count + 1
                    end
                end

                assert.equal(0, separator_count)
                assert.equal(prompt_row - 2, button_start_row)
                assert.is_true(button_end_row >= button_start_row)
                assert.equal("allow-once", option_mapping[1])
                assert.equal("reject-once", option_mapping[2])
            end
        )
    end)

    describe("_prepare_block_lines", function()
        local FileSystem
        local read_stub
        local path_stub

        before_each(function()
            FileSystem = require("agentic.utils.file_system")
            read_stub = spy.stub(FileSystem, "read_from_buffer_or_disk")
            path_stub = spy.stub(FileSystem, "to_absolute_path")
            path_stub:invokes(function(path)
                return path
            end)
        end)

        after_each(function()
            read_stub:revert()
            path_stub:revert()
        end)

        it("creates highlight ranges for pure insertion hunks", function()
            read_stub:returns({ "line1", "line2", "line3" })

            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "test-hl",
                status = "pending",
                kind = "edit",
                argument = "/test.lua",
                diff = {
                    old = { "line1", "line2", "line3" },
                    new = { "line1", "inserted", "line2", "line3" },
                },
            }

            local lines, highlight_ranges = writer:_prepare_block_lines(block)

            local found_inserted = false
            for _, line in ipairs(lines) do
                if line == "inserted" then
                    found_inserted = true
                    break
                end
            end
            assert.is_true(found_inserted)

            local new_ranges = vim.tbl_filter(function(r)
                return r.type == "new"
            end, highlight_ranges)
            assert.is_true(#new_ranges > 0)
            assert.equal("inserted", new_ranges[1].new_line)
        end)
    end)
end)
