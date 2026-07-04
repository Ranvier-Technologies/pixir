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
end
