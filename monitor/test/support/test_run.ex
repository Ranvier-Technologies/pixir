defmodule PixirMonitor.TestRun do
  @moduledoc false

  # Unique per ExUnit invocation (not per test, not per VM integer counter).
  # Concurrent `mix test` processes on one host must not share tmp prefixes,
  # profile globs, or LogWatcher default workspaces. `System.unique_integer/1`
  # restarts low on every node, so it is not enough by itself (#467 family;
  # issue #555).

  @env "PIXIR_MONITOR_TEST_RUN"
  @id_pattern ~r/\A[a-z0-9][a-z0-9-]{0,62}\z/

  @doc "Installs the per-run key into the process environment. Safe to call twice."
  def install! do
    id = persisted_id()
    System.put_env(@env, id)
    id
  end

  @doc "Per-run key for this ExUnit invocation."
  def id, do: persisted_id()

  @doc "Environment variable that Node harnesses read for the same key."
  def env_name, do: @env

  @doc """
  Returns `prefix-<run-id>-<unique>` under `System.tmp_dir!/0`.

  The run id keeps a concurrent suite's `unique_integer` from landing in the
  same directory name; the unique suffix keeps tests inside this suite apart.
  """
  def tmp(prefix) when is_binary(prefix) and prefix != "" do
    Path.join(System.tmp_dir!(), "#{prefix}-#{id()}-#{System.unique_integer([:positive])}")
  end

  @doc "Wildcard over this run's profiles of `family` (e.g. `pixir-monitor-browser`)."
  def profile_glob(family) when is_binary(family) and family != "" do
    Path.join(System.tmp_dir!(), profile_prefix(family) <> "*")
  end

  @doc "Directory-name prefix for this run's profiles of `family`."
  def profile_prefix(family) when is_binary(family) and family != "" do
    "#{family}-#{id()}-"
  end

  defp persisted_id do
    case System.get_env(@env) do
      id when is_binary(id) and id != "" ->
        if id =~ @id_pattern do
          id
        else
          raise ArgumentError,
                "#{@env} must be a lowercase token of 1..63 [a-z0-9-] characters, got: #{inspect(id)}"
        end

      _ ->
        generate_id()
    end
  end

  defp generate_id do
    random = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    "#{:os.getpid()}-#{random}"
  end
end
