# Change: Add folding for tool call responses

## Why

Tool call blocks can dump a large amount of low-signal output into the
chat buffer. Users need native Neovim folds so noisy responses stay easy
to collapse while the tool name and status remain visible.

## What Changes

- Add native folds for tool call response bodies in the chat buffer,
  while keeping the tool header and status lines visible
- Add an `agentic.ui.ChatFolds` module to own tool-response folding
  policy, fold state tracking, and window-local fold creation
- Add a future-friendly `folding.tool_calls` configuration section with
  family-level enablement, a default `min_lines` threshold, and
  per-tool `enabled`/`min_lines` overrides
- Ship opinionated defaults that fold noisy completed `fetch` and
  `execute` responses sooner, while leaving `edit` responses open
- Fold only completed tool calls whose rendered response body meets the
  effective line threshold; keep in-progress and failed tool calls open
- Render folded tool responses with a compact custom fold header text
  that preserves the block marker, such as `│ response hidden (N lines)`
- Respect Neovim's built-in fold restoration when reopening an existing
  chat buffer, and backfill folds only for tool calls that became
  foldable while no chat window was visible by recording them as pending
  until the next chat-window `BufWinEnter`
- Keep the folding subsystem extmark-driven and scoped to affected tool
  call blocks so live updates and widget reopen do not require full chat
  buffer rescans
- Document the configuration keys using normalized tool kinds such as
  `fetch`, `execute`, `edit`, and `read`

## Impact

- Affected specs: new `tool-call-folding` capability
- Affected code:
  - `lua/agentic/ui/chat_folds.lua` - own tool response folding state,
    thresholds, and backfill behavior
  - `lua/agentic/ui/message_writer.lua` - track foldable tool blocks and
    notify `ChatFolds` when tool call blocks are written or updated
  - `lua/agentic/session_manager.lua` - backfill missing folds when the
    chat buffer re-enters a window after hidden updates
  - `lua/agentic/config_default.lua` - add folding configuration
  - `README.md` - document folding behavior and configuration
