defmodule Pixir.Delegate do
  @moduledoc """
  Agent-facing Delegate CLI surface for Codex/GPT callers.

  Delegate is the scaffold for `pixir delegate`: a CLI-first service facade over Pixir's
  existing Subagents and Workflows runtime. It is deliberately attached-first in v1:
  callers enter Pixir once, receive one final result envelope, and do not poll by
  shelling out per Subagent or per wait tick.

  The first runtime path is an attached Subagents runner. Service mode can also use a
  manually started workspace-local daemon for cross-invocation `start/status/cancel`.
  Workflow execution and streaming attach remain behind explicit TODO anchors so future
  work can grow without changing the I/O contract.

  TODO(delegate-runner): extend attached execution from Subagents to Workflows without
  adding a second orchestration runtime.

  TODO(delegate-async): grow streaming `attach` and workflow runtime from the current
  durable status/attach/cancel snapshots and daemon-backed Subagent owner path.

  TODO(delegate-handle): replace the reversible `delegate_id` wrapper with a durable
  owner/index once service mode can keep a resident BEAM runtime alive across CLI
  invocations.

  TODO(delegate-progress): stream optional progress and heartbeat snapshots on stderr
  JSONL while keeping canonical Log events bounded to real lifecycle decisions.

  TODO(delegate-artifacts): materialize large child evidence, diagnostics, and patches
  under an output directory and reference them from the final JSON envelope.
  """

  alias Pixir.Delegate.CLIContract

  @doc "Run the Delegate CLI contract parser and dry-run planner."
  @spec run_cli([String.t()], keyword()) :: CLIContract.result()
  def run_cli(argv, opts \\ []), do: CLIContract.run(argv, opts)
end
