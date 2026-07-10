defmodule Pixir.RecoveryCommands do
  @moduledoc """
  Copyable recovery command builders for failed or ambiguous Sessions.

  These commands are operator-facing guidance, not execution. `Turn` records them as
  durable failure evidence, while presenters such as `CLI` render the same templates
  on stdout/stderr so downstream orchestrators and humans see one consistent recovery
  contract.
  """

  alias Pixir.Tool

  @safe_resume_prompt "Continue from the latest incomplete turn. Inspect the Log first, avoid duplicating completed writes, and report what you resumed."

  @virtual_overlay_notes [
    "The in-memory overlay filesystem no longer exists; each run_virtual_commands call re-imports a fresh read_set.",
    "Inspect the child Log before regenerating virtual commands.",
    "Reusing or applying a preserved virtual_diff is a separate explicit operator decision through apply_virtual_diff."
  ]

  @write_capable_resume_notes [
    "The child Log is the source of truth; the resumed turn continues with context intact.",
    "Inspect the child Log for already-applied writes before resuming so work is not duplicated.",
    "A stale writer lease fails closed on purpose; inspect with pixir diagnose and never force-release it as a default."
  ]

  @doc "Build the standard diagnose/resume commands for a Session id."
  @spec commands(String.t()) :: {:ok, %{required(String.t()) => String.t()}} | {:error, map()}
  def commands(session_id) when is_binary(session_id) and byte_size(session_id) > 0 do
    {:ok,
     %{
       "diagnose_command" => "pixir diagnose session #{session_id} --json",
       "resume_command" => ~s(pixir resume #{session_id} "#{@safe_resume_prompt}")
     }}
  end

  def commands(_session_id) do
    {:error,
     Tool.error(:invalid_args, "session id must be a non-empty string", %{
       "next_actions" => ["pass_a_valid_session_id"]
     })}
  end

  @doc "Build strategy-aware recovery guidance without changing the standard commands."
  @spec commands(String.t(), keyword()) ::
          {:ok, %{required(String.t()) => String.t() | [String.t()]}} | {:error, map()}
  def commands(session_id, opts) when is_list(opts) do
    with {:ok, commands} <- commands(session_id) do
      notes =
        []
        |> append_notes(
          Keyword.get(opts, :workspace_mode) in ["virtual_overlay", :virtual_overlay],
          @virtual_overlay_notes
        )
        |> append_notes(Keyword.get(opts, :write_capable) == true, @write_capable_resume_notes)

      if notes == [] do
        {:ok, commands}
      else
        {:ok, Map.put(commands, "notes", notes)}
      end
    end
  end

  defp append_notes(notes, true, extra_notes), do: notes ++ extra_notes
  defp append_notes(notes, false, _extra_notes), do: notes
end
