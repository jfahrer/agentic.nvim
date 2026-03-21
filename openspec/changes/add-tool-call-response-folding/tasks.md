# Tasks: Tool call response folding

## 1. Add configuration and docs

- [x] 1.1 Add `folding.tool_calls.enabled`,
  `folding.tool_calls.min_lines`, and nested
  `folding.tool_calls.kinds.<kind>.enabled` /
  `folding.tool_calls.kinds.<kind>.min_lines` to
  `lua/agentic/config_default.lua`
- [x] 1.2 Set the documented defaults: family `min_lines = 20`,
  `fetch.min_lines = 8`, `execute.min_lines = 12`, and
  `edit.enabled = false`
- [x] 1.3 Document the new config in `README.md`, including an example
  that folds completed `fetch` output at a lower threshold while leaving
  `edit` open

## 2. Add `agentic.ui.ChatFolds`

- [x] 2.1 RED: Add tests for creating a native fold over a tool call's
  response body while keeping the header visible and rendering the
  custom fold text
- [x] 2.2 GREEN: Create `lua/agentic/ui/chat_folds.lua` to own
  per-tool-call fold metadata, policy resolution, and fold creation
- [x] 2.3 RED: Add tests for family-level and per-tool threshold
  precedence in `ChatFolds`
- [x] 2.4 GREEN: Resolve the effective `enabled` and `min_lines` policy
  from `Config.folding.tool_calls` inside `ChatFolds`
- [x] 2.5 RED: Add tests that a user-opened or user-closed fold keeps
  that state when the same tool call receives later updates in the same
  visible window
- [x] 2.6 GREEN: Refresh fold ranges for visible chat windows without
  overriding the current window's fold state
- [x] 2.7 GREEN: Apply custom chat-window fold text for tool response
  folds: `response hidden (N lines)`
- [x] 2.8 GREEN: Keep fold metadata and any pending-fold queue inside
  `ChatFolds` so hot-path updates avoid rescanning full chat history

## 3. Wire `MessageWriter` and `SessionManager` to `ChatFolds`

- [x] 3.1 RED: Add integration tests that in-progress tool calls stay
  open even when their current rendered body exceeds the threshold
- [x] 3.2 GREEN: Notify `ChatFolds` from `MessageWriter` when tool call
  blocks are written or updated, using extmark-backed block rows as the
  source of truth
- [x] 3.3 RED: Add integration tests that completed tool calls fold only
  when their rendered body line count is greater than or equal to the
  effective threshold
- [x] 3.4 GREEN: Defer the auto-fold decision until status becomes
  `completed` and base it on rendered body lines
- [x] 3.5 RED: Add integration tests that failed tool calls remain open
  by default
- [x] 3.6 GREEN: Skip automatic folding for `failed` tool calls

## 4. Preserve restored folds and backfill missing ones

- [x] 4.1 RED: Add tests that widget close/reopen preserves Neovim's
  restored fold state for an already-folded tool call block
- [x] 4.2 GREEN: Avoid recreating folds on widget reopen when Neovim has
  already restored them for the existing chat buffer
- [x] 4.3 RED: Add tests that a tool call completing while the chat
  buffer has no visible window gets its fold created on the next
  `BufWinEnter`
- [x] 4.4 GREEN: Record foldable hidden-time tool calls in a pending set
  inside `ChatFolds` and consume that set from a chat-buffer-local
  `BufWinEnter` path in `SessionManager`
- [x] 4.5 RED: Add tests that replayed completed tool calls receive the
  stored completion-time fold state during session restoration
- [x] 4.6 GREEN: Apply fold syncing consistently to replayed and hidden
  live tool call blocks
- [x] 4.7 RED: Add tests that widget reopen backfills only pending folds
  instead of rescanning all historical tool call blocks

## 5. Validation

- [x] 5.1 Run `make validate`
- [x] 5.2 Verify `zc`/`zo` behavior for completed `fetch`, `execute`, and
  `edit` tool calls in a local Neovim chat-buffer simulation
- [x] 5.3 Verify folding remains responsive with a long chat transcript
  containing many historical tool call blocks
