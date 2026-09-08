defmodule Pixir.WorkspaceStrategy do
  @moduledoc """
  Workspace Strategy vocabulary for Subagents and Workflow steps.

  A Workspace Strategy describes how a child sees files and whether writes can mutate
  the parent workspace. Subagents execute `shared` and `isolated`, and may opt in to
  `virtual_overlay` with operator-owned read-set context. Workflow steps also support
  explicit virtual commands. Each invocation imports host files afresh and returns an
  unapplied `virtual_diff`; only commands within that invocation share virtual edits.
  Canonical Logs/artifacts persist on disk; no persistent Session scratch is implied.
  """

  alias Pixir.Tool

  @runtime_modes ~w(shared isolated)
  @modeled_modes @runtime_modes ++ ~w(virtual_overlay)

  @doc "Normalize a runtime workspace mode or return a structured error."
  @spec normalize_runtime_mode(term(), String.t(), map()) ::
          {:ok, String.t()} | {:error, map()}
  @spec normalize_runtime_mode(term(), String.t(), map(), keyword()) ::
          {:ok, String.t()} | {:error, map()}
  def normalize_runtime_mode(mode, scope, details \\ %{}, opts \\ []) when is_binary(scope) do
    normalized = normalize_mode(mode)
    supported_modes = Keyword.get(opts, :supported_modes, @runtime_modes)

    if normalized in supported_modes do
      {:ok, normalized}
    else
      {:error, unsupported_runtime_mode_error(normalized, scope, details, supported_modes)}
    end
  end

  @doc "Return compact Delegation Context fields for a modeled workspace mode."
  @spec delegation_context(term(), map()) :: {:ok, map()} | {:error, map()}
  def delegation_context(mode, metadata \\ %{}) do
    mode = normalize_mode(mode)

    case mode do
      "shared" ->
        {:ok,
         %{
           "workspace_fidelity" => "real_parent_workspace",
           "read_boundary" => "parent_workspace",
           "write_semantics" => "parent_workspace_subject_to_permission_mode",
           "parent_workspace_mutation" => "possible_with_write_permissions"
         }}

      "isolated" ->
        {:ok,
         %{
           "workspace_fidelity" => "bounded_physical_snapshot",
           "read_boundary" => "snapshot_copy",
           "write_semantics" => "snapshot_only_parent_workspace_not_mutated",
           "parent_workspace_mutation" => "none"
         }}

      "virtual_overlay" ->
        {:ok,
         %{
           "workspace_fidelity" => "virtual_shell_no_host_binaries",
           "read_boundary" => "imported_read_set_only",
           "write_semantics" => "virtual_only_parent_workspace_not_mutated",
           "parent_workspace_mutation" => "none",
           "output_artifact" => "virtual_diff",
           "apply_status" => "not_applied",
           "requires_explicit_apply" => true,
           "virtual_command_boundary" => "beam_native_virtual_shell_only",
           "virtual_edit_lifetime" => "one_invocation_only_next_call_reimports_host_files",
           "durable_evidence" => "canonical_logs_and_artifacts_persist_on_disk",
           "delivery_selection" =>
             "latest_successful_explicit_mark_else_legacy_latest_successful_artifact",
           "fidelity_caveats" => virtual_overlay_caveats(metadata)
         }}

      _ ->
        {:error,
         Tool.error(:invalid_args, "workspace_mode cannot be described", %{
           "workspace_mode" => mode || inspect(mode),
           "modeled_modes" => @modeled_modes
         })}
    end
  end

  defp unsupported_runtime_mode_error(mode, scope, details, supported_modes) do
    future_modes = @modeled_modes -- supported_modes

    details =
      details
      |> stringify_keys()
      |> Map.merge(%{
        "workspace_mode" => mode || inspect(mode),
        "supported_modes" => supported_modes,
        "future_modes" => future_modes,
        "next_actions" => unsupported_mode_next_actions(future_modes)
      })
      |> maybe_put_future_mode_status(future_modes)

    Tool.error(
      :invalid_args,
      "#{scope} workspace_mode must be one of #{Enum.join(supported_modes, ", ")}",
      details
    )
  end

  defp maybe_put_future_mode_status(details, []), do: details

  defp maybe_put_future_mode_status(details, future_modes) do
    if "virtual_overlay" in future_modes do
      Map.put(
        details,
        "future_mode_status",
        "virtual_overlay requires operator-owned read_set context and is not enabled on this surface without it"
      )
    else
      details
    end
  end

  defp unsupported_mode_next_actions([]), do: ["use_supported_workspace_mode"]

  defp unsupported_mode_next_actions(future_modes) do
    if "virtual_overlay" in future_modes do
      [
        "use_workspace_mode_shared_or_isolated",
        "supply_operator_virtual_overlay_read_set_context"
      ]
    else
      ["use_supported_workspace_mode"]
    end
  end

  defp virtual_overlay_caveats(_metadata) do
    [
      "Only files imported from read_set are visible.",
      "Commands within ONE run_virtual_commands call share virtual edits; the next call reimports host files. No persistent Session scratch is retained.",
      "Canonical Logs/artifacts persist on disk even though virtual edits are in memory.",
      "Virtual writes do not mutate the parent workspace.",
      "Real host binaries are unavailable: mix, git, node, package managers, compilers, tests, /bin/bash, /bin/sh, and arbitrary host commands.",
      "Network and custom host-side commands are unavailable by default.",
      "Set deliverable: true on the producing call to select its successful artifact; later unmarked reads do not replace it. A later explicit mark replaces it, including an empty diff. Without a mark, the latest successful artifact is selected.",
      "Return changes as a virtual_diff artifact; applying it requires a later explicit apply step."
    ]
  end

  defp normalize_mode(mode) when is_binary(mode), do: mode
  defp normalize_mode(nil), do: nil
  defp normalize_mode(mode) when is_atom(mode), do: Atom.to_string(mode)
  defp normalize_mode(mode), do: inspect(mode)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_keys(_other), do: %{}
end
