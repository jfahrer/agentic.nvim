# Thought Highlighting and Collapsible Chat Blocks Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add dedicated thought highlighting plus configurable collapsible thought and tool-call blocks in the chat buffer.

**Architecture:** Introduce a small fold manager module that owns buffer-local collapsible block metadata and chat window fold setup. Extend `MessageWriter` to track thought blocks, reuse existing tool-call extmarks for tool-call folds, and expose user configuration through `config_default.lua`, `theme.lua`, and `README.md`.

**Tech Stack:** Neovim Lua, extmarks, foldexpr/foldtext, mini.test, StyLua, LuaLS, Selene

---

### Task 1: Add configuration and theme surface area

**Files:**
- Modify: `lua/agentic/config_default.lua`
- Modify: `lua/agentic/theme.lua`
- Modify: `README.md`
- Test: `lua/agentic/ui/chat_folds.test.lua`

**Step 1: Write the failing test**

Add a new test file skeleton at `lua/agentic/ui/chat_folds.test.lua` that checks config resolution:

```lua
local assert = require("tests.helpers.assert")
local Config = require("agentic.config")

describe("agentic.ui.ChatFolds", function()
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

        assert.equal("expanded", ChatFolds.get_initial_state("tool_call", "edit"))
        assert.equal("collapsed", ChatFolds.get_initial_state("tool_call", "read"))
        assert.equal("expanded", ChatFolds.get_initial_state("thought", nil))
    end)
end)
```

**Step 2: Run test to verify it fails**

Run: `make test-file FILE=lua/agentic/ui/chat_folds.test.lua`
Expected: FAIL because `agentic.ui.chat_folds` does not exist and `Config.folds` is undefined.

**Step 3: Write minimal implementation**

Add config defaults in `lua/agentic/config_default.lua`:

```lua
folds = {
    thoughts = {
        initial_state = "expanded",
    },
    tool_calls = {
        initial_state = "expanded",
        by_kind = {},
    },
},
```

Add theme surface in `lua/agentic/theme.lua`:

```lua
Theme.HL_GROUPS.THOUGHT = "AgenticThought"
```

and define a default highlight in `Theme.setup()`.

Document both the new fold config and the new `AgenticThought` highlight in `README.md`.

**Step 4: Run test to verify it passes**

Run: `make test-file FILE=lua/agentic/ui/chat_folds.test.lua`
Expected: PASS once config access and module loading work.

**Step 5: Commit**

```bash
git add lua/agentic/config_default.lua lua/agentic/theme.lua README.md lua/agentic/ui/chat_folds.test.lua
git commit -m "feat: add fold config and thought highlight surface"
```

### Task 2: Create the fold manager module

**Files:**
- Create: `lua/agentic/ui/chat_folds.lua`
- Test: `lua/agentic/ui/chat_folds.test.lua`

**Step 1: Write the failing test**

Extend `lua/agentic/ui/chat_folds.test.lua` with registry and summary behavior:

```lua
it("stores and returns collapsible blocks per buffer", function()
    local bufnr = vim.api.nvim_create_buf(false, true)

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
```

Add a fold text test:

```lua
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
    assert.truthy(chunks[1])
end)
```

**Step 2: Run test to verify it fails**

Run: `make test-file FILE=lua/agentic/ui/chat_folds.test.lua`
Expected: FAIL because the module functions are not implemented.

**Step 3: Write minimal implementation**

Create `lua/agentic/ui/chat_folds.lua` with:

```lua
local Config = require("agentic.config")
local Theme = require("agentic.theme")

local M = {}

local function get_store(bufnr)
    vim.b[bufnr].agentic_chat_folds = vim.b[bufnr].agentic_chat_folds or {}
    return vim.b[bufnr].agentic_chat_folds
end

function M.upsert_block(bufnr, id, block)
    local store = get_store(bufnr)
    store[id] = vim.tbl_extend("force", store[id] or {}, block)
end

function M.get_blocks(bufnr)
    local store = get_store(bufnr)
    local items = {}
    for id, block in pairs(store) do
        block.id = id
        table.insert(items, block)
    end
    table.sort(items, function(a, b)
        return a.start_row < b.start_row
    end)
    return items
end
```

Also implement:

- `get_initial_state(block_type, kind)`
- `build_foldtext(block)`
- helpers to set chat window fold options
- a line-to-fold-level resolver used by `foldexpr`

**Step 4: Run test to verify it passes**

Run: `make test-file FILE=lua/agentic/ui/chat_folds.test.lua`
Expected: PASS for config resolution, registry management, and fold text summary tests.

**Step 5: Commit**

```bash
git add lua/agentic/ui/chat_folds.lua lua/agentic/ui/chat_folds.test.lua
git commit -m "feat: add chat fold manager"
```

### Task 3: Track and highlight thought blocks in MessageWriter

**Files:**
- Modify: `lua/agentic/ui/message_writer.lua`
- Test: `lua/agentic/ui/message_writer.test.lua`

**Step 1: Write the failing test**

Add a test that streams thought chunks and expects tracked thought metadata:

```lua
it("tracks a streamed thought block as one collapsible region", function()
    writer:write_message_chunk({
        sessionUpdate = "agent_thought_chunk",
        content = { type = "text", text = "first line" },
    })

    writer:write_message_chunk({
        sessionUpdate = "agent_thought_chunk",
        content = { type = "text", text = "\nsecond line" },
    })

    assert.is_not_nil(writer._thought_block)
    assert.equal("agent_thought_chunk", writer._last_message_type)
end)
```

Add another test to verify thought highlighting extmarks exist in the thought range.

**Step 2: Run test to verify it fails**

Run: `make test-file FILE=lua/agentic/ui/message_writer.test.lua`
Expected: FAIL because thought blocks are not tracked and no dedicated thought highlight exists.

**Step 3: Write minimal implementation**

In `lua/agentic/ui/message_writer.lua`:

- add runtime fields for the active thought block and thought highlight namespace usage
- on the first `agent_thought_chunk`, record the start row before appending text
- after each chunk append, update the tracked end row
- when switching from thought to normal agent text, finalize the thought block and register it with `ChatFolds`

The internal shape should look like:

```lua
local thought_block = {
    id = "thought:" .. tostring(vim.uv.hrtime()),
    start_row = start_row,
    end_row = end_row,
    summary = "reasoning hidden",
    initial_state = ChatFolds.get_initial_state("thought", nil),
}
```

Apply the `AgenticThought` highlight to the block range using extmarks.

**Step 4: Run test to verify it passes**

Run: `make test-file FILE=lua/agentic/ui/message_writer.test.lua`
Expected: PASS for thought block tracking and highlighting.

**Step 5: Commit**

```bash
git add lua/agentic/ui/message_writer.lua lua/agentic/ui/message_writer.test.lua
git commit -m "feat: track and highlight thought blocks"
```

### Task 4: Register tool-call folds and keep them updated

**Files:**
- Modify: `lua/agentic/ui/message_writer.lua`
- Test: `lua/agentic/ui/message_writer.test.lua`

**Step 1: Write the failing test**

Add a test that writes a tool call and checks fold metadata:

```lua
it("registers tool calls as collapsible blocks with per-kind state", function()
    writer:write_tool_call_block({
        tool_call_id = "tool-1",
        status = "pending",
        kind = "read",
        argument = "lua/agentic/ui/message_writer.lua",
        body = { "Read 10 lines" },
    })

    local ChatFolds = require("agentic.ui.chat_folds")
    local blocks = ChatFolds.get_blocks(bufnr)
    assert.equal("tool_call", blocks[1].type)
    assert.equal("read", blocks[1].kind)
end)
```

Add an update test that changes the status from `pending` to `completed` and expects the stored summary/status to refresh.

**Step 2: Run test to verify it fails**

Run: `make test-file FILE=lua/agentic/ui/message_writer.test.lua`
Expected: FAIL because tool calls are not yet registered with the fold manager.

**Step 3: Write minimal implementation**

In `write_tool_call_block()` and `update_tool_call_block()`:

- call `ChatFolds.upsert_block()` after the extmark range is known
- pass `type = "tool_call"`, `kind`, `status`, `start_row`, `end_row`, summary text, and resolved initial state
- refresh the stored range whenever a tool call rerenders

Use the existing tool-call extmark as the source of truth for the block range.

**Step 4: Run test to verify it passes**

Run: `make test-file FILE=lua/agentic/ui/message_writer.test.lua`
Expected: PASS for tool-call fold registration and update coverage.

**Step 5: Commit**

```bash
git add lua/agentic/ui/message_writer.lua lua/agentic/ui/message_writer.test.lua
git commit -m "feat: register tool call folds"
```

### Task 5: Configure the chat window to use foldexpr and foldtext

**Files:**
- Modify: `lua/agentic/ui/chat_widget.lua`
- Modify: `lua/agentic/ui/chat_widget.test.lua`
- Modify: `lua/agentic/ui/chat_folds.lua`

**Step 1: Write the failing test**

Add a chat widget test that opens the widget and checks the chat window fold options:

```lua
it("configures folds for the chat window", function()
    widget:show()

    local winid = widget.win_nrs.chat
    assert.equal("expr", vim.wo[winid].foldmethod)
    assert.truthy(vim.wo[winid].foldexpr:find("chat_folds"))
    assert.truthy(vim.wo[winid].foldtext:find("chat_folds"))
end)
```

**Step 2: Run test to verify it fails**

Run: `make test-file FILE=lua/agentic/ui/chat_widget.test.lua`
Expected: FAIL because the chat window does not configure fold options.

**Step 3: Write minimal implementation**

In `lua/agentic/ui/chat_widget.lua`, once the chat window exists, call a helper such as:

```lua
local ChatFolds = require("agentic.ui.chat_folds")
ChatFolds.setup_window(self.buf_nrs.chat, self.win_nrs.chat)
```

In `lua/agentic/ui/chat_folds.lua`, implement:

- `setup_window(bufnr, winid)`
- a `foldexpr()` entry point callable from the window option
- a `foldtext()` entry point callable from the window option
- reapplication of configured initial folded state when a new chat window is created

Do not add custom fold keymaps in this task.

**Step 4: Run test to verify it passes**

Run: `make test-file FILE=lua/agentic/ui/chat_widget.test.lua`
Expected: PASS for fold option setup.

**Step 5: Commit**

```bash
git add lua/agentic/ui/chat_widget.lua lua/agentic/ui/chat_widget.test.lua lua/agentic/ui/chat_folds.lua
git commit -m "feat: enable folds in chat window"
```

### Task 6: Finish docs and run full validation

**Files:**
- Modify: `README.md`
- Modify: `lua/agentic/config_default.lua`
- Modify: `lua/agentic/theme.lua`
- Modify: `lua/agentic/ui/chat_folds.lua`
- Modify: `lua/agentic/ui/chat_widget.lua`
- Modify: `lua/agentic/ui/message_writer.lua`
- Modify: `lua/agentic/ui/chat_folds.test.lua`
- Modify: `lua/agentic/ui/chat_widget.test.lua`
- Modify: `lua/agentic/ui/message_writer.test.lua`

**Step 1: Write the failing test**

If any edge case is still missing, add the last failing tests now. Priorities:

- session restore rebuilds fold metadata by replaying messages
- collapsed foldtext shows status for completed tool calls
- thought-to-agent transition finalizes a thought block exactly once

**Step 2: Run test to verify it fails**

Run the narrowest applicable command, for example:

`make test-file FILE=lua/agentic/ui/message_writer.test.lua`

Expected: FAIL for the uncovered edge case.

**Step 3: Write minimal implementation**

Make the smallest code change needed to satisfy the edge case. Keep behavior aligned with the design:

- no module-level per-tab state
- no ANSI escape rendering
- no callback-based fold config in this version

**Step 4: Run test to verify it passes**

Run:

`make validate`

Expected: output like

```text
format: 0 (took 1s) - log: .local/agentic_format_output.log
luals: 0 (took 2s) - log: .local/agentic_luals_output.log
selene: 0 (took 0s) - log: .local/agentic_selene_output.log
test: 0 (took 1s) - log: .local/agentic_test_output.log
Total: 4s
```

If any line shows a non-zero exit code, read only the matching log file, fix the issue, and rerun `make validate`.

**Step 5: Commit**

```bash
git add README.md lua/agentic/config_default.lua lua/agentic/theme.lua lua/agentic/ui/chat_folds.lua lua/agentic/ui/chat_widget.lua lua/agentic/ui/message_writer.lua lua/agentic/ui/chat_folds.test.lua lua/agentic/ui/chat_widget.test.lua lua/agentic/ui/message_writer.test.lua
git commit -m "feat: add collapsible thought and tool call blocks"
```
