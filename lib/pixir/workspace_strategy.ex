defmodule Pixir.WorkspaceStrategy do
  @moduledoc """
  Workspace Strategy vocabulary for Subagents and Workflow steps.

  A Workspace Strategy describes how a child sees files and whether writes can mutate
  the parent workspace. Subagents currently execute `shared` and `isolated`; Workflow
  steps may also opt in to `virtual_overlay`, which runs explicit virtual commands over
  an imported read set and returns a `virtual_diff` without mutating the parent.
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
        "virtual_overlay is modeled in Delegation Context but is not runtime-enabled yet on this surface"
      )
    else
      details
    end
  end

  defp unsupported_mode_next_actions([]), do: ["use_supported_workspace_mode"]

  defp unsupported_mode_next_actions(future_modes) do
    if "virtual_overlay" in future_modes do
      ["use_workspace_mode_shared_or_isolated", "wait_for_virtual_overlay_runtime_slice_121"]
    else
      ["use_supported_workspace_mode"]
    end
  end

  defp virtual_overlay_caveats(_metadata) do
    [
      "Only files imported from read_set are visible.",
      "Virtual writes do not mutate the parent workspace.",
      "Real host binaries are unavailable: mix, git, node, package managers, compilers, tests, /bin/bash, /bin/sh, and arbitrary host commands.",
      "Network and custom host-side commands are unavailable by default.",
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
