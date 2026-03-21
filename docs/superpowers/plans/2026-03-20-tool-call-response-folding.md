# Tool Call Response Folding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add native Neovim folding for tool call response bodies, with configurable thresholds, correct live/update/replay behavior, hidden-window backfill, and benchmark coverage that proves the feature stays responsive on long transcripts.

**Architecture:** Introduce a per-session `agentic.ui.ChatFolds` object owned by `SessionManager`. `MessageWriter` remains the source of truth for rendered tool call blocks and extmark-backed row tracking. `ChatFolds` resolves policy from `Config.folding.tool_calls`, creates or refreshes body-only folds for the session chat window, records hidden-time pending folds, and relies on Neovim to restore already-existing folds on widget reopen. `SessionManager` wires live updates, replay, and `BufWinEnter` backfill. A separate `hrtime`-based benchmark helper measures hot-path and reopen performance without becoming an initial CI timing gate.

**Tech Stack:** Lua, Neovim native folds/extmarks/autocmds, mini.test, child Neovim tests, `vim.loop.hrtime()` / `vim.uv.hrtime()`

---

## File Structure

- Create: `lua/agentic/ui/chat_folds.lua`
- Create: `lua/agentic/ui/chat_folds.test.lua`
- Create: `tests/benchmarks/tool_call_response_folding.lua`
- Modify: `lua/agentic/config_default.lua`
- Modify: `README.md`
- Modify: `lua/agentic/ui/message_writer.lua`
- Modify: `lua/agentic/ui/message_writer.test.lua`
- Modify: `lua/agentic/session_manager.lua`
- Modify: `lua/agentic/session_manager.test.lua`
- Modify: `lua/agentic/session_restore.lua`
- Modify: `lua/agentic/session_restore.test.lua`
- Modify: `Makefile`

### Task 1: Config Surface and Policy Defaults

**Files:**
- Create: `lua/agentic/ui/chat_folds.test.lua`
- Modify: `lua/agentic/config_default.lua`
- Modify: `README.md`
- Test: `lua/agentic/ui/chat_folds.test.lua`

- [ ] **Step 1: Write the failing policy/default tests**

```lua
local assert = require("tests.helpers.assert")

describe("agentic.ui.ChatFolds policy", function()
    it("uses the shipped tool-call folding defaults", function()
        local ChatFolds = require("agentic.ui.chat_folds")
        local policy = ChatFolds.resolve_policy_for_test("execute")

        assert.equal(true, policy.enabled)
        assert.equal(12, policy.min_lines)
    end)

    it("applies per-kind overrides over family defaults", function()
        local ChatFolds = require("agentic.ui.chat_folds")
        local policy = ChatFolds.resolve_policy_for_test("edit", {
            folding = {
                tool_calls = {
                    enabled = true,
                    min_lines = 20,
                    kinds = { edit = { enabled = false } },
                },
            },
        })

        assert.equal(false, policy.enabled)
        assert.equal(20, policy.min_lines)
    end)
end)
```

- [ ] **Step 2: Run the new test file and confirm it fails**

Run: `make test-file FILE=lua/agentic/ui/chat_folds.test.lua`
Expected: FAIL because `agentic.ui.chat_folds` does not exist yet and the config surface is missing.

- [ ] **Step 3: Add the config surface and annotations**

Update `lua/agentic/config_default.lua` with:

```lua
--- @class agentic.UserConfig.ToolCallFoldingKind
--- @field enabled? boolean
--- @field min_lines? integer

--- @class agentic.UserConfig.ToolCallFolding
--- @field enabled boolean
--- @field min_lines integer
--- @field kinds table<string, agentic.UserConfig.ToolCallFoldingKind>

--- @class agentic.UserConfig.Folding
--- @field tool_calls agentic.UserConfig.ToolCallFolding

folding = {
    tool_calls = {
        enabled = true,
        min_lines = 20,
        kinds = {
            fetch = { enabled = true, min_lines = 8 },
            execute = { enabled = true, min_lines = 12 },
            edit = { enabled = false },
        },
    },
},
```

- [ ] **Step 4: Document the user-facing config**

Add a README example showing:

```lua
folding = {
    tool_calls = {
        min_lines = 24,
        kinds = {
            fetch = { min_lines = 8 },
            edit = { enabled = false },
        },
    },
}
```

- [ ] **Step 5: Add the minimal policy resolver skeleton**

Create the first `lua/agentic/ui/chat_folds.lua` export with a test helper or public resolver:

```lua
local ChatFolds = {}

function ChatFolds.resolve_policy_for_test(kind, config)
    local folding = (config or require("agentic.config")).folding.tool_calls
    local kind_cfg = folding.kinds[string.lower(kind)] or {}

    return {
        enabled = kind_cfg.enabled == nil and folding.enabled or kind_cfg.enabled,
        min_lines = kind_cfg.min_lines or folding.min_lines,
    }
end

return ChatFolds
```

- [ ] **Step 6: Re-run the policy tests**

Run: `make test-file FILE=lua/agentic/ui/chat_folds.test.lua`
Expected: PASS for the policy/default scenarios.

- [ ] **Step 7: Run full validation for this Lua change**

Run: `make validate`
Expected: all validation lines exit `0`.

- [ ] **Step 8: Commit**

```bash
git add lua/agentic/config_default.lua README.md lua/agentic/ui/chat_folds.lua lua/agentic/ui/chat_folds.test.lua
git commit -m "feat: add tool-call folding config defaults"
```

### Task 2: Core ChatFolds Body Fold Creation

**Files:**
- Modify: `lua/agentic/ui/chat_folds.lua`
- Modify: `lua/agentic/ui/chat_folds.test.lua`
- Modify: `lua/agentic/ui/message_writer.lua`
- Modify: `lua/agentic/ui/message_writer.test.lua`
- Test: `lua/agentic/ui/chat_folds.test.lua`
- Test: `lua/agentic/ui/message_writer.test.lua`

- [ ] **Step 1: Write failing fold-range and foldtext tests**

Add scenarios to `lua/agentic/ui/chat_folds.test.lua` that:

```lua
it("creates a fold over the body only", function()
    local block = make_tool_call_block("tc-1", "completed", { "a", "b", "c" })
    writer:write_tool_call_block(block)
    folds:sync_tool_call("tc-1")

    local tracker = writer.tool_call_blocks["tc-1"]
    local pos = writer:get_tool_call_rows("tc-1")

    assert.equal(-1, vim.fn.foldclosed(pos.start_row))
    assert.equal(pos.start_row + 1, vim.fn.foldclosed(pos.start_row + 1))
    assert.equal("response hidden (3 lines)", vim.fn.foldtextresult(pos.start_row + 1))
end)
```

Also add a test that diff/edit blocks keep the header visible and footer outside the fold.

Add a separate test that clears and rebuilds the Lua module state while leaving the buffer alive, then verifies `foldtext` still resolves from `vim.b[bufnr].agentic_chat_folds` alone.

- [ ] **Step 2: Run the focused tests and confirm failure**

Run: `make test-file FILE=lua/agentic/ui/chat_folds.test.lua`
Expected: FAIL because `ChatFolds` cannot yet resolve extmark-backed rows or create native folds.

- [ ] **Step 3: Add row helpers to MessageWriter**

In `lua/agentic/ui/message_writer.lua`, add focused helpers such as:

```lua
function MessageWriter:get_tool_call_rows(tool_call_id)
    local tracker = self.tool_call_blocks[tool_call_id]
    if not tracker or not tracker.extmark_id then
        return nil
    end

    local pos = vim.api.nvim_buf_get_extmark_by_id(self.bufnr, NS_TOOL_BLOCKS, tracker.extmark_id, { details = true })
    if not pos or not pos[1] or not pos[3] or not pos[3].end_row then
        return nil
    end

    return {
        start_row = pos[1],
        end_row = pos[3].end_row,
        tracker = tracker,
    }
end
```

- [ ] **Step 4: Implement the first real ChatFolds object**

Expand `lua/agentic/ui/chat_folds.lua` with:

```lua
--- @class agentic.ui.ChatFolds
--- @field bufnr integer
--- @field writer agentic.ui.MessageWriter
--- @field tool_calls table<string, table>
--- @field pending table<string, boolean>

function ChatFolds:new(bufnr, writer)
    local instance = {
        bufnr = bufnr,
        writer = writer,
        tool_calls = {},
        pending = {},
    }
    return setmetatable(instance, self)
end
```

Use this explicit buffer-local foldtext contract:

```lua
vim.b[bufnr].agentic_chat_folds = {
    by_tool_call_id = {
        [tool_call_id] = {
            fold_start = body_start,
            fold_end = body_end,
            body_line_count = body_line_count,
        },
    },
    by_fold_start = {
        [body_start] = {
            tool_call_id = tool_call_id,
            body_line_count = body_line_count,
        },
    },
}
```

And expose a foldtext entrypoint that reads from buffer-local state only:

```lua
function ChatFolds.foldtext()
    local state = vim.b[vim.api.nvim_get_current_buf()].agentic_chat_folds or {}
    local row = vim.v.foldstart - 1
    local fold = state.by_fold_start and state.by_fold_start[row]
    local count = fold and fold.body_line_count or (vim.v.foldend - vim.v.foldstart + 1)
    return string.format("response hidden (%d lines)", count)
end
```

Implement helpers for:
- applying chat-window fold options (`foldmethod=manual`, `foldenable=true`, `foldtext=...`)
- resolving body start/end rows from `MessageWriter:get_tool_call_rows()`
- creating a manual fold over only `body_start..body_end`
- storing foldtext metadata in `vim.b[bufnr].agentic_chat_folds`
- rendering `response hidden (N lines)` fold text from cached metadata

- [ ] **Step 5: Re-run the focused tests**

Run: `make test-file FILE=lua/agentic/ui/chat_folds.test.lua`
Expected: PASS for body-only fold creation and custom fold text.

- [ ] **Step 6: Backfill MessageWriter helper coverage**

Add `lua/agentic/ui/message_writer.test.lua` coverage for `get_tool_call_rows()` returning valid start/end rows after write and after update.

- [ ] **Step 7: Run the MessageWriter tests**

Run: `make test-file FILE=lua/agentic/ui/message_writer.test.lua`
Expected: PASS with the new row helper coverage.

- [ ] **Step 8: Run full validation for this Lua change**

Run: `make validate`
Expected: all validation lines exit `0`.

- [ ] **Step 9: Commit**

```bash
git add lua/agentic/ui/chat_folds.lua lua/agentic/ui/chat_folds.test.lua lua/agentic/ui/message_writer.lua lua/agentic/ui/message_writer.test.lua
git commit -m "feat: add body-only chat fold creation"
```

### Task 3: Live Session Wiring and Terminal-State Folding

**Files:**
- Modify: `lua/agentic/session_manager.lua`
- Modify: `lua/agentic/session_manager.test.lua`
- Modify: `lua/agentic/ui/chat_folds.lua`
- Test: `lua/agentic/session_manager.test.lua`
- Test: `lua/agentic/ui/chat_folds.test.lua`

- [ ] **Step 1: Write failing live-update tests**

Add scenarios covering:

```lua
it("does not auto-fold in-progress tool calls", function()
    writer:write_tool_call_block(make_tool_call_block("tc-1", "in_progress", huge_body))
    folds:sync_tool_call("tc-1")
    assert.equal(-1, vim.fn.foldclosed(body_line))
end)

it("auto-folds completed tool calls at or above threshold", function()
    writer:write_tool_call_block(make_tool_call_block("tc-2", "completed", huge_body))
    folds:sync_tool_call("tc-2")
    assert.equal(body_line, vim.fn.foldclosed(body_line))
end)

it("keeps failed tool calls open", function()
    writer:write_tool_call_block(make_tool_call_block("tc-3", "failed", huge_body))
    folds:sync_tool_call("tc-3")
    assert.equal(-1, vim.fn.foldclosed(body_line))
end)
```

In `lua/agentic/session_manager.test.lua`, add orchestration tests that stub `ChatFolds.sync_tool_call()` and verify it runs after `write_tool_call_block()` and `update_tool_call_block()`.

- [ ] **Step 2: Run the session-manager and fold tests and confirm failure**

Run: `make test-file FILE=lua/agentic/session_manager.test.lua`
Expected: FAIL because `SessionManager` does not instantiate or call `ChatFolds` yet.

Run: `make test-file FILE=lua/agentic/ui/chat_folds.test.lua`
Expected: FAIL because completion-time decisions are not stored yet.

- [ ] **Step 3: Instantiate ChatFolds in SessionManager**

In `lua/agentic/session_manager.lua`, require the module in `SessionManager:new()` and store it:

```lua
local ChatFolds = require("agentic.ui.chat_folds")

self.message_writer = MessageWriter:new(self.widget.buf_nrs.chat)
self.chat_folds = ChatFolds:new(self.widget.buf_nrs.chat, self.message_writer)
```

Add a small helper:

```lua
function SessionManager:_sync_tool_call_folds(tool_call_id)
    self.chat_folds:sync_tool_call(tool_call_id)
end
```

- [ ] **Step 4: Wire live tool-call paths**

After `write_tool_call_block()` in `on_tool_call`, call `self:_sync_tool_call_folds(tool_call.tool_call_id)`.

After `update_tool_call_block()` in `_on_tool_call_update()`, call `self:_sync_tool_call_folds(tool_call_update.tool_call_id)` before `checktime()` so the tracker state is current for both folding and file-mutating reload checks.

- [ ] **Step 5: Implement completion-time decision caching**

In `lua/agentic/ui/chat_folds.lua`, store per-tool-call metadata:

```lua
state[tool_call_id] = {
    kind = tracker.kind,
    enabled = policy.enabled,
    min_lines = policy.min_lines,
    decided = true,
    should_close = body_line_count >= policy.min_lines,
    body_line_count = body_line_count,
}
```

Rules:
- `pending` / `in_progress` -> never auto-close
- `failed` -> never auto-close
- `completed` -> decide once using rendered body line count

- [ ] **Step 6: Re-run the targeted tests**

Run: `make test-file FILE=lua/agentic/ui/chat_folds.test.lua`
Expected: PASS for in-progress/completed/failed behavior.

Run: `make test-file FILE=lua/agentic/session_manager.test.lua`
Expected: PASS for SessionManager orchestration.

- [ ] **Step 7: Run full validation for this Lua change**

Run: `make validate`
Expected: all validation lines exit `0`.

- [ ] **Step 8: Commit**

```bash
git add lua/agentic/session_manager.lua lua/agentic/session_manager.test.lua lua/agentic/ui/chat_folds.lua lua/agentic/ui/chat_folds.test.lua
git commit -m "feat: sync live tool call folding from session manager"
```

### Task 4: Reopen Behavior and Preserved Restored Folds

**Files:**
- Modify: `lua/agentic/ui/chat_folds.lua`
- Modify: `lua/agentic/session_manager.lua`
- Modify: `lua/agentic/session_manager.test.lua`
- Test: `lua/agentic/session_manager.test.lua`

- [ ] **Step 1: Write the failing reopen test in a child Neovim**

Add a child-process scenario to `lua/agentic/session_manager.test.lua` that:

```lua
it("keeps Neovim-restored fold state on widget reopen", function()
    -- create session, write a completed foldable tool call, change its fold state,
    -- hide widget, show widget again, and assert Neovim restores that state
end)
```

Use `tests/helpers/child.lua` and real widget `hide()` / `show()` calls instead of mocking fold restoration. The important assertion is that `BufWinEnter` does not rebuild historical folds and does not disturb the already-restored fold state.

- [ ] **Step 2: Run the failing reopen test**

Run: `make test-file FILE=lua/agentic/session_manager.test.lua`
Expected: FAIL because reopen logic does not yet limit itself to pending-only backfill.

- [ ] **Step 3: Add a pending-only reopened-window path**

In `lua/agentic/session_manager.lua`, register a chat-buffer-local `BufWinEnter` callback after constructing `self.chat_folds`:

```lua
vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = self.widget.buf_nrs.chat,
    callback = function()
        self.chat_folds:backfill_pending_for_current_window()
    end,
})
```

In `lua/agentic/ui/chat_folds.lua`, make `backfill_pending_for_current_window()`:
- apply fold options for the current chat window
- create only folds from the pending set

- [ ] **Step 4: Re-run the reopen test**

Run: `make test-file FILE=lua/agentic/session_manager.test.lua`
Expected: PASS with restored fold state preserved across widget hide/show.

- [ ] **Step 5: Run full validation for this Lua change**

Run: `make validate`
Expected: all validation lines exit `0`.

- [ ] **Step 6: Commit**

```bash
git add lua/agentic/ui/chat_folds.lua lua/agentic/session_manager.lua lua/agentic/session_manager.test.lua
git commit -m "feat: preserve restored tool folds on widget reopen"
```

### Task 5: Hidden-Window Backfill and Replay Wiring

**Files:**
- Modify: `lua/agentic/ui/chat_folds.lua`
- Modify: `lua/agentic/session_manager.lua`
- Modify: `lua/agentic/session_restore.lua`
- Modify: `lua/agentic/session_restore.test.lua`
- Modify: `lua/agentic/session_manager.test.lua`
- Test: `lua/agentic/session_restore.test.lua`
- Test: `lua/agentic/session_manager.test.lua`
- Test: `lua/agentic/ui/chat_folds.test.lua`

- [ ] **Step 1: Write failing hidden-window and replay tests**

Add tests for:

```lua
it("records a completed hidden-time tool call in the pending set", function()
    -- no visible chat window
    writer:write_tool_call_block(make_tool_call_block("tc-hidden", "completed", huge_body))
    folds:sync_tool_call("tc-hidden")
    assert.equal(true, folds.pending["tc-hidden"])
end)

it("replay_messages invokes the tool-call callback after writing a tool block", function()
    local callback_spy = spy.new(function() end)
    SessionRestore.replay_messages(writer, messages, callback_spy --[[@as function]])
    assert.spy(callback_spy).was.called(1)
end)
```

In `session_manager.test.lua`, add a child test that completes a tool call while the widget is hidden and verifies the fold appears on the next `show()` / `BufWinEnter` without rescanning all historical tool calls.

- [ ] **Step 2: Run the focused tests and confirm failure**

Run: `make test-file FILE=lua/agentic/session_restore.test.lua`
Expected: FAIL because replay has no fold callback hook yet.

Run: `make test-file FILE=lua/agentic/session_manager.test.lua`
Expected: FAIL because hidden-time completions are not backfilled yet.

- [ ] **Step 3: Implement pending hidden-time fold tracking**

In `lua/agentic/ui/chat_folds.lua`:
- if a tool call becomes foldable while `bufwinid(self.bufnr) == -1`, mark `pending[tool_call_id] = true`
- on `backfill_pending_for_current_window()`, iterate only the pending ids
- create those missing folds and clear only the consumed ids

- [ ] **Step 4: Add the replay callback contract**

Change `lua/agentic/session_restore.lua` to:

```lua
--- @param on_tool_call_rendered fun(tool_call: agentic.ui.MessageWriter.ToolCallBlock)|nil
function SessionRestore.replay_messages(writer, messages, on_tool_call_rendered)
    ...
    writer:write_tool_call_block(tool_block)
    if on_tool_call_rendered then
        on_tool_call_rendered(tool_block)
    end
end
```

Update `SessionManager:restore_from_history()` to pass:

```lua
function(tool_block)
    self:_sync_tool_call_folds(tool_block.tool_call_id)
end
```

- [ ] **Step 5: Re-run the focused tests**

Run: `make test-file FILE=lua/agentic/session_restore.test.lua`
Expected: PASS for replay callback coverage.

Run: `make test-file FILE=lua/agentic/session_manager.test.lua`
Expected: PASS for hidden-window backfill and pending-only reopen behavior.

- [ ] **Step 6: Run full validation for this Lua change**

Run: `make validate`
Expected: all validation lines exit `0`.

- [ ] **Step 7: Commit**

```bash
git add lua/agentic/ui/chat_folds.lua lua/agentic/session_manager.lua lua/agentic/session_manager.test.lua lua/agentic/session_restore.lua lua/agentic/session_restore.test.lua
git commit -m "feat: backfill hidden-time folds and replay fold sync"
```

### Task 6: Benchmark Harness and Developer Command

**Files:**
- Create: `tests/benchmarks/tool_call_response_folding.lua`
- Modify: `Makefile`
- Test: `tests/benchmarks/tool_call_response_folding.lua`

- [ ] **Step 1: Write the benchmark helper module**

Create `tests/benchmarks/tool_call_response_folding.lua` with an entrypoint:

```lua
local M = {}

function M.run()
    local uv = vim.uv or vim.loop
    local start = uv.hrtime()
    -- build transcript, run repeated fold syncs, print timings
    print(string.format("hot-path-update-ms: %.2f", (uv.hrtime() - start) / 1e6))
    vim.cmd("qall!")
end

return M
```

Benchmark scenarios:
- hot-path sync for one updated tool call inside a long transcript
- hidden completion then `BufWinEnter` backfill for a small pending set
- reopen where existing folds were already restored by Neovim
- worst-case initial visible creation with many completed foldable tool calls

- [ ] **Step 2: Add a dedicated Make target**

Modify `Makefile`:

```make
.PHONY: benchmark-tool-call-folding

benchmark-tool-call-folding:
	$(NVIM) --headless -u tests/init.lua -c "lua require('tests.benchmarks.tool_call_response_folding').run()"
```

- [ ] **Step 3: Run the benchmark helper**

Run: `make benchmark-tool-call-folding`
Expected: prints a small timing report with separate lines for the benchmark scenarios and exits successfully.

- [ ] **Step 4: Tune obvious hot-path regressions before final validation**

If the benchmark output shows reopen or live updates scaling with total transcript size, fix that before continuing. The intended hot path is extmark lookup plus touched-tool metadata only.

- [ ] **Step 5: Run full validation for this Lua change**

Run: `make validate`
Expected: all validation lines exit `0`.

- [ ] **Step 6: Commit**

```bash
git add tests/benchmarks/tool_call_response_folding.lua Makefile
git commit -m "test: add tool-call folding benchmark helper"
```

### Task 7: Final Validation and Manual Verification

**Files:**
- Verify: `lua/agentic/ui/chat_folds.lua`
- Verify: `lua/agentic/session_manager.lua`
- Verify: `lua/agentic/session_restore.lua`
- Verify: `lua/agentic/config_default.lua`
- Verify: `README.md`
- Verify: `tests/benchmarks/tool_call_response_folding.lua`

- [ ] **Step 1: Run the full project validation**

Run: `make validate`
Expected: all lines exit with `0` and total validation succeeds.

- [ ] **Step 2: Run the benchmark again on the finished implementation**

Run: `make benchmark-tool-call-folding`
Expected: timing report completes successfully and shows no obvious transcript-size blowups for the hot-path scenario.

- [ ] **Step 3: Manually verify folding behavior in a local Neovim simulation**

Verify all of the following in a real session:
- completed `fetch` output auto-folds at the lower threshold
- completed `execute` output auto-folds at its threshold
- `edit` stays open by default
- `failed` stays open
- `zo` / `zc` changes survive widget close/reopen for an already existing fold
- hidden-time completed output gets its fold on reopen

- [ ] **Step 4: Update OpenSpec task checklist after implementation**

Mark every completed item in `openspec/changes/add-tool-call-response-folding/tasks.md` as `- [x]` only after the implementation and validation are actually done.

- [ ] **Step 5: Final commit**

```bash
git add lua/agentic/ui/chat_folds.lua lua/agentic/ui/chat_folds.test.lua lua/agentic/ui/message_writer.lua lua/agentic/ui/message_writer.test.lua lua/agentic/session_manager.lua lua/agentic/session_manager.test.lua lua/agentic/session_restore.lua lua/agentic/session_restore.test.lua lua/agentic/config_default.lua README.md tests/benchmarks/tool_call_response_folding.lua Makefile openspec/changes/add-tool-call-response-folding/tasks.md
git commit -m "feat: add tool-call response folding"
```
