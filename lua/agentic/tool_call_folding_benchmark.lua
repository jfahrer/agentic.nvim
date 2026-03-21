local Config = require("agentic.config")
local ACPPayloads = require("agentic.acp.acp_payloads")

--- @class agentic.ToolCallFoldingBenchmark.RunMetrics
--- @field elapsed_ms number
--- @field active_memory_kb number
--- @field retained_memory_kb number
--- @field last_fold_state boolean|nil
--- @field pending_before_restore integer|nil
--- @field pending_after_restore integer|nil

--- @class agentic.ToolCallFoldingBenchmark.ScenarioResult
--- @field path "writer"|"session"
--- @field scenario "live"|"hidden_backfill"
--- @field transcript_size integer
--- @field folding_enabled boolean
--- @field runs agentic.ToolCallFoldingBenchmark.RunMetrics[]
--- @field average_elapsed_ms number
--- @field average_active_memory_kb number
--- @field average_retained_memory_kb number

--- @class agentic.ToolCallFoldingBenchmark.Options
--- @field transcript_sizes? integer[]
--- @field repetitions? integer
--- @field body_line_count? integer
--- @field hidden_after_ratio? number

--- @class agentic.ToolCallFoldingBenchmark.Environment
--- @field writer agentic.ui.MessageWriter
--- @field chat_folds agentic.ui.ChatFolds
--- @field get_last_fold_state fun(): boolean|nil
--- @field get_pending_count fun(): integer
--- @field hide fun()
--- @field show fun()
--- @field cleanup fun()

local Benchmark = {}

local DEFAULT_OPTIONS = {
    transcript_sizes = { 50, 120, 500 },
    repetitions = 3,
    body_line_count = 8,
    hidden_after_ratio = 0.5,
}

--- @param count integer
--- @return string[] body
local function make_body(count)
    local body = {}

    for i = 1, count do
        body[i] = string.format("output line %d", i)
    end

    return body
end

--- @return number kb
local function collect_memory_kb()
    collectgarbage("collect")
    collectgarbage("collect")
    return collectgarbage("count")
end

--- @param values number[]
--- @return number average
local function average(values)
    local total = 0

    for _, value in ipairs(values) do
        total = total + value
    end

    return total / math.max(#values, 1)
end

--- @param chat_folds agentic.ui.ChatFolds
--- @param tool_call_id string
--- @param winid integer|nil
--- @return boolean|nil fold_state
local function get_fold_state(chat_folds, tool_call_id, winid)
    if not winid or not vim.api.nvim_win_is_valid(winid) then
        return nil
    end

    return chat_folds:get_fold_state_for_tool_call(winid, tool_call_id)
end

--- @param folding_enabled boolean
local function apply_benchmark_config(folding_enabled)
    Config.auto_scroll = { threshold = 0 }
    Config.folding = {
        tool_calls = {
            enabled = folding_enabled,
            min_lines = 20,
            kinds = {
                fetch = {
                    enabled = true,
                    min_lines = 6,
                },
                execute = {
                    enabled = true,
                    min_lines = 12,
                },
                edit = {
                    enabled = false,
                },
            },
        },
    }
end

--- @return agentic.ToolCallFoldingBenchmark.Environment env
local function create_writer_environment()
    local MessageWriter = require("agentic.ui.message_writer")
    local ChatFolds = require("agentic.ui.chat_folds")

    local bufnr = vim.api.nvim_create_buf(false, true)
    --- @type integer|nil
    local winid = vim.api.nvim_open_win(bufnr, true, {
        relative = "editor",
        width = 100,
        height = 50,
        row = 0,
        col = 0,
    })

    local writer = MessageWriter:new(bufnr)
    local chat_folds = ChatFolds:new(bufnr)
    writer:set_chat_folds(chat_folds)
    if winid then
        chat_folds:on_buf_win_enter(winid)
    end

    --- @type agentic.ToolCallFoldingBenchmark.Environment
    local env = {
        writer = writer,
        chat_folds = chat_folds,
        get_last_fold_state = function()
            return get_fold_state(chat_folds, "tool-call-last", winid)
        end,
        get_pending_count = function()
            return chat_folds:get_pending_count()
        end,
        hide = function()
            if winid and vim.api.nvim_win_is_valid(winid) then
                vim.api.nvim_win_close(winid, true)
                winid = nil
            end
        end,
        show = function()
            local new_winid = vim.api.nvim_open_win(bufnr, true, {
                relative = "editor",
                width = 100,
                height = 50,
                row = 0,
                col = 0,
            })
            winid = new_winid
            chat_folds:on_buf_win_enter(winid)
        end,
        cleanup = function()
            if winid and vim.api.nvim_win_is_valid(winid) then
                vim.api.nvim_win_close(winid, true)
            end

            if vim.api.nvim_buf_is_valid(bufnr) then
                vim.api.nvim_buf_delete(bufnr, { force = true })
            end
        end,
    }

    return env
end

--- @return agentic.ToolCallFoldingBenchmark.Environment env
local function create_session_environment()
    local AgentInstance = require("agentic.acp.agent_instance")
    local SessionManager = require("agentic.session_manager")

    local dummy_agent = {
        provider_config = {
            name = "Benchmark",
            default_mode = nil,
        },
    }

    local original_get_instance = AgentInstance.get_instance
    AgentInstance.get_instance = function(_provider_name, _on_ready)
        return dummy_agent
    end

    local session = SessionManager:new(vim.api.nvim_get_current_tabpage())
    AgentInstance.get_instance = original_get_instance

    if not session then
        error("Failed to create benchmark SessionManager")
    end

    --- @cast session agentic.SessionManager

    session.widget:show({ focus_prompt = false })
    if session.widget.win_nrs.chat then
        session.chat_folds:on_buf_win_enter(session.widget.win_nrs.chat)
    end

    --- @type agentic.ToolCallFoldingBenchmark.Environment
    local env = {
        writer = session.message_writer,
        chat_folds = session.chat_folds,
        get_last_fold_state = function()
            return get_fold_state(
                session.chat_folds,
                "tool-call-last",
                session.widget.win_nrs.chat
            )
        end,
        get_pending_count = function()
            return session.chat_folds:get_pending_count()
        end,
        hide = function()
            session.widget:hide()
        end,
        show = function()
            session.widget:show({ focus_prompt = false })
            if session.widget.win_nrs.chat then
                session.chat_folds:on_buf_win_enter(session.widget.win_nrs.chat)
            end
        end,
        cleanup = function()
            session:destroy()
        end,
    }

    return env
end

--- @param writer agentic.ui.MessageWriter
--- @param index integer
--- @param is_last boolean
--- @param body_line_count integer
local function write_transcript_step(writer, index, is_last, body_line_count)
    writer:write_message(
        ACPPayloads.generate_agent_message(string.format("message %d", index))
    )

    writer:write_tool_call_block({
        tool_call_id = is_last and "tool-call-last"
            or string.format("tool-call-%d", index),
        kind = "fetch",
        argument = string.format("https://example.com/%d", index),
        status = "completed",
        body = make_body(body_line_count),
    })
end

--- @param factory fun(): agentic.ToolCallFoldingBenchmark.Environment
--- @param scenario "live"|"hidden_backfill"
--- @param transcript_size integer
--- @param body_line_count integer
--- @param hidden_after_ratio number
--- @return agentic.ToolCallFoldingBenchmark.RunMetrics metrics
local function run_single(
    factory,
    scenario,
    transcript_size,
    body_line_count,
    hidden_after_ratio
)
    local env = factory()
    local before_memory = collect_memory_kb()
    local hidden_after =
        math.max(1, math.floor(transcript_size * hidden_after_ratio))
    local pending_before_restore = nil

    local start_time = vim.uv.hrtime()

    for i = 1, transcript_size do
        if scenario == "hidden_backfill" and i == hidden_after + 1 then
            env:hide()
        end

        write_transcript_step(
            env.writer,
            i,
            i == transcript_size,
            body_line_count
        )
    end

    if scenario == "hidden_backfill" then
        pending_before_restore = env:get_pending_count()
        env:show()
    end

    local elapsed_ms = (vim.uv.hrtime() - start_time) / 1e6
    local active_memory = collect_memory_kb() - before_memory
    local last_fold_state = env:get_last_fold_state()
    local pending_after_restore = scenario == "hidden_backfill"
            and env:get_pending_count()
        or nil

    env:cleanup()

    --- @type agentic.ToolCallFoldingBenchmark.RunMetrics
    local metrics = {
        elapsed_ms = elapsed_ms,
        active_memory_kb = active_memory,
        retained_memory_kb = collect_memory_kb() - before_memory,
        last_fold_state = last_fold_state,
        pending_before_restore = pending_before_restore,
        pending_after_restore = pending_after_restore,
    }

    return metrics
end

--- @param path "writer"|"session"
--- @return fun(): agentic.ToolCallFoldingBenchmark.Environment factory
local function get_factory(path)
    if path == "writer" then
        return create_writer_environment
    end

    return create_session_environment
end

--- @param path "writer"|"session"
--- @param scenario "live"|"hidden_backfill"
--- @param transcript_size integer
--- @param folding_enabled boolean
--- @param options agentic.ToolCallFoldingBenchmark.Options
--- @return agentic.ToolCallFoldingBenchmark.ScenarioResult result
local function run_scenario(
    path,
    scenario,
    transcript_size,
    folding_enabled,
    options
)
    local factory = get_factory(path)
    local runs = {}
    local elapsed_values = {}
    local active_memory_values = {}
    local retained_memory_values = {}

    for _ = 1, options.repetitions do
        apply_benchmark_config(folding_enabled)

        local metrics = run_single(
            factory,
            scenario,
            transcript_size,
            options.body_line_count,
            options.hidden_after_ratio
        )
        table.insert(runs, metrics)
        table.insert(elapsed_values, metrics.elapsed_ms)
        table.insert(active_memory_values, metrics.active_memory_kb)
        table.insert(retained_memory_values, metrics.retained_memory_kb)
    end

    --- @type agentic.ToolCallFoldingBenchmark.ScenarioResult
    local result = {
        path = path,
        scenario = scenario,
        transcript_size = transcript_size,
        folding_enabled = folding_enabled,
        runs = runs,
        average_elapsed_ms = average(elapsed_values),
        average_active_memory_kb = average(active_memory_values),
        average_retained_memory_kb = average(retained_memory_values),
    }

    return result
end

--- @param options agentic.ToolCallFoldingBenchmark.Options|nil
--- @return agentic.ToolCallFoldingBenchmark.ScenarioResult[] results
function Benchmark.run(options)
    options = vim.tbl_deep_extend(
        "force",
        vim.deepcopy(DEFAULT_OPTIONS),
        options or {}
    )

    local original_auto_scroll = Config.auto_scroll
    local original_folding = Config.folding
    local results = {}

    for _, path in ipairs({ "writer", "session" }) do
        for _, scenario in ipairs({ "live", "hidden_backfill" }) do
            for _, transcript_size in ipairs(options.transcript_sizes) do
                for _, folding_enabled in ipairs({ false, true }) do
                    table.insert(
                        results,
                        run_scenario(
                            path,
                            scenario,
                            transcript_size,
                            folding_enabled,
                            options
                        )
                    )
                end
            end
        end
    end

    Config.auto_scroll = original_auto_scroll --- @diagnostic disable-line: assign-type-mismatch
    Config.folding = original_folding --- @diagnostic disable-line: assign-type-mismatch

    return results
end

--- @param results agentic.ToolCallFoldingBenchmark.ScenarioResult[]
--- @return string report
function Benchmark.format_report(results)
    local lines = {
        "path scenario size folding avg_ms avg_active_kb avg_retained_kb last_fold pending_before pending_after",
    }

    for _, result in ipairs(results) do
        local last_run = result.runs[#result.runs]
        table.insert(
            lines,
            string.format(
                "%s %s %d %s %.2f %.2f %.2f %s %s %s",
                result.path,
                result.scenario,
                result.transcript_size,
                result.folding_enabled and "on" or "off",
                result.average_elapsed_ms,
                result.average_active_memory_kb,
                result.average_retained_memory_kb,
                tostring(last_run.last_fold_state),
                tostring(last_run.pending_before_restore),
                tostring(last_run.pending_after_restore)
            )
        )
    end

    return table.concat(lines, "\n")
end

--- @param options agentic.ToolCallFoldingBenchmark.Options|nil
function Benchmark.run_cli(options)
    local results = Benchmark.run(options)
    print(Benchmark.format_report(results))
    vim.cmd("qa!")
end

return Benchmark
