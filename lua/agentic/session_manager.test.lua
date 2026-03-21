--- @diagnostic disable: invisible, missing-fields, assign-type-mismatch, cast-local-type, param-type-mismatch
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local AgentModes = require("agentic.acp.agent_modes")
local ChatFolds = require("agentic.ui.chat_folds")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local MessageWriter = require("agentic.ui.message_writer")
local SessionManager = require("agentic.session_manager")
local SlashCommands = require("agentic.acp.slash_commands")

--- @param mode_id string
--- @return agentic.acp.CurrentModeUpdate
local function mode_update(mode_id)
    return { sessionUpdate = "current_mode_update", currentModeId = mode_id }
end

describe("agentic.SessionManager", function()
    describe("_on_session_update: current_mode_update", function()
        --- @type TestStub
        local notify_stub
        --- @type TestSpy
        local render_header_spy
        --- @type agentic.SessionManager
        local session
        --- @type integer
        local test_bufnr

        before_each(function()
            notify_stub = spy.stub(Logger, "notify")
            render_header_spy = spy.new(function() end)
            test_bufnr = vim.api.nvim_create_buf(false, true)

            local legacy_modes = AgentModes:new()
            legacy_modes:set_modes({
                availableModes = {
                    { id = "plan", name = "Plan", description = "Planning" },
                    { id = "code", name = "Code", description = "Coding" },
                },
                currentModeId = "plan",
            })

            session = {
                config_options = {
                    legacy_agent_modes = legacy_modes,
                    get_mode_name = function(_self, mode_id)
                        local mode = legacy_modes:get_mode(mode_id)
                        return mode and mode.name or nil
                    end,
                },
                widget = {
                    render_header = render_header_spy,
                    buf_nrs = { chat = test_bufnr },
                },
                _on_session_update = SessionManager._on_session_update,
                _set_mode_to_chat_header = SessionManager._set_mode_to_chat_header,
            } --[[@as agentic.SessionManager]]
        end)

        after_each(function()
            notify_stub:revert()
            vim.api.nvim_buf_delete(test_bufnr, { force = true })
        end)

        it("updates state, re-renders header, notifies user", function()
            session:_on_session_update(mode_update("code"))

            assert.equal(
                "code",
                session.config_options.legacy_agent_modes.current_mode_id
            )

            assert.spy(render_header_spy).was.called(1)
            assert.equal("chat", render_header_spy.calls[1][2])
            assert.equal("Mode: Code", render_header_spy.calls[1][3])

            assert.spy(notify_stub).was.called(1)
            assert.equal("Mode changed to: code", notify_stub.calls[1][1])
            assert.equal(vim.log.levels.INFO, notify_stub.calls[1][2])
        end)

        it("rejects invalid mode and keeps current state", function()
            session:_on_session_update(mode_update("nonexistent"))

            assert.equal(
                "plan",
                session.config_options.legacy_agent_modes.current_mode_id
            )
            assert.spy(render_header_spy).was.called(0)

            assert.spy(notify_stub).was.called(1)
            assert.equal(vim.log.levels.WARN, notify_stub.calls[1][2])
        end)
    end)

    describe("_on_session_update: config_option_update", function()
        --- @type TestSpy
        local render_header_spy
        --- @type agentic.SessionManager
        local session
        --- @type integer
        local test_bufnr

        before_each(function()
            render_header_spy = spy.new(function() end)
            test_bufnr = vim.api.nvim_create_buf(false, true)

            local AgentConfigOptions =
                require("agentic.acp.agent_config_options")
            local BufHelpers = require("agentic.utils.buf_helpers")
            local keymap_stub = spy.stub(BufHelpers, "multi_keymap_set")

            local config_opts = AgentConfigOptions:new(
                { chat = test_bufnr },
                function() end,
                function() end
            )

            keymap_stub:revert()

            session = {
                config_options = config_opts,
                widget = {
                    render_header = render_header_spy,
                    buf_nrs = { chat = test_bufnr },
                },
                _on_session_update = SessionManager._on_session_update,
                _set_mode_to_chat_header = SessionManager._set_mode_to_chat_header,
                _handle_new_config_options = SessionManager._handle_new_config_options,
            } --[[@as agentic.SessionManager]]
        end)

        after_each(function()
            vim.api.nvim_buf_delete(test_bufnr, { force = true })
        end)

        it("sets config options and updates header on mode", function()
            --- @type agentic.acp.ConfigOptionsUpdate
            local update = {
                sessionUpdate = "config_option_update",
                configOptions = {
                    {
                        id = "mode-1",
                        category = "mode",
                        currentValue = "plan",
                        description = "Mode",
                        name = "Mode",
                        options = {
                            {
                                value = "plan",
                                name = "Plan",
                                description = "",
                            },
                        },
                    },
                },
            }

            session:_on_session_update(update)

            assert.is_not_nil(session.config_options.mode)
            assert.equal("plan", session.config_options.mode.currentValue)
            assert.spy(render_header_spy).was.called(1)
            assert.equal("Mode: Plan", render_header_spy.calls[1][3])
        end)
    end)

    describe("_generate_welcome_header", function()
        it(
            "returns header with provider name, session id, and timestamp",
            function()
                local header = SessionManager._generate_welcome_header(
                    "Claude ACP",
                    "abc123"
                )

                assert.truthy(header:match("^# Agentic %- Claude ACP\n"))
                assert.truthy(header:match("\n%- %d%d%d%d%-%d%d%-%d%d"))
                assert.truthy(header:match("\n%- session id: abc123\n"))
                assert.truthy(header:match("\n%-%-%- %-%-$"))
            end
        )

        it("uses 'unknown' when session_id is nil", function()
            local header =
                SessionManager._generate_welcome_header("Claude ACP", nil)

            assert.truthy(header:match("^# Agentic %- Claude ACP\n"))
            assert.truthy(header:match("\n%- session id: unknown\n"))
            assert.truthy(header:match("\n%-%-%- %-%-$"))
        end)

        it("includes version when provided", function()
            local header = SessionManager._generate_welcome_header(
                "Claude ACP",
                "abc123",
                "1.2.3"
            )

            assert.truthy(header:match("^# Agentic %- Claude ACP v1%.2%.3\n"))
            assert.truthy(header:match("\n%- session id: abc123\n"))
        end)

        it("omits version when nil", function()
            local header = SessionManager._generate_welcome_header(
                "Claude ACP",
                "abc123",
                nil
            )

            assert.truthy(header:match("^# Agentic %- Claude ACP\n"))
            assert.is_nil(header:match(" v"))
        end)
    end)

    describe("switch_provider", function()
        --- @type TestStub
        local notify_stub
        --- @type TestStub
        local get_instance_stub
        --- @type TestStub
        local schedule_stub
        local original_provider

        before_each(function()
            original_provider = Config.provider
            notify_stub = spy.stub(Logger, "notify")
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)
        end)

        after_each(function()
            Config.provider = original_provider
            schedule_stub:revert()
            notify_stub:revert()
            if get_instance_stub then
                get_instance_stub:revert()
                get_instance_stub = nil
            end
        end)

        it("blocks when is_generating is true", function()
            local session = {
                is_generating = true,
                switch_provider = SessionManager.switch_provider,
            } --[[@as agentic.SessionManager]]

            session:switch_provider()

            assert.spy(notify_stub).was.called(1)
            local msg = notify_stub.calls[1][1]
            assert.truthy(msg:match("[Gg]enerating"))
        end)

        it(
            "soft cancels old session without clearing widget/history",
            function()
                local cancel_spy = spy.new(function() end)
                local perm_clear_spy = spy.new(function() end)
                local todo_clear_spy = spy.new(function() end)
                local widget_clear_spy = spy.new(function() end)
                local file_list_clear_spy = spy.new(function() end)
                local code_selection_clear_spy = spy.new(function() end)

                local AgentInstance = require("agentic.acp.agent_instance")
                local mock_new_agent = {
                    provider_config = { name = "New Provider" },
                    create_session = spy.new(function() end),
                }
                get_instance_stub = spy.stub(AgentInstance, "get_instance")
                get_instance_stub:invokes(function(_provider, on_ready)
                    on_ready(mock_new_agent)
                    return mock_new_agent
                end)

                local new_session_spy = spy.new(function() end)

                local original_messages = { { type = "user", text = "hello" } }
                local mock_chat_history = {
                    messages = original_messages,
                    session_id = "old-session",
                }

                Config.provider = "new-provider"

                local session = {
                    is_generating = false,
                    session_id = "old-session",

                    agent = {
                        cancel_session = cancel_spy,
                        provider_config = { name = "Old Provider" },
                    },
                    permission_manager = { clear = perm_clear_spy },
                    todo_list = { clear = todo_clear_spy },
                    widget = { clear = widget_clear_spy },
                    file_list = { clear = file_list_clear_spy },
                    code_selection = { clear = code_selection_clear_spy },
                    chat_history = mock_chat_history,
                    _is_first_message = false,
                    _history_to_send = nil,
                    new_session = new_session_spy,
                    switch_provider = SessionManager.switch_provider,
                } --[[@as agentic.SessionManager]]

                session:switch_provider()

                assert.spy(cancel_spy).was.called(1)
                assert.is_nil(session.session_id)
                assert.spy(perm_clear_spy).was.called(1)
                assert.spy(todo_clear_spy).was.called(1)

                assert.spy(widget_clear_spy).was.called(0)
                assert.spy(file_list_clear_spy).was.called(0)
                assert.spy(code_selection_clear_spy).was.called(0)

                assert.equal(mock_new_agent, session.agent)

                assert.spy(new_session_spy).was.called(1)
                local opts = new_session_spy.calls[1][2]
                assert.is_true(opts.restore_mode)
                assert.equal("function", type(opts.on_created))
            end
        )

        it(
            "schedules history resend and sets _is_first_message in on_created",
            function()
                local AgentInstance = require("agentic.acp.agent_instance")
                local mock_new_agent = {
                    provider_config = { name = "New Provider" },
                    create_session = spy.new(function() end),
                }
                get_instance_stub = spy.stub(AgentInstance, "get_instance")
                get_instance_stub:invokes(function(_provider, on_ready)
                    on_ready(mock_new_agent)
                    return mock_new_agent
                end)

                local captured_on_created
                local new_session_spy = spy.new(function(_self, opts)
                    captured_on_created = opts.on_created
                end)

                local original_messages = { { type = "user", text = "hello" } }
                local saved_history = {
                    messages = original_messages,
                    session_id = "old",
                }

                Config.provider = "new-provider"

                local session = {
                    is_generating = false,
                    session_id = "old-session",

                    agent = {
                        cancel_session = spy.new(function() end),
                        provider_config = { name = "Old" },
                    },
                    permission_manager = { clear = function() end },
                    todo_list = { clear = function() end },
                    chat_history = saved_history,
                    _is_first_message = false,
                    _history_to_send = nil,
                    new_session = new_session_spy,
                    switch_provider = SessionManager.switch_provider,
                } --[[@as agentic.SessionManager]]

                session:switch_provider()

                assert.is_not_nil(captured_on_created)

                local new_timestamp = os.time()
                session.chat_history = {
                    messages = {},
                    session_id = "new",
                    timestamp = new_timestamp,
                }
                captured_on_created()

                assert.same(original_messages, session.chat_history.messages)
                assert.equal("new", session.chat_history.session_id)
                assert.equal(new_timestamp, session.chat_history.timestamp)
                assert.same(original_messages, session._history_to_send)
                assert.is_true(session._is_first_message)
            end
        )

        it("no-ops soft cancel when session_id is nil", function()
            local AgentInstance = require("agentic.acp.agent_instance")
            local mock_agent = {
                provider_config = { name = "Provider" },
                cancel_session = spy.new(function() end),
                create_session = spy.new(function() end),
            }
            get_instance_stub = spy.stub(AgentInstance, "get_instance")
            get_instance_stub:invokes(function(_provider, on_ready)
                on_ready(mock_agent)
                return mock_agent
            end)

            Config.provider = "some-provider"

            local session = {
                is_generating = false,
                session_id = nil,

                agent = mock_agent,
                permission_manager = { clear = spy.new(function() end) },
                todo_list = { clear = spy.new(function() end) },
                chat_history = { messages = {} },
                _is_first_message = false,
                _history_to_send = nil,
                new_session = spy.new(function() end),
                switch_provider = SessionManager.switch_provider,
            } --[[@as agentic.SessionManager]]

            session:switch_provider()

            assert.spy(mock_agent.cancel_session).was.called(0)
            assert.spy(session.permission_manager.clear).was.called(1)
            assert.spy(session.todo_list.clear).was.called(1)
            assert.spy(session.new_session).was.called(1)
        end)
    end)

    describe("_cancel_session", function()
        --- @type TestStub
        local slash_commands_stub
        --- @type integer
        local chat_bufnr
        --- @type integer
        local input_bufnr

        before_each(function()
            chat_bufnr = vim.api.nvim_create_buf(false, true)
            input_bufnr = vim.api.nvim_create_buf(false, true)
            slash_commands_stub = spy.stub(SlashCommands, "setCommands")
        end)

        after_each(function()
            slash_commands_stub:revert()

            if vim.api.nvim_buf_is_valid(chat_bufnr) then
                vim.api.nvim_buf_delete(chat_bufnr, { force = true })
            end

            if vim.api.nvim_buf_is_valid(input_bufnr) then
                vim.api.nvim_buf_delete(input_bufnr, { force = true })
            end
        end)

        it("clears fold metadata and fold caches", function()
            local writer = MessageWriter:new(chat_bufnr)
            local chat_folds = ChatFolds:new(chat_bufnr, writer)
            local state = vim.b[chat_bufnr].agentic_chat_folds

            state.by_tool_call_id["tool-reset-1"] = {
                fold_start = 2,
                fold_end = 8,
                body_line_count = 7,
            }
            state.by_fold_start[2] = {
                tool_call_id = "tool-reset-1",
                body_line_count = 7,
            }
            chat_folds._tool_call_decisions["tool-reset-1"] = {
                kind = "execute",
                enabled = true,
                min_lines = 12,
                decided = true,
                should_close = true,
                body_line_count = 7,
            }
            chat_folds._pending_tool_call_ids["tool-reset-1"] = true

            local session = {
                session_id = "session-1",
                agent = { cancel_session = spy.new(function() end) },
                widget = {
                    clear = spy.new(function() end),
                    buf_nrs = { input = input_bufnr },
                },
                todo_list = { clear = spy.new(function() end) },
                file_list = { clear = spy.new(function() end) },
                code_selection = { clear = spy.new(function() end) },
                diagnostics_list = { clear = spy.new(function() end) },
                config_options = { clear = spy.new(function() end) },
                chat_folds = chat_folds,
                permission_manager = { clear = spy.new(function() end) },
                chat_history = { messages = { "old" } },
                _history_to_send = { "old" },
                _cancel_session = SessionManager._cancel_session,
            } --[[@as agentic.SessionManager]]

            session:_cancel_session()

            local reset_state = vim.b[chat_bufnr].agentic_chat_folds
            assert.same({}, reset_state.by_tool_call_id)
            assert.same({}, reset_state.by_fold_start)
            assert.same({}, chat_folds._tool_call_decisions)
            assert.same({}, chat_folds._pending_tool_call_ids)
        end)
    end)

    describe("FileChangedShell autocommand", function()
        local Child = require("tests.helpers.child")
        local child = Child:new()

        before_each(function()
            child.setup()
        end)

        after_each(function()
            child.stop()
        end)

        it("sets fcs_choice to reload when FileChangedShell fires", function()
            child.v.fcs_choice = ""
            child.api.nvim_exec_autocmds("FileChangedShell", {
                group = "AgenticCleanup",
                pattern = "*",
            })

            assert.equal("reload", child.v.fcs_choice)
        end)
    end)

    describe("chat fold reopen", function()
        local Child = require("tests.helpers.child")
        local child = Child.new()

        before_each(function()
            child.setup()
        end)

        after_each(function()
            child.stop()
        end)

        it(
            "preserves Neovim-restored fold state when the widget reopens",
            function()
                local result = child.lua([[
                    local SessionRegistry = require("agentic.session_registry")

                    vim.cmd("enew")

                    local session = SessionRegistry.get_session_for_tab_page()
                    session.widget:show({ focus_prompt = false })

                    local body = {}
                    for i = 1, 13 do
                        body[i] = string.format("output %d", i)
                    end

                    session.message_writer:write_tool_call_block({
                        tool_call_id = "tool-reopen-1",
                        kind = "execute",
                        status = "completed",
                        argument = "ls",
                        body = body,
                    })
                    session.chat_folds:sync_tool_call("tool-reopen-1")

                    local metadata = vim.b[session.widget.buf_nrs.chat].agentic_chat_folds.by_tool_call_id["tool-reopen-1"]
                    local chat_winid = vim.fn.bufwinid(session.widget.buf_nrs.chat)

                    vim.api.nvim_win_set_cursor(chat_winid, { metadata.fold_start, 0 })
                    vim.api.nvim_win_call(chat_winid, function()
                        vim.cmd("silent keepjumps normal! zo")
                    end)

                    local fold_before_hide = vim.api.nvim_win_call(chat_winid, function()
                        return vim.fn.foldclosed(metadata.fold_start)
                    end)

                    local original_create_fold = session.chat_folds.create_fold
                    session.chat_folds._create_fold_calls = 0
                    session.chat_folds.create_fold = function(self, tool_call_id)
                        self._create_fold_calls = self._create_fold_calls + 1
                        return original_create_fold(self, tool_call_id)
                    end

                    session.widget:hide()
                    session.widget:show({ focus_prompt = false })

                    local reopened_winid = vim.fn.bufwinid(session.widget.buf_nrs.chat)
                    local fold_after_reopen = vim.api.nvim_win_call(reopened_winid, function()
                        return vim.fn.foldclosed(metadata.fold_start)
                    end)

                    vim.wo[reopened_winid].foldenable = false
                    vim.wo[reopened_winid].foldtext = ""

                    vim.api.nvim_win_call(reopened_winid, function()
                        vim.api.nvim_exec_autocmds("BufWinEnter", {
                            buffer = session.widget.buf_nrs.chat,
                            modeline = false,
                        })
                    end)

                    return {
                        fold_before_hide = fold_before_hide,
                        fold_after_reopen = fold_after_reopen,
                        fold_after_bufwinenter = vim.api.nvim_win_call(reopened_winid, function()
                            return vim.fn.foldclosed(metadata.fold_start)
                        end),
                        create_fold_calls = session.chat_folds._create_fold_calls,
                        foldmethod = vim.wo[reopened_winid].foldmethod,
                        foldenable = vim.wo[reopened_winid].foldenable,
                        foldtext = vim.wo[reopened_winid].foldtext,
                    }
                ]])

                assert.equal(-1, result.fold_before_hide)
                assert.equal(-1, result.fold_after_reopen)
                assert.equal(-1, result.fold_after_bufwinenter)
                assert.equal(0, result.create_fold_calls)
                assert.equal("manual", result.foldmethod)
                assert.is_true(result.foldenable)
                assert.equal(
                    "v:lua.require'agentic.ui.chat_folds'.foldtext()",
                    result.foldtext
                )
            end
        )

        it(
            "queues fold creation when a foldable tool call completes while hidden",
            function()
                local result = child.lua([[
                    local SessionRegistry = require("agentic.session_registry")

                    local session = SessionRegistry.get_session_for_tab_page()
                    session.widget:show({ focus_prompt = false })

                    local body = {}
                    for i = 1, 13 do
                        body[i] = string.format("output %d", i)
                    end

                    session.message_writer:write_tool_call_block({
                        tool_call_id = "tool-hidden-1",
                        kind = "execute",
                        status = "in_progress",
                        argument = "ls",
                        body = body,
                    })

                    session.widget:hide()

                    session.message_writer:update_tool_call_block({
                        tool_call_id = "tool-hidden-1",
                        status = "completed",
                        body = body,
                    })

                    local synced_while_hidden = session.chat_folds:sync_tool_call("tool-hidden-1")
                    local state_while_hidden = vim.b[session.widget.buf_nrs.chat].agentic_chat_folds
                    local pending_while_hidden = session.chat_folds._pending_tool_call_ids["tool-hidden-1"] == true

                    session.widget:show({ focus_prompt = false })

                    local reopened_winid = vim.fn.bufwinid(session.widget.buf_nrs.chat)
                    vim.api.nvim_win_call(reopened_winid, function()
                        vim.api.nvim_exec_autocmds("BufWinEnter", {
                            buffer = session.widget.buf_nrs.chat,
                            modeline = false,
                        })
                    end)
                    local metadata_after_reopen = vim.b[session.widget.buf_nrs.chat].agentic_chat_folds.by_tool_call_id["tool-hidden-1"]

                    return {
                        synced_while_hidden = synced_while_hidden,
                        has_metadata_while_hidden = state_while_hidden.by_tool_call_id["tool-hidden-1"] ~= nil,
                        pending_while_hidden = pending_while_hidden,
                        has_metadata_after_reopen = metadata_after_reopen ~= nil,
                        pending_after_reopen = session.chat_folds._pending_tool_call_ids["tool-hidden-1"] == true,
                        fold_after_reopen = metadata_after_reopen
                                and vim.api.nvim_win_call(reopened_winid, function()
                                    return vim.fn.foldclosed(metadata_after_reopen.fold_start)
                                end)
                            or nil,
                    }
                ]])

                assert.is_false(result.synced_while_hidden)
                assert.is_false(result.has_metadata_while_hidden)
                assert.is_true(result.pending_while_hidden)
                assert.is_true(result.has_metadata_after_reopen)
                assert.is_false(result.pending_after_reopen)
                assert.is_not_nil(result.fold_after_reopen)
            end
        )
    end)

    describe("on_tool_call_update: buffer reload", function()
        --- @type TestStub
        local checktime_stub
        --- @type TestStub
        local schedule_stub

        --- @param tool_call_blocks table<string, table>
        --- @return agentic.SessionManager
        local function make_session(tool_call_blocks)
            return {
                message_writer = {
                    update_tool_call_block = function() end,
                    tool_call_blocks = tool_call_blocks,
                },
                chat_folds = { sync_tool_call = function() end },
                permission_manager = {
                    current_request = nil,
                    queue = {},
                    remove_request_by_tool_call_id = function() end,
                },
                status_animation = { start = function() end },
                _clear_diff_in_buffer = function() end,
                chat_history = {
                    update_tool_call = function() end,
                    add_message = function() end,
                },
                _sync_tool_call_folds = SessionManager._sync_tool_call_folds,
                _on_tool_call = function() end,
            } --[[@as agentic.SessionManager]]
        end

        before_each(function()
            checktime_stub = spy.stub(vim.cmd, "checktime")
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)
        end)

        after_each(function()
            checktime_stub:revert()
            schedule_stub:revert()
        end)

        it("calls checktime for each file-mutating kind", function()
            for _, kind in ipairs({
                "edit",
                "create",
                "write",
                "delete",
                "move",
            }) do
                checktime_stub:reset()
                local tc_id = "tc-" .. kind
                local session = make_session({
                    [tc_id] = { kind = kind, status = "in_progress" },
                })

                SessionManager._on_tool_call_update(
                    session,
                    { tool_call_id = tc_id, status = "completed" }
                )

                assert.spy(checktime_stub).was.called(1)
            end
        end)

        it("does not call checktime for failed tool calls", function()
            local session = make_session({
                ["tc-1"] = { kind = "edit", status = "in_progress" },
            })

            SessionManager._on_tool_call_update(
                session,
                { tool_call_id = "tc-1", status = "failed" }
            )

            assert.spy(checktime_stub).was.called(0)
        end)

        it("does not call checktime for non-mutating kinds", function()
            local session = make_session({
                ["tc-1"] = { kind = "read", status = "in_progress" },
            })

            SessionManager._on_tool_call_update(
                session,
                { tool_call_id = "tc-1", status = "completed" }
            )

            assert.spy(checktime_stub).was.called(0)
        end)

        it("does not call checktime when tracker is missing", function()
            local debug_stub = spy.stub(Logger, "debug")
            local session = make_session({})

            SessionManager._on_tool_call_update(
                session,
                { tool_call_id = "tc-missing", status = "completed" }
            )

            assert.spy(checktime_stub).was.called(0)
            debug_stub:revert()
        end)
    end)

    describe("tool call fold sync", function()
        it("syncs folds after live on_tool_call writes the block", function()
            local create_session_spy
            local captured_handlers
            local call_order = {}
            local sync_spy = spy.new(function(_self, tool_call_id)
                table.insert(call_order, "sync:" .. tool_call_id)
            end)

            local session = {
                status_animation = {
                    start = spy.new(function() end),
                    stop = spy.new(function() end),
                },
                message_writer = {
                    tool_call_blocks = {},
                    write_tool_call_block = spy.new(function(_self, tool_call)
                        table.insert(
                            call_order,
                            "write:" .. tool_call.tool_call_id
                        )
                        _self.tool_call_blocks[tool_call.tool_call_id] =
                            tool_call
                    end),
                    write_message = spy.new(function() end),
                },
                chat_folds = { sync_tool_call = sync_spy },
                chat_history = {
                    add_message = spy.new(function(_self, tool_call)
                        table.insert(
                            call_order,
                            "history:" .. tool_call.tool_call_id
                        )
                    end),
                },
                config_options = {
                    set_initial_mode = spy.new(function() end),
                },
                _on_tool_call = SessionManager._on_tool_call,
                _sync_tool_call_folds = SessionManager._sync_tool_call_folds,
                new_session = SessionManager.new_session,
            } --[[@as agentic.SessionManager]]

            create_session_spy = spy.new(function(_self, handlers, _callback)
                captured_handlers = handlers
            end)

            session.agent = {
                provider_config = {
                    name = "Provider",
                    default_mode = "code",
                },
                create_session = create_session_spy,
            }

            session:new_session({ restore_mode = true })

            assert.is_not_nil(captured_handlers)
            if captured_handlers == nil then
                return
            end

            captured_handlers.on_tool_call({
                tool_call_id = "tool-live-1",
                kind = "execute",
                status = "pending",
                argument = "ls",
                body = { "line 1" },
            })

            assert.same({
                "write:tool-live-1",
                "sync:tool-live-1",
                "history:tool-live-1",
            }, call_order)
        end)

        it("syncs folds after tool call updates before checktime", function()
            local checktime_stub = spy.stub(vim.cmd, "checktime")
            local schedule_stub = spy.stub(vim, "schedule")
            local call_order = {}

            schedule_stub:invokes(function(fn)
                fn()
            end)

            local session = {
                message_writer = {
                    tool_call_blocks = {
                        ["tool-update-1"] = {
                            kind = "edit",
                            status = "in_progress",
                        },
                    },
                    update_tool_call_block = spy.new(function(_self, update)
                        table.insert(
                            call_order,
                            "update:" .. update.tool_call_id
                        )
                    end),
                },
                chat_folds = {
                    sync_tool_call = spy.new(function(_self, tool_call_id)
                        table.insert(call_order, "sync:" .. tool_call_id)
                    end),
                },
                permission_manager = {
                    current_request = nil,
                    queue = {},
                    remove_request_by_tool_call_id = spy.new(function() end),
                },
                status_animation = {
                    start = spy.new(function()
                        table.insert(call_order, "status")
                    end),
                },
                chat_history = {
                    update_tool_call = spy.new(function(_self, tool_call_id)
                        table.insert(call_order, "history:" .. tool_call_id)
                    end),
                },
                _clear_diff_in_buffer = function(_self, tool_call_id)
                    table.insert(call_order, "clear:" .. tool_call_id)
                end,
                _sync_tool_call_folds = SessionManager._sync_tool_call_folds,
            } --[[@as agentic.SessionManager]]

            checktime_stub:invokes(function()
                table.insert(call_order, "checktime")
            end)

            SessionManager._on_tool_call_update(session, {
                tool_call_id = "tool-update-1",
                status = "completed",
            })

            assert.same({
                "update:tool-update-1",
                "sync:tool-update-1",
                "history:tool-update-1",
                "clear:tool-update-1",
                "checktime",
                "status",
            }, call_order)

            schedule_stub:revert()
            checktime_stub:revert()
        end)

        it(
            "passes replayed tool calls through fold sync during restore",
            function()
                local SessionRestore = require("agentic.session_restore")
                local replay_stub = spy.stub(SessionRestore, "replay_messages")
                local call_order = {}

                replay_stub:invokes(
                    function(_writer, _messages, on_tool_call_rendered)
                        table.insert(call_order, "replay")
                        if on_tool_call_rendered then
                            on_tool_call_rendered({
                                tool_call_id = "tool-restore-sync-1",
                            })
                        end
                    end
                )

                local session = {
                    _restoring = false,
                    _history_to_send = nil,
                    _is_first_message = true,
                    session_id = "session-1",
                    message_writer = {},
                    widget = { clear = spy.new(function() end) },
                    chat_folds = {
                        reset = spy.new(function() end),
                        sync_tool_call = spy.new(function(_self, tool_call_id)
                            table.insert(call_order, "sync:" .. tool_call_id)
                        end),
                    },
                    permission_manager = { clear = spy.new(function() end) },
                    todo_list = { clear = spy.new(function() end) },
                    file_list = { clear = spy.new(function() end) },
                    code_selection = { clear = spy.new(function() end) },
                    diagnostics_list = { clear = spy.new(function() end) },
                    chat_history = {
                        messages = {},
                        title = "",
                    },
                    _sync_tool_call_folds = SessionManager._sync_tool_call_folds,
                    restore_from_history = SessionManager.restore_from_history,
                } --[[@as agentic.SessionManager]]

                session:restore_from_history({
                    title = "restored",
                    messages = {
                        {
                            type = "tool_call",
                            tool_call_id = "tool-restore-sync-1",
                        },
                    },
                }, { reuse_session = true })

                assert.same(
                    { "replay", "sync:tool-restore-sync-1" },
                    call_order
                )
                replay_stub:revert()
            end
        )
    end)

    describe("restore_from_history", function()
        it("keeps history queued for ACP when reusing the session", function()
            local SessionRestore = require("agentic.session_restore")
            local replay_stub = spy.stub(SessionRestore, "replay_messages")

            local history_messages = {
                {
                    type = "user",
                    text = "restored prompt",
                    timestamp = 1,
                    provider_name = "Provider",
                },
            }

            local session = {
                _restoring = false,
                _history_to_send = nil,
                _is_first_message = true,
                session_id = "session-1",
                message_writer = {},
                widget = { clear = spy.new(function() end) },
                chat_folds = {
                    reset = spy.new(function() end),
                    sync_tool_call = spy.new(function() end),
                },
                permission_manager = { clear = spy.new(function() end) },
                todo_list = { clear = spy.new(function() end) },
                file_list = { clear = spy.new(function() end) },
                code_selection = { clear = spy.new(function() end) },
                diagnostics_list = { clear = spy.new(function() end) },
                chat_history = {
                    messages = {},
                    title = "",
                },
                _sync_tool_call_folds = SessionManager._sync_tool_call_folds,
                restore_from_history = SessionManager.restore_from_history,
            } --[[@as agentic.SessionManager]]

            session:restore_from_history({
                title = "restored",
                messages = history_messages,
            }, { reuse_session = true })

            assert.same(history_messages, session._history_to_send)
            replay_stub:revert()
        end)

        it(
            "clears current UI state before replay when reusing the session",
            function()
                local SessionRestore = require("agentic.session_restore")
                local replay_stub = spy.stub(SessionRestore, "replay_messages")
                local call_order = {}

                local session = {
                    _restoring = false,
                    _history_to_send = nil,
                    _is_first_message = true,
                    session_id = "session-1",
                    message_writer = {},
                    widget = {
                        clear = spy.new(function()
                            table.insert(call_order, "widget_clear")
                        end),
                    },
                    chat_folds = {
                        reset = spy.new(function()
                            table.insert(call_order, "folds_reset")
                        end),
                        sync_tool_call = spy.new(function() end),
                    },
                    permission_manager = {
                        clear = spy.new(function()
                            table.insert(call_order, "permissions_clear")
                        end),
                    },
                    todo_list = {
                        clear = spy.new(function()
                            table.insert(call_order, "todos_clear")
                        end),
                    },
                    file_list = {
                        clear = spy.new(function()
                            table.insert(call_order, "files_clear")
                        end),
                    },
                    code_selection = {
                        clear = spy.new(function()
                            table.insert(call_order, "code_clear")
                        end),
                    },
                    diagnostics_list = {
                        clear = spy.new(function()
                            table.insert(call_order, "diagnostics_clear")
                        end),
                    },
                    chat_history = {
                        messages = { { type = "user" } },
                        title = "current",
                    },
                    _sync_tool_call_folds = SessionManager._sync_tool_call_folds,
                    restore_from_history = SessionManager.restore_from_history,
                } --[[@as agentic.SessionManager]]

                replay_stub:invokes(function()
                    table.insert(call_order, "replay")
                end)

                session:restore_from_history({
                    title = "restored",
                    messages = {},
                }, { reuse_session = true })

                assert.same({
                    "widget_clear",
                    "folds_reset",
                    "permissions_clear",
                    "todos_clear",
                    "files_clear",
                    "code_clear",
                    "diagnostics_clear",
                    "replay",
                }, call_order)

                replay_stub:revert()
            end
        )

        it(
            "clears restoring flag when restore session creation fails",
            function()
                local session = {
                    _restoring = false,
                    _history_to_send = nil,
                    _is_first_message = true,
                    session_id = nil,
                    chat_history = {
                        messages = {},
                        title = "",
                    },
                    new_session = spy.new(function(_self, opts)
                        opts.on_failed()
                    end),
                    restore_from_history = SessionManager.restore_from_history,
                } --[[@as agentic.SessionManager]]

                session:restore_from_history({
                    title = "restored",
                    messages = {},
                })

                assert.is_false(session._restoring)
            end
        )
    end)

    describe("hidden tool call completion", function()
        local Child = require("tests.helpers.child")
        local child = Child.new()

        before_each(function()
            child.setup()
        end)

        after_each(function()
            child.stop()
        end)

        it(
            "backfills only pending hidden tool calls when the widget shows again",
            function()
                local result = child.lua([[ 
                    local SessionRegistry = require("agentic.session_registry")

                    local session = SessionRegistry.get_session_for_tab_page()
                    session.widget:show({ focus_prompt = false })

                    local body = {}
                    for i = 1, 13 do
                        body[i] = string.format("output %d", i)
                    end

                    session.message_writer:write_tool_call_block({
                        tool_call_id = "tool-existing-1",
                        kind = "execute",
                        status = "completed",
                        argument = "ls",
                        body = body,
                    })
                    session.chat_folds:sync_tool_call("tool-existing-1")

                    session.widget:hide()

                    session.message_writer:write_tool_call_block({
                        tool_call_id = "tool-hidden-new-1",
                        kind = "execute",
                        status = "completed",
                        argument = "pwd",
                        body = body,
                    })
                    session.chat_folds:sync_tool_call("tool-hidden-new-1")

                    local original_create_fold = session.chat_folds.create_fold
                    session.chat_folds._create_fold_calls = {}
                    session.chat_folds.create_fold = function(self, tool_call_id)
                        table.insert(self._create_fold_calls, tool_call_id)
                        return original_create_fold(self, tool_call_id)
                    end

                    session.widget:show({ focus_prompt = false })

                    local chat_winid = vim.fn.bufwinid(session.widget.buf_nrs.chat)
                    vim.api.nvim_win_call(chat_winid, function()
                        vim.api.nvim_exec_autocmds("BufWinEnter", {
                            buffer = session.widget.buf_nrs.chat,
                            modeline = false,
                        })
                    end)

                    local hidden_metadata = vim.b[session.widget.buf_nrs.chat].agentic_chat_folds.by_tool_call_id["tool-hidden-new-1"]
                    local existing_metadata = vim.b[session.widget.buf_nrs.chat].agentic_chat_folds.by_tool_call_id["tool-existing-1"]

                    return {
                        create_fold_calls = session.chat_folds._create_fold_calls,
                        pending_count = vim.tbl_count(session.chat_folds._pending_tool_call_ids),
                        hidden_has_metadata = hidden_metadata ~= nil,
                        existing_has_metadata = existing_metadata ~= nil,
                    }
                ]])

                assert.same({ "tool-hidden-new-1" }, result.create_fold_calls)
                assert.equal(0, result.pending_count)
                assert.is_true(result.hidden_has_metadata)
                assert.is_true(result.existing_has_metadata)
            end
        )
    end)
end)
