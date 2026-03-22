local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local ChatFolds = require("agentic.ui.chat_folds")
local MessageWriter = require("agentic.ui.message_writer")

describe("SessionRestore", function()
    --- @type agentic.SessionRestore
    local SessionRestore
    local ChatHistory
    local SessionRegistry
    local Logger

    --- @type TestStub
    local chat_history_load_stub
    --- @type TestStub
    local chat_history_list_stub
    --- @type TestStub
    local session_registry_stub
    --- @type TestStub
    local logger_notify_stub
    --- @type TestStub
    local vim_ui_select_stub

    local test_sessions = {
        {
            session_id = "session-1",
            title = "First chat",
            timestamp = 1704067200,
        },
        {
            session_id = "session-2",
            title = "Second chat",
            timestamp = 1704153600,
        },
    }

    local mock_history = {
        session_id = "restored-session",
        messages = { { type = "user", text = "Previous chat" } },
    }

    local function create_mock_session(opts)
        opts = opts or {}
        return {
            session_id = opts.session_id or "current-session",
            chat_history = opts.chat_history or { messages = {} },
            agent = { cancel_session = spy.new(function() end) },
            chat_folds = opts.chat_folds or { reset = spy.new(function() end) },
            _cancel_session = opts._cancel_session or spy.new(function() end),
            widget = {
                clear = spy.new(function() end),
                show = spy.new(function() end),
            },
            restore_from_history = spy.new(function() end),
        }
    end

    local function setup_list_stub(sessions)
        chat_history_list_stub:invokes(function(callback)
            callback(sessions or test_sessions)
        end)
    end

    local function setup_load_stub(history, err)
        chat_history_load_stub:invokes(function(_sid, callback)
            callback(history, err)
        end)
    end

    local function setup_registry_stub(session)
        session_registry_stub:invokes(function(_tab_id, callback)
            callback(session)
        end)
    end

    local function select_session(index)
        local callback = vim_ui_select_stub.calls[index][3]
        local items = vim_ui_select_stub.calls[index][1]
        return callback, items
    end

    before_each(function()
        package.loaded["agentic.session_restore"] = nil
        package.loaded["agentic.ui.chat_history"] = nil
        package.loaded["agentic.session_registry"] = nil
        package.loaded["agentic.utils.logger"] = nil

        SessionRestore = require("agentic.session_restore")
        ChatHistory = require("agentic.ui.chat_history")
        SessionRegistry = require("agentic.session_registry")
        Logger = require("agentic.utils.logger")

        chat_history_load_stub = spy.stub(ChatHistory, "load")
        chat_history_list_stub = spy.stub(ChatHistory, "list_sessions")
        session_registry_stub =
            spy.stub(SessionRegistry, "get_session_for_tab_page")
        logger_notify_stub = spy.stub(Logger, "notify")
        vim_ui_select_stub = spy.stub(vim.ui, "select")
    end)

    after_each(function()
        chat_history_load_stub:revert()
        chat_history_list_stub:revert()
        session_registry_stub:revert()
        logger_notify_stub:revert()
        vim_ui_select_stub:revert()
    end)

    describe("show_picker", function()
        it("notifies and skips picker when no sessions exist", function()
            setup_list_stub({})

            SessionRestore.show_picker(1, nil)

            assert.spy(logger_notify_stub).was.called(1)
            assert.equal(
                "No saved sessions found",
                logger_notify_stub.calls[1][1]
            )
            assert.equal(vim.log.levels.INFO, logger_notify_stub.calls[1][2])
            assert.spy(vim_ui_select_stub).was.called(0)
        end)

        it("displays formatted sessions with date and title", function()
            setup_list_stub()

            SessionRestore.show_picker(1, nil)

            local items = vim_ui_select_stub.calls[1][1]
            local opts = vim_ui_select_stub.calls[1][2]

            assert.equal(2, #items)
            assert.equal("session-1", items[1].session_id)
            assert.truthy(items[1].display:match("First chat"))
            assert.equal("Select session to restore:", opts.prompt)
            assert.equal(items[1].display, opts.format_item(items[1]))
        end)

        it("handles sessions with missing title", function()
            setup_list_stub({ { session_id = "s1" } })

            SessionRestore.show_picker(1, nil)

            local items = vim_ui_select_stub.calls[1][1]
            assert.truthy(items[1].display:match("%(no title%)"))
        end)

        it("does nothing when user cancels picker", function()
            setup_list_stub()

            SessionRestore.show_picker(1, nil)

            local callback = select_session(1)
            callback(nil)

            assert.spy(chat_history_load_stub).was.called(0)
        end)
    end)

    describe("restore without conflict", function()
        it("restores directly with reuse_session=true", function()
            local mock_session = create_mock_session()
            setup_list_stub()
            setup_load_stub(mock_history)
            setup_registry_stub(mock_session)

            SessionRestore.show_picker(1, nil)

            local callback = select_session(1)
            callback({ session_id = "session-1" })

            assert.spy(mock_session.agent.cancel_session).was.called(0)
            assert.spy(mock_session.widget.clear).was.called(0)
            assert.spy(mock_session.restore_from_history).was.called(1)

            local restore_call = mock_session.restore_from_history.calls[1]
            assert.equal(mock_history, restore_call[2])
            assert.is_true(restore_call[3].reuse_session)
            assert.spy(mock_session.widget.show).was.called(1)
        end)
    end)

    describe("restore with conflict", function()
        local function session_with_messages()
            return create_mock_session({
                chat_history = { messages = { { type = "user" } } },
            })
        end

        it("prompts user when current session has messages", function()
            local mock_session = session_with_messages()
            setup_list_stub()

            SessionRestore.show_picker(
                1,
                mock_session --[[@as agentic.SessionManager]]
            )

            local callback = select_session(1)
            callback({ session_id = "session-1" })

            assert.spy(vim_ui_select_stub).was.called(2)

            local conflict_opts = vim_ui_select_stub.calls[2][2]
            assert.truthy(
                conflict_opts.prompt:match("Current session has messages")
            )
        end)

        it("cancels restore when user chooses Cancel", function()
            local mock_session = session_with_messages()
            setup_list_stub()

            SessionRestore.show_picker(
                1,
                mock_session --[[@as agentic.SessionManager]]
            )

            local callback = select_session(1)
            callback({ session_id = "session-1" })

            local conflict_callback = vim_ui_select_stub.calls[2][3]
            conflict_callback("Cancel")

            assert.spy(chat_history_load_stub).was.called(0)
        end)

        it(
            "clears session and restores with reuse_session=false when confirmed",
            function()
                local mock_session = session_with_messages()
                setup_list_stub()
                setup_load_stub(mock_history)
                setup_registry_stub(mock_session)

                SessionRestore.show_picker(
                    1,
                    mock_session --[[@as agentic.SessionManager]]
                )

                local callback = select_session(1)
                callback({ session_id = "session-1" })

                local conflict_callback = vim_ui_select_stub.calls[2][3]
                conflict_callback("Clear current session and restore")

                assert.spy(mock_session._cancel_session).was.called(1)

                local restore_call = mock_session.restore_from_history.calls[1]
                assert.is_false(restore_call[3].reuse_session)
            end
        )

        it(
            "uses the broader cancel path before replaying restored history",
            function()
                local call_order = {}
                local mock_session = create_mock_session({
                    chat_history = { messages = { { type = "user" } } },
                    _cancel_session = spy.new(function()
                        table.insert(call_order, "cancel_session")
                    end),
                })

                mock_session.widget.clear = spy.new(function()
                    table.insert(call_order, "clear_widget")
                end)
                mock_session.restore_from_history = spy.new(function()
                    table.insert(call_order, "restore_from_history")
                end)

                setup_list_stub()
                setup_load_stub(mock_history)
                setup_registry_stub(mock_session)

                SessionRestore.show_picker(
                    1,
                    mock_session --[[@as agentic.SessionManager]]
                )

                local callback = select_session(1)
                callback({ session_id = "session-1" })

                local conflict_callback = vim_ui_select_stub.calls[2][3]
                conflict_callback("Clear current session and restore")

                assert.same({
                    "cancel_session",
                    "restore_from_history",
                }, call_order)
                assert.spy(mock_session.widget.clear).was.called(0)
            end
        )
    end)

    describe("load failures", function()
        it("shows warning on load error", function()
            setup_list_stub()
            setup_load_stub(nil, "File not found")

            SessionRestore.show_picker(1, nil)

            local callback = select_session(1)
            callback({ session_id = "session-1" })

            assert.spy(logger_notify_stub).was.called(1)
            assert.truthy(
                logger_notify_stub.calls[1][1]:match("File not found")
            )
            assert.equal(vim.log.levels.WARN, logger_notify_stub.calls[1][2])
            assert.spy(session_registry_stub).was.called(0)
        end)

        it("shows warning on nil history without error", function()
            setup_list_stub()
            setup_load_stub(nil, nil)

            SessionRestore.show_picker(1, nil)

            local callback = select_session(1)
            callback({ session_id = "session-1" })

            assert.spy(logger_notify_stub).was.called(1)
            assert.truthy(logger_notify_stub.calls[1][1]:match("unknown error"))
            assert.spy(session_registry_stub).was.called(0)
        end)
    end)

    describe("conflict detection", function()
        it("detects no conflict when current_session is nil", function()
            setup_list_stub()

            SessionRestore.show_picker(1, nil)

            local callback = select_session(1)
            callback({ session_id = "session-1" })

            assert.spy(vim_ui_select_stub).was.called(1)
        end)

        it("detects no conflict when session_id is nil", function()
            local session = {
                session_id = nil,
                chat_history = { messages = { { type = "user" } } },
            }
            setup_list_stub()

            SessionRestore.show_picker(
                1,
                session --[[@as agentic.SessionManager]]
            )

            local callback = select_session(1)
            callback({ session_id = "session-1" })

            assert.spy(vim_ui_select_stub).was.called(1)
        end)

        it("detects no conflict when chat_history is nil", function()
            local session = { session_id = "current", chat_history = nil }
            setup_list_stub()

            SessionRestore.show_picker(
                1,
                session --[[@as agentic.SessionManager]]
            )

            local callback = select_session(1)
            callback({ session_id = "session-1" })

            assert.spy(vim_ui_select_stub).was.called(1)
        end)

        it("detects no conflict when messages array is empty", function()
            local session =
                { session_id = "current", chat_history = { messages = {} } }
            setup_list_stub()

            SessionRestore.show_picker(
                1,
                session --[[@as agentic.SessionManager]]
            )

            local callback = select_session(1)
            callback({ session_id = "session-1" })

            assert.spy(vim_ui_select_stub).was.called(1)
        end)
    end)

    describe("replay_messages", function()
        it(
            "calls on_tool_call_rendered right after writing the tool call",
            function()
                local bufnr = vim.api.nvim_create_buf(false, true)
                local writer = MessageWriter:new(bufnr)
                local call_order = {}
                local original_write_tool_call_block =
                    writer.write_tool_call_block
                local write_tool_call_block_stub =
                    spy.stub(writer, "write_tool_call_block")
                local callback_spy = spy.new(function(tool_call)
                    table.insert(
                        call_order,
                        "callback:" .. tool_call.tool_call_id
                    )
                end)

                write_tool_call_block_stub:invokes(function(self, tool_call)
                    table.insert(call_order, "write:" .. tool_call.tool_call_id)
                    return original_write_tool_call_block(self, tool_call)
                end)

                --- @type agentic.ui.ChatHistory.Message[]
                local messages = {
                    {
                        type = "tool_call",
                        tool_call_id = "tool-restore-1",
                        kind = "execute",
                        status = "completed",
                        argument = "ls",
                        body = { "line 1", "line 2" },
                    },
                }

                SessionRestore.replay_messages(
                    writer,
                    messages,
                    callback_spy --[[@as function]]
                )

                assert.same({
                    "write:tool-restore-1",
                    "callback:tool-restore-1",
                }, call_order)
                assert.spy(callback_spy).was.called(1)
                assert.equal(
                    "tool-restore-1",
                    callback_spy.calls[1][1].tool_call_id
                )

                write_tool_call_block_stub:revert()
                vim.api.nvim_buf_delete(bufnr, { force = true })
            end
        )

        it(
            "keeps replayed tool call headers visible in populated transcripts",
            function()
                local bufnr = vim.api.nvim_create_buf(false, true)
                local winid = vim.api.nvim_open_win(bufnr, true, {
                    relative = "editor",
                    width = 120,
                    height = 40,
                    row = 0,
                    col = 0,
                })
                local writer = MessageWriter:new(bufnr)
                local folds = ChatFolds:new(bufnr, writer)

                --- @type agentic.ui.ChatHistory.Message[]
                local messages = {
                    {
                        type = "agent",
                        text = "The user wants me to execute foo.rb again.",
                    },
                    {
                        type = "tool_call",
                        tool_call_id = "tool-restore-header-visible",
                        kind = "execute",
                        status = "completed",
                        argument = "foo.rb",
                        body = (function()
                            local lines = {}
                            for i = 1, 12 do
                                lines[i] = string.format("line %d", i)
                            end
                            return lines
                        end)(),
                    },
                }

                SessionRestore.replay_messages(
                    writer,
                    messages,
                    function(tool_call)
                        folds:sync_tool_call(tool_call.tool_call_id)
                    end
                )

                local metadata =
                    vim.b[bufnr].agentic_chat_folds.by_tool_call_id["tool-restore-header-visible"]
                assert.is_not_nil(metadata)
                if metadata == nil then
                    return
                end

                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                local header_line = nil
                for i, line in ipairs(lines) do
                    if line == " execute(foo.rb) " then
                        header_line = i
                        break
                    end
                end

                assert.is_not_nil(header_line)
                if header_line == nil then
                    return
                end

                assert.equal(header_line + 1, metadata.fold_start)
                assert.equal(-1, vim.fn.foldclosed(header_line))
                assert.equal(
                    metadata.fold_start,
                    vim.api.nvim_win_call(winid, function()
                        return vim.fn.foldclosed(metadata.fold_start)
                    end)
                )

                vim.api.nvim_win_close(winid, true)
                vim.api.nvim_buf_delete(bufnr, { force = true })
            end
        )
    end)
end)
