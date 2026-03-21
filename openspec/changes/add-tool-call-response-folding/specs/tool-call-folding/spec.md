## ADDED Requirements

### Requirement: Tool call responses SHALL use native Neovim folds

The chat buffer SHALL expose tool call response bodies as standard
Neovim folds so users can use native fold commands on tool output while
the tool header and status remain visible.

#### Scenario: Create a fold for a new tool call response

- **WHEN** a tool call block with response body lines is written to the
  chat buffer
- **AND** tool call folding is enabled
- **THEN** the response body lines are placed inside a native Neovim
  fold
- **AND** the tool header line remains visible outside the fold
- **AND** the folded body uses the custom fold text
  `response hidden (N lines)`

#### Scenario: Tool call update expands the fold range

- **WHEN** an existing tool call block receives an update with more
  response body lines
- **AND** that block already has a tool response fold
- **THEN** the fold range expands to cover the new body lines

#### Scenario: In-progress tool call stays open while streaming

- **WHEN** an in-progress tool call response grows beyond the configured
  folding threshold
- **THEN** the system does not auto-fold it yet
- **AND** the response remains open while output is still streaming

#### Scenario: Manual fold toggle survives later updates

- **WHEN** a user manually opens or closes a tool response fold in the
  current chat window
- **AND** the same tool call later receives an update
- **THEN** the fold range is refreshed as needed
- **AND** the current window keeps the user's open or closed state

### Requirement: Tool call fold defaults SHALL be configurable

The system SHALL provide a `folding.tool_calls` configuration section
with `enabled`, `min_lines`, and `kinds` fields. Each
`folding.tool_calls.kinds.<kind>` entry SHALL support `enabled` and
`min_lines` overrides.

The `kinds` table SHALL use the normalized tool kinds rendered by the
chat buffer, such as `fetch`, `execute`, `edit`, and `read`.

The top-level `folding` table SHALL be structured so additional
response families can be added later without changing the shape of the
existing `tool_calls` configuration.

#### Scenario: Default configuration uses documented thresholds

- **WHEN** the user does not override `folding.tool_calls`
- **THEN** `folding.tool_calls.enabled = true`
- **AND** `folding.tool_calls.min_lines = 20`
- **AND** `folding.tool_calls.kinds.fetch.enabled = true`
- **AND** `folding.tool_calls.kinds.fetch.min_lines = 8`
- **AND** `folding.tool_calls.kinds.execute.enabled = true`
- **AND** `folding.tool_calls.kinds.execute.min_lines = 12`
- **AND** `folding.tool_calls.kinds.edit.enabled = false`

#### Scenario: Per-tool override beats the global default

- **WHEN** `folding.tool_calls.enabled = true`
- **AND** `folding.tool_calls.min_lines = 20`
- **AND** `folding.tool_calls.kinds.edit.enabled = false`
- **AND** `folding.tool_calls.kinds.fetch.enabled = true`
- **AND** `folding.tool_calls.kinds.fetch.min_lines = 8`
- **THEN** completed `edit` tool call responses do not auto-fold
- **AND** completed `fetch` tool call responses fold at 8 rendered body
  lines instead of 20

#### Scenario: Folding can be disabled entirely

- **WHEN** `folding.tool_calls.enabled = false`
- **THEN** the system does not create automatic tool response folds

### Requirement: Tool call responses SHALL auto-fold only on completion

Automatic tool call folding SHALL be decided only when a tool call
reaches `completed`, using the final rendered body line count and the
effective `min_lines` threshold.

#### Scenario: Completed tool call meets the threshold

- **WHEN** a tool call reaches `completed`
- **AND** automatic folding is enabled for its tool kind
- **AND** its rendered response body line count is greater than or equal
  to the effective `min_lines` threshold
- **THEN** the tool response fold is created in the closed state by
  default

#### Scenario: Completed tool call does not meet the threshold

- **WHEN** a tool call reaches `completed`
- **AND** automatic folding is enabled for its tool kind
- **AND** its rendered response body line count is less than the
  effective `min_lines` threshold
- **THEN** the tool response remains open by default

#### Scenario: Failed tool call stays open by default

- **WHEN** a tool call reaches `failed`
- **AND** its rendered response body line count is greater than or equal
  to the effective `min_lines` threshold
- **THEN** the tool response fold is created in the open state by default
- **AND** the user can manually close or reopen that fold with normal
  Neovim fold commands

### Requirement: Tool call folding SHALL respect restored folds and backfill missing ones

The system SHALL preserve Neovim's restored fold state on widget
close/reopen for an already-edited chat buffer and SHALL create tool
response folds only for blocks that became foldable while no chat
window was visible.

The folding subsystem SHALL record those hidden-time foldable tool calls
as pending and SHALL consume that pending set on the next chat-window
`BufWinEnter`.

#### Scenario: Reopen the chat widget after a manual fold toggle

- **WHEN** a user manually opens or closes a tool response fold
- **AND** the chat widget closes its window and is later reopened for
  the same tabpage session
- **THEN** the reopened chat window uses Neovim's restored fold state
- **AND** the system does not force that fold back to its default state

#### Scenario: Tool call completes while the chat widget is hidden

- **WHEN** a tool call reaches `completed`
- **AND** its response meets the effective auto-fold threshold
- **AND** the chat buffer has no visible chat window at that moment
- **THEN** the folding subsystem records that tool call as pending
- **AND** the fold is created when the chat widget is shown again
- **AND** the fold uses the stored completion-time default state

#### Scenario: Replay tool calls during session restore

- **WHEN** session history replay renders a stored tool call block into
  the chat buffer
- **THEN** the same tool call folding rules apply as for a live tool
  call

### Requirement: Tool call folding SHALL scope work to relevant blocks

The folding subsystem SHALL use tracked tool call metadata and extmark-
backed block ranges so live updates and widget reopen do not require
rescanning unrelated chat history.

The folding subsystem SHALL treat the pending hidden-time fold set as
the source of truth for widget-reopen backfill work.

#### Scenario: Visible tool call update

- **WHEN** a visible tool call block receives an update
- **THEN** fold maintenance uses that tool call's tracked block range
- **AND** the system does not need to rescan unrelated tool call blocks

#### Scenario: Widget reopen after hidden updates

- **WHEN** the chat widget is reopened after hidden tool call updates
- **THEN** fold backfill runs only for tool calls recorded as pending
- **AND** the system does not need to rebuild fold state for unrelated
  historical tool call blocks
