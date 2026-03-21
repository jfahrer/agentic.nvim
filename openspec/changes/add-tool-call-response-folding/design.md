# Design: Tool call response folding

## Context

`MessageWriter` renders each tool call as a header line, zero or more
body lines, and a trailing footer/blank line in the chat buffer.
Existing tool call blocks are already tracked with extmarks in
`tool_call_blocks[tool_call_id]`, so the system can resolve the current
rows for a block even after later buffer edits.

Neovim folds are window-local, while the chat buffer can be hidden and
shown again in a new window. Neovim's `fold-behavior` docs state that
when editing a buffer that has been edited before, the last used folding
settings are used again, manual folds are restored, and manually
opened/closed folds are restored from the window where the buffer was
edited last.

For this widget, that means `hide()`/`show()` reusing the same chat
buffer should benefit from Neovim's built-in restoration for folds that
already existed before the chat window closed. The remaining gap is tool
call output that is written while no chat window is visible, because no
window exists at that moment to create the fold in the first place.

Any design for tool call folds therefore needs both:

- buffer-side metadata that survives while the chat buffer exists
- window-side fold creation only for blocks whose folds could not be
  materialized earlier

## Goals

- Use standard Neovim folds for tool call responses
- Keep the tool header and status visible when folded
- Let users configure family-level and per-tool folding thresholds
- Keep behavior multi-tab safe with no module-level runtime state
- Avoid overriding a manual fold toggle during later tool call updates
- Keep folding logic out of `MessageWriter` by isolating it in
  `agentic.ui.ChatFolds`

## Non-goals

- Persisting a user's temporary fold toggles across full buffer
  destruction and recreation
- Folding non-tool chat content
- Building a custom virtual-text collapse UI

## Decisions

### Fold only the response body

The fold range covers only the tool response body rows for a block. The
header line remains visible so users can still see which tool ran, and
the trailing footer/status line remains outside the fold.

This matches the request to fold the response content rather than hide
the entire tool call card.

To avoid Neovim's default fold text showing a noisy first output line,
the chat window should use a custom fold text for tool-response folds:

`response hidden (N lines)`

This keeps the fold text compact and generic because the actual tool
header remains visible immediately above the folded body.

### Namespace folding config by response family

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

This keeps the current change scoped to tool calls, while leaving room
to add future siblings such as `folding.thoughts` or
`folding.agent_messages` without reshaping the config later.

Config keys inside `folding.tool_calls.kinds` use the normalized tool
kinds already stored in `tool_call_block.kind`, such as `fetch`,
`execute`, `edit`, and `read`.

The proposed shipped defaults are:

- `folding.tool_calls.enabled = true`
- `folding.tool_calls.min_lines = 20`
- `folding.tool_calls.kinds.fetch = { enabled = true, min_lines = 8 }`
- `folding.tool_calls.kinds.execute = { enabled = true, min_lines = 12 }`
- `folding.tool_calls.kinds.edit = { enabled = false }`

These defaults keep short, useful output visible, fold obviously noisy
web and shell output more aggressively, and avoid collapsing diffs or
edit previews by default.

### Store the initial fold policy per tool call block

When the first `tool_call` arrives, `ChatFolds` stores the resolved
family-level and per-kind policy needed to make the final folding
decision later. The actual default open/closed state is decided only
when the tool call reaches `completed`, using the final rendered body
line count.

This avoids jarring mid-stream auto-folding while output is still being
written.

The precedence rules are:

1. `folding.tool_calls.enabled` gates automatic tool-call folding
2. `folding.tool_calls.kinds[kind].enabled` overrides the family value
   when present
3. `folding.tool_calls.kinds[kind].min_lines` overrides
   `folding.tool_calls.min_lines` when present
4. auto-folding runs only for `completed` tool calls
5. `failed` and non-terminal tool calls stay open by default

Once the completion-time decision is stored on the tracked block, later
`tool_call_update`s and fold refreshes reuse that stored default instead
of recomputing it. This keeps a visible fold from snapping back to a new
state after a user manually opens or closes it.

### Put fold ownership in `ChatFolds`

Create a dedicated `agentic.ui.ChatFolds` module that owns:

- tool-call fold policy resolution from `Config.folding.tool_calls`
- per-tool-call fold metadata and completion-time default state
- fold creation and fold-range refresh for a visible chat window
- tracking of tool calls that need fold creation later because no chat
  window was visible

`MessageWriter` should stay focused on rendering buffer lines and
extmarks. After writing or updating a tool call block, it should notify
`ChatFolds` with the tool call ID and let that module decide whether a
fold must be created, refreshed, deferred, or skipped.

This keeps fold behavior cohesive and prevents more window-management
logic from spreading through `MessageWriter`.

### Reuse restored folds and backfill only missing ones

Use the existing tool block extmark as the source of truth for the
current block rows. `ChatFolds` should use that extmark-backed range to
manage body-only folds.

For widget close/reopen, Neovim restores the fold state for previously
existing folds automatically, so the fold module does not need to probe
whether a reopened window already has an expected restored fold.
Instead, it should only materialize folds for tool calls that were
recorded as pending while no chat window was visible.

That pending-fold record is the intended mechanism, not just an
implementation detail. When a tool call becomes foldable while hidden,
`ChatFolds` should enqueue that tool call ID for later backfill instead
of trying to infer missing work by rescanning historical blocks when the
chat window reappears.

That means the fold module should:

- resolves the current block range from the extmark
- computes the body-only fold rows
- creates or refreshes the native fold immediately when a chat window is
  visible during live updates
- records pending fold creation when a foldable tool call completes
  while no chat window is visible
- creates those pending folds on the next chat-buffer `BufWinEnter`
- applies the stored completion-time open/closed state only when the
  fold is first created by the plugin

This keeps the solution aligned with current extmark-based block
tracking, avoids extra markers in the buffer, and avoids fighting
Neovim's own fold restoration.

### Backfill folds after hidden updates

Because tool call output can continue streaming while the widget is
hidden, some completed tool calls may become foldable while the chat
buffer has no visible window. `SessionManager` should register a
buffer-local `BufWinEnter` hook for the chat buffer that asks
`ChatFolds` to backfill missing folds whenever the chat buffer gets
a window again. That hook should consume the pending-fold records that
`ChatFolds` accumulated while hidden.

This stays tab-safe because each tabpage already has its own
`SessionManager`, `ChatWidget`, and chat buffer.

### Performance characteristics

This feature should stay cheap enough to run on every tool call update
without making long chat transcripts sluggish.

The implementation should therefore avoid full-buffer or full-history
rescans in the hot path:

- visible tool call updates should touch only the updated tool call
  block, using its extmark-backed range
- completion-time fold decisions should be stored once per tool call and
  reused, not recomputed from unrelated blocks
- widget reopen should backfill only tool calls recorded as pending while
  hidden, not iterate through every historical tool call block

These constraints fit naturally with a dedicated `ChatFolds` module,
because it can keep the pending-fold queue and per-block fold metadata in
one place.

## Risks / trade-offs

- Re-syncing folds on every relevant tool update adds some extra window
  work, but tool call counts are low and extmark lookups are already part
  of tool block maintenance.
- Manual fold toggles should survive widget close/reopen for previously
  existing folds because Neovim restores them for an already-edited
  buffer. The implementation must avoid overwriting that restored state
  while still creating folds that were never created because the buffer
  was hidden at completion time.

## Open Questions

- None identified.
