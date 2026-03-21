# Tool Call Response Folding Design

## Goal

Implement native Neovim folds for tool call response bodies in the chat buffer,
with configurable auto-fold thresholds, body-only fold ranges, preserved manual
fold toggles, and deferred fold creation for tool calls that become foldable
while the chat window is hidden.

## Context

The existing implementation already tracks rendered tool call blocks in
`MessageWriter` using extmarks stored in `tool_call_blocks[tool_call_id]`.
Those extmarks are the current source of truth for block positions after later
buffer edits.

The feature must stay multi-tab safe. Each tabpage already owns its own
`SessionManager`, `ChatWidget`, and `MessageWriter`, so runtime fold state must
also stay instance-scoped rather than module-scoped.

Neovim folds are window-local. That means a fold can only be materialized when a
chat window exists for the buffer. In this codebase, `ChatWidget:hide()` closes
widget windows and later reopens fresh windows, so window-local folds cannot be
be created while no chat window exists.

For folds that already existed before the chat window was hidden, the design can
rely on Neovim's documented fold restoration behavior for previously edited
buffers. The only gap this feature needs to handle explicitly is tool call
output that becomes foldable while no chat window is visible, because no window
exists at that moment to create the fold in the first place.

## Design Overview

Add a dedicated `agentic.ui.ChatFolds` module and make it the sole owner of tool
response folding behavior.

`MessageWriter` remains responsible for rendering tool call blocks and updating
their extmark-backed ranges. `ChatFolds` consumes that rendered state, resolves
fold policy, tracks per-tool-call folding metadata, and creates or refreshes
body-only native folds when a chat window is available.

`SessionManager` wires the feature together. It instantiates `ChatFolds`, calls
it after live tool call writes and updates, and registers a buffer-local
`BufWinEnter` path to backfill folds that could not be created while the chat
buffer had no visible window.

`SessionRestore` must route replayed tool calls through the same fold-sync path
used by live tool calls so restored history follows the same rules.

## Window Model

Folds are window-local, so `ChatFolds` must operate on concrete chat windows,
not just on the shared buffer.

This feature only needs to handle the normal widget architecture: one chat
window per session/tabpage. Each tabpage has its own dedicated session and chat
buffer, so handling multiple visible windows for the same chat buffer is not a
requirement for this change.

To preserve manual fold toggles in that session-owned chat window, `ChatFolds`
should distinguish between:

- a fold the plugin is creating for the first time
- a fold that already exists and only needs its range refreshed
- a fold that Neovim already restored on widget reopen

That state belongs inside the per-session `ChatFolds` instance, not in
module-level state.

Across widget hide/show, existing folds should be restored by Neovim for the
same edited chat buffer. `ChatFolds` should not try to snapshot and reapply that
state itself. Instead, it should only record pending fold work for tool calls
that became foldable while no chat window was visible.

## Responsibilities

### `agentic.ui.ChatFolds`

`ChatFolds` owns:

- config resolution from `Config.folding.tool_calls`
- per-tool-call fold metadata keyed by `tool_call_id`
- completion-time auto-fold decisions
- pending backfill tracking for hidden-window completions
- fold creation and fold-range refresh for visible chat windows
- custom fold text for tool response folds

Its runtime state is per-instance and tied to a single chat buffer/session.

### `agentic.ui.MessageWriter`

`MessageWriter` continues to own:

- rendered tool call lines
- extmark-backed block tracking in `tool_call_blocks`
- status/footer rendering
- content updates for tool call blocks

It should not own fold policy or fold lifecycle. Instead, it exposes the current
tool call block metadata that `ChatFolds` uses to resolve body ranges from the
existing extmarks.

### `agentic.SessionManager`

`SessionManager` becomes the orchestration point for:

- constructing `ChatFolds`
- calling fold sync after live tool call writes and updates
- registering a chat-buffer-local `BufWinEnter` callback for backfill

This keeps fold lifecycle integration close to the other session-scoped UI state
without pushing more window logic into `MessageWriter`.

### `agentic.SessionRestore`

`SessionRestore.replay_messages()` should replay tool calls through the same
fold-sync entry point used for live messages, instead of bypassing folding
entirely. That keeps replayed completed tool calls consistent with live ones.

To make that explicit with the current API shape, replay should gain an optional
callback hook, for example `on_tool_call_rendered(tool_call_block)`, invoked
immediately after `writer:write_tool_call_block(tool_block)`. `SessionManager`
can pass a callback that routes replayed tool calls into `ChatFolds` using the
same sync method used for live tool calls.

## Fold Policy

Add a new top-level config section:

```lua
folding = {
    tool_calls = {
        enabled = true,
        min_lines = 20,
        kinds = {
            fetch = {
                enabled = true,
                min_lines = 8,
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
```

Config precedence:

1. `folding.tool_calls.enabled` gates automatic tool call folding globally
2. `folding.tool_calls.kinds[kind].enabled` overrides the family enabled value
3. `folding.tool_calls.kinds[kind].min_lines` overrides
   `folding.tool_calls.min_lines`
4. automatic closing happens only when status becomes `completed`
5. `failed` and non-terminal tool calls stay open by default

The `kinds` table uses normalized config keys derived from the raw
`tool_call.kind` value by lowercasing it before lookup.

Examples:

- `fetch` -> `fetch`
- `execute` -> `execute`
- `edit` -> `edit`
- `read` -> `read`
- `WebSearch` -> `websearch`
- `SubAgent` -> `subagent`
- `SlashCommand` -> `slashcommand`
- `Skill` -> `skill`

This keeps common tool names simple while still defining deterministic behavior
for mixed-case ACP tool kinds already present in the codebase.

## Fold Range and Text

The fold covers only the rendered response body lines for a tool call block.
The header line stays visible above the fold and the trailing footer/status line
stays outside the fold.

The chat window uses a custom fold text for these folds:

`response hidden (N lines)`

`N` is the rendered body line count contained in the fold. The tool header stays
visible immediately above it, so the fold text stays generic and compact.

## Window Setup

When `ChatFolds` first sees a visible chat window, it should apply the required
window-local fold options for that chat window:

- `foldmethod=manual`
- `foldenable=true`
- `foldtext` set to the tool-response fold text expression owned by
  `ChatFolds`

The feature should not store runtime session state in those options. Any dynamic
data needed to compute fold text or creation behavior must come from the
instance-owned fold metadata and the current buffer/window state.

Use buffer-local storage for fold text metadata, for example
`vim.b[bufnr].agentic_chat_folds`, so the `foldtext` expression can resolve the
current folded tool call without introducing module-level per-session runtime
state.

The design intentionally leaves unrelated fold presentation settings, such as
`foldcolumn`, under user control.

## Runtime Flow

### Live tool call write

1. `SessionManager` receives `on_tool_call`
2. `MessageWriter:write_tool_call_block()` renders the block and stores its
   extmark
3. `SessionManager` asks `ChatFolds` to sync that tool call id
4. `ChatFolds` stores initial fold policy metadata
5. If the tool call is not yet completed, no auto-close decision is applied

### Live tool call update

1. `SessionManager:_on_tool_call_update()` updates the rendered block
2. `SessionManager` asks `ChatFolds` to sync the same tool call id
3. `ChatFolds` resolves the current extmark-backed block range
4. If the tool call has now reached `completed`, `ChatFolds` stores the
   completion-time default state based on rendered body line count and effective
   threshold
5. If a chat window is visible, `ChatFolds` creates or refreshes the fold
6. If no chat window is visible and the tool call should auto-fold,
   `ChatFolds` records the tool call id in its pending set for later backfill

### Replay

1. `SessionRestore.replay_messages()` replays stored tool calls
2. After each replayed tool call render, `SessionRestore` invokes the optional
   replay callback supplied by `SessionManager`
3. Replayed tool calls go through the same fold-sync path after rendering
4. Completed replayed tool calls receive the same completion-time policy logic
   as live tool calls

### Widget reopen

1. The chat buffer enters a window again
2. By the time the chat-buffer `BufWinEnter` callback runs, Neovim may already
   have restored folds that previously existed for that edited chat buffer,
   including manual open/closed state
3. The buffer-local `BufWinEnter` callback calls `ChatFolds` window
   materialization logic for that specific window
4. `ChatFolds` ensures window-local fold options are configured
5. `ChatFolds` consumes only its pending set for tool calls that became
   foldable while no chat window was visible and creates those missing folds
6. When creating one of those pending folds for the first time, `ChatFolds`
   applies the stored completion-time default state

## Manual Toggle Preservation

The plugin should apply closed/open state only when it first creates a fold in a
given window.

On widget hide/show for the same existing chat buffer, `ChatFolds` should not
override Neovim's restored fold state for already-existing folds. It should only
backfill folds that could not be created earlier because no chat window was
visible.

Because auto-folding is decided when the tool call reaches `completed`, and that
terminal update already includes the final rendered body used for the decision,
the design does not need to guard against post-completion fold-state
recomputation.

## Data Model

Each tracked tool call in `ChatFolds` should store enough metadata to avoid
recomputing unrelated state on every update. At minimum:

- `tool_call_id`
- `kind`
- whether folding is enabled for the tool kind
- effective `min_lines`
- whether a completion-time decision has already been recorded
- the stored default closed/open state decided at completion time
- rendered body line count used for fold text
- whether the tool call is pending hidden-window backfill

This metadata lives inside the `ChatFolds` instance, not in module-level state.

## Files

- Create `lua/agentic/ui/chat_folds.lua`
- Modify `lua/agentic/session_manager.lua`
- Modify `lua/agentic/session_restore.lua`
- Modify `lua/agentic/config_default.lua`
- Modify `README.md`
- Add or extend tests in:
  - `lua/agentic/ui/chat_folds.test.lua`
  - `lua/agentic/ui/message_writer.test.lua`
  - `lua/agentic/session_manager.test.lua`

## Error Handling

- Invalid or missing tool call tracking data should fail soft with debug logging
  rather than breaking chat rendering
- If a tool call no longer has a resolvable extmark range, fold sync should skip
  that block
- If no chat window is visible, visible-window fold creation should be skipped
  and deferred through the pending set when appropriate
- Non-foldable tool calls should clear any stale pending state

## Testing Strategy

Add tests for:

- body-only fold creation while keeping header/footer visible
- custom fold text rendering
- family-level and per-kind config precedence
- in-progress tool calls staying open while streaming
- completed tool calls folding only at or above the effective threshold
- failed tool calls staying open by default
- hidden-window completion recording pending fold work
- widget close/reopen preserving Neovim-restored fold state for an already
  existing fold
- `BufWinEnter` consuming only the pending set for tool calls that became
  foldable while no chat window was visible
- replayed completed tool calls following the same stored completion-time logic

All Lua-file changes finish with `make validate`.

## Performance

This feature should stay responsive even with long chat transcripts containing
many historical tool call blocks.

The implementation should avoid expensive work in the hot path:

- no full-buffer rescans on normal live tool call updates
- no full historical tool-call rebuild on widget reopen
- extmark-backed range lookup for the touched tool call block only
- per-tool-call fold metadata cached and reused after completion-time decisions

The hidden-window reopen path should consume only the pending set of tool calls
that became foldable while no chat window was visible.

## Benchmarking

Add a lightweight benchmark helper for this feature, separate from normal
correctness tests, and measure timing with `vim.loop.hrtime()` or
`vim.uv.hrtime()`.

Initial benchmark scenarios should cover:

- hot-path sync of one updated tool call inside a long transcript
- hidden completion followed by widget reopen where only a small pending set is
  backfilled
- widget reopen with previously existing folds already restored by Neovim,
  verifying reopen work stays small
- worst-case initial visible creation with many completed foldable tool calls

The benchmark should report timings and help catch regressions during
development, but it should not start as a hard CI timing gate. Exact thresholds
can be set later after measuring the first implementation on real project data.

## Trade-offs

- Introducing `ChatFolds` adds a new module, but it prevents `MessageWriter`
  from accumulating more window-local behavior and keeps the feature testable
- Native folds are window-local, so fold creation needs a visible-window path
  plus hidden-time backfill logic
- Reusing extmark-backed block tracking avoids full transcript rescans and fits
  the current rendering model
