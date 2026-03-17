# Thought Highlighting and Collapsible Chat Blocks Design

## Goal

Add first-class rendering for `thought` responses and make both thoughts and tool
calls collapsible in the chat buffer, while keeping the behavior configurable and
safe for the plugin's multi-tab architecture.

## Current State

- `agent_thought_chunk` content is appended as plain text in the chat buffer.
- Tool calls already render as tracked blocks with extmarks, status highlights,
  and decorative borders.
- The chat buffer uses the `AgenticChat` filetype mapped to markdown, so most
  non-tool-call coloring comes from markdown/tree-sitter content highlighting.
- There is no dedicated highlight group for thought text and no fold model for
  either thoughts or tool calls.

## User-Facing Outcome

- Expanded thought text gets a dedicated highlight group: `AgenticThought`.
- Thought blocks can start expanded or collapsed based on config.
- Tool calls can start expanded or collapsed based on a default config plus
  per-tool-kind overrides.
- Collapsed blocks use real Neovim folds, so built-in fold motions and commands
  continue to work.

## Non-Goals

- Per-message font families. Neovim highlights can style text, but they do not
  provide different font families for only part of a normal buffer.
- Persisting manual fold open/closed state across editor restarts.
- Changing ACP payloads or provider-specific tool-call normalization.

## Recommended Approach

Use a dedicated fold manager module plus the existing extmark-based rendering.

### Why this approach

- It keeps the rendered chat text real, so markdown rendering and normal cursor
  behavior still work.
- It reuses the plugin's existing extmark pattern for tool-call tracking.
- It keeps fold state window-local, which matches Neovim's model and this
  plugin's tab-local widget instances.
- It avoids custom virtual replacement UI that would fight streaming updates.

## Design

### 1. Add a fold manager module

Create a new module, `lua/agentic/ui/chat_folds.lua`, responsible for:

- configuring fold options for chat windows
- storing buffer-local metadata for collapsible blocks
- resolving initial collapsed/expanded state from user config
- providing `foldexpr` and `foldtext`
- reapplying configured fold state when a chat window is recreated

This module should not keep per-tab runtime state in module-level tables. Any
block registry should live in buffer-local or tab-local storage, such as
`vim.b[bufnr]`.

### 2. Represent collapsible ranges as block metadata

Each collapsible region should be tracked as a logical block with:

- stable `id`
- `type = "thought" | "tool_call"`
- `start_row`
- `end_row`
- `kind` for tool calls
- summary text for fold rendering
- desired initial state (`expanded` or `collapsed`)

Tool calls already have a range extmark and stable `tool_call_id`, so they can
reuse that identity. Thoughts need new runtime tracking in `MessageWriter` so a
stream of `agent_thought_chunk` updates becomes a single tracked block.

### 3. Turn thoughts into first-class render blocks

Today thoughts are only raw text chunks. The writer should instead:

- create a thought block when a thought stream starts
- extend the block as new thought chunks arrive
- finalize the block when the stream changes back to an agent message or the
  response completes
- apply `AgenticThought` highlighting across the thought block while expanded

This keeps thought rendering close to tool-call rendering without forcing both
paths into the same data model.

### 4. Use real folds for collapse

The chat window should use fold settings driven by the fold manager.

- `foldmethod=expr`
- `foldexpr` consults the buffer-local block registry
- `foldtext` renders a concise summary line for collapsed thoughts and tool
  calls

The fold range should cover the entire logical block. For tool calls that means
header, body/diff content, and footer line. That keeps the implementation
simple and lets `foldtext` show kind, argument, status, and body size in a
single summary line.

### 5. Use highlighted foldtext summaries

Neovim allows `foldtext` to return a list that is rendered like overlay virtual
text. That should be used to make collapsed summaries informative.

Examples:

- thought: `[thought] reasoning hidden (12 lines)` with `AgenticThought`
- tool call: `[read] /path/to/file.lua - completed` with status highlight

This gives a clear collapsed representation without inventing a separate UI.

### 6. Add configuration for default fold behavior

Add a top-level config group for fold behavior, for example:

```lua
folds = {
    thoughts = {
        initial_state = "expanded",
    },
    tool_calls = {
        initial_state = "expanded",
        by_kind = {
            read = "collapsed",
            search = "collapsed",
            edit = "expanded",
            execute = "expanded",
        },
    },
}
```

Rules:

- `thoughts.initial_state` applies to all thought blocks
- `tool_calls.initial_state` is the fallback for tool calls
- `tool_calls.by_kind[kind]` overrides the fallback when present
- accepted values should stay small and explicit: `expanded` or `collapsed`

### 7. Add a dedicated thought highlight group

Add `AgenticThought` to `Theme.HL_GROUPS`, define a default highlight in
`Theme.setup()`, and document it in the README's customization table.

This is the user-facing styling hook for thought text. No separate "font"
option is needed, because Neovim highlight groups already provide the correct
customization surface.

## Data Flow

### Thought chunks

1. `SessionManager` receives `agent_thought_chunk`
2. `MessageWriter` writes or extends the active thought block
3. `MessageWriter` updates the thought block's tracked range and highlight
4. `chat_folds` updates the buffer-local fold registry for that block
5. If the configured initial state is `collapsed`, the chat window closes that
   fold once the block exists in the visible window

### Tool calls

1. `MessageWriter:write_tool_call_block()` renders the block
2. The existing tool-call extmark remains the source of truth for the range
3. `chat_folds` stores a fold block entry keyed by `tool_call_id`
4. Updates refresh the block range and summary metadata as status/body changes
5. The configured initial state comes from `tool_calls.by_kind[kind]` or the
   tool-call default

### Window recreation

When the widget is hidden and shown again, the chat window is recreated. Since
fold state is window-local, `ChatWidget` should call fold setup for the chat
window each time the window is opened so the current block registry can be used
to rebuild the initial fold state.

## Error Handling and Edge Cases

- Streaming thought chunks must continue appending correctly while folded ranges
  are updated.
- Switching from thought to agent text must finalize the thought block cleanly.
- Session restore should rebuild thought/tool-call fold metadata by replaying
  messages through existing writer paths.
- Diff tool calls should remain immutable after first render, matching the
  current tool-call update rules.
- Fold setup must be buffer/window scoped and never rely on module-level shared
  state for per-tab data.

## Testing Strategy

### Unit tests

- add a new `lua/agentic/ui/chat_folds.test.lua`
- verify fold registry updates for thought and tool-call blocks
- verify config resolution for `by_kind` overrides
- verify fold text summaries for thought and tool-call blocks

### Existing module tests

- extend `lua/agentic/ui/message_writer.test.lua` to cover thought block
  creation, highlighting, and tracked-range updates
- extend `lua/agentic/ui/chat_widget.test.lua` to cover fold option setup for
  the chat window
- extend `lua/agentic/session_restore.test.lua` only if restore wiring needs
  explicit assertions beyond replay behavior already covered indirectly

### Validation

After implementation, run `make validate` because Lua file changes require full
format, type, lint, and test validation in this project.

## Files Expected to Change

- `lua/agentic/config_default.lua`
- `lua/agentic/theme.lua`
- `lua/agentic/ui/message_writer.lua`
- `lua/agentic/ui/chat_widget.lua`
- `lua/agentic/ui/chat_folds.lua` (new)
- `lua/agentic/ui/message_writer.test.lua`
- `lua/agentic/ui/chat_widget.test.lua`
- `lua/agentic/ui/chat_folds.test.lua` (new)
- `README.md`

## Open Trade-Offs Chosen Deliberately

- Do not persist manual fold state across restarts for the first version.
- Do not add new custom keymaps for folding in the first version; built-in fold
  commands like `za`, `zc`, `zo`, `zM`, and `zR` should work once folds exist.
- Keep the config declarative instead of callback-based so behavior is easy to
  document, validate, and test.
