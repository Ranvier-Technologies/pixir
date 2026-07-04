defmodule Pixir do
  @moduledoc """
  Pixir — an OTP-native, terminal-first coding agent.

  Pixir is a local-first runtime built around a small spine:
  `Pixir.Session` -> `Pixir.Turn` -> `Pixir.Provider` -> `Pixir.Tools`.
  The append-only `Pixir.Log` is the source of truth, and front-ends observe
  canonical and ephemeral facts through `Pixir.Events`.

  The public architecture is intentionally split across focused modules:

  - `Pixir.Conversation` is the UI-agnostic multi-turn driver.
  - `Pixir.ACP` modules present the same runtime over ACP/JSON-RPC stdio.
  - `Pixir.Skills` loads progressive-disclosure instruction packages.
  - `Pixir.Subagents` supervises delegated child Sessions.
  - `Pixir.Workflows` runs deterministic dependency graphs over Subagents.
  - `Pixir.Delegate` scaffolds the Codex/GPT-first delegate CLI contract.
  - `Pixir.SessionTree` projects read-only Session/Subagent trees from Logs.
  - `Pixir.Compaction` records durable History checkpoints for bounded replay.

  See `CONTEXT.md` for vocabulary and `docs/adr/` for accepted architecture
  decisions.
  """

  # Read the version from the compiled app spec (set from mix.exs) so there is a
  # single source of truth and the CLI can never drift from the released version.
  @version Mix.Project.config()[:version]

  @doc "Pixir version (from `mix.exs`)."
  @spec version() :: String.t()
  def version, do: @version
end
