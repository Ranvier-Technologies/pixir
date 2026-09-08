defmodule Pixir.BuildInfo do
  @moduledoc """
  Artifact identity captured at compilation, plus attribution of the serving VM.

  Diagnostics never inspect Git or the caller's working directory. Unknown source
  facts stay explicit for archives, missing Git, or a bounded probe failure. The
  fingerprint hashes source names and contents, not timestamps, and exports neither.
  It is source provenance, not a reproducible-build or artifact-signing guarantee.
  """

  @source (fn ->
             try do
               root = Path.expand("../..", __DIR__)

               unknown = %{
                 "source_revision" => "unknown",
                 "source_dirty" => "unknown",
                 "source_fingerprint" => "unknown"
               }

               # Use Git's own worktree resolution; never walk up from runtime CWD.
               # Bound each local command to 2 seconds and 4 MiB of output. Disable
               # optional locks and fsmonitor hooks; no diff/filter/hook is executed.
               git = fn executable, args ->
                 port =
                   Port.open({:spawn_executable, executable}, [
                     :binary,
                     :exit_status,
                     :use_stdio,
                     :stderr_to_stdout,
                     args: [
                       "--no-optional-locks",
                       "-c",
                       "core.fsmonitor=false",
                       "-C",
                       root | args
                     ],
                     env:
                       Enum.map(
                         ~w(GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR),
                         &{String.to_charlist(&1), false}
                       )
                   ])

                 deadline = System.monotonic_time(:millisecond) + 2_000

                 collect = fn collect, chunks, size ->
                   receive do
                     {^port, {:data, data}} when size + byte_size(data) <= 4_194_304 ->
                       collect.(collect, [data | chunks], size + byte_size(data))

                     {^port, {:exit_status, 0}} ->
                       {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

                     {^port, {:exit_status, _}} ->
                       :error

                     {^port, {:data, _}} ->
                       Port.close(port)
                       :error
                   after
                     max(deadline - System.monotonic_time(:millisecond), 0) ->
                       Port.close(port)
                       :error
                   end
                 end

                 collect.(collect, [], 0)
               end

               fingerprint = fn paths ->
                 paths = paths |> String.split(<<0>>, trim: true) |> Enum.uniq() |> Enum.sort()

                 if length(paths) <= 10_000 do
                   Enum.reduce_while(paths, {:crypto.hash_init(:sha256), 0}, fn path,
                                                                                {hash, size} ->
                     full = Path.join(root, path)

                     content =
                       case File.lstat(full) do
                         {:ok, %{type: :regular, size: bytes}} when size + bytes <= 33_554_432 ->
                           File.read(full)

                         {:ok, %{type: :symlink}} ->
                           case File.read_link(full) do
                             {:ok, target} -> {:ok, "symlink:" <> target}
                             _ -> :error
                           end

                         {:error, :enoent} ->
                           {:ok, "deleted"}

                         _ ->
                           :error
                       end

                     case content do
                       {:ok, bytes} when size + byte_size(bytes) <= 33_554_432 ->
                         input = :erlang.term_to_binary({path, bytes})
                         {:cont, {:crypto.hash_update(hash, input), size + byte_size(bytes)}}

                       _ ->
                         {:halt, :unknown}
                     end
                   end)
                   |> case do
                     {hash, _} -> hash |> :crypto.hash_final() |> Base.encode16(case: :lower)
                     :unknown -> "unknown"
                   end
                 else
                   "unknown"
                 end
               end

               with true <- File.exists?(Path.join(root, ".git")),
                    executable when is_binary(executable) <- System.find_executable("git"),
                    {:ok, revision} <- git.(executable, ["rev-parse", "--verify", "HEAD"]),
                    revision = String.trim(revision),
                    true <- Regex.match?(~r/\A[0-9a-f]{40,64}\z/, revision),
                    {:ok, status} <-
                      git.(executable, ["status", "--porcelain=v1", "--untracked-files=all"]),
                    {:ok, paths} <-
                      git.(executable, [
                        "ls-files",
                        "--cached",
                        "--others",
                        "--exclude-standard",
                        "-z"
                      ]) do
                 %{
                   "source_revision" => revision,
                   "source_dirty" => status != "",
                   "source_fingerprint" => fingerprint.(paths)
                 }
               else
                 _ -> unknown
               end
             rescue
               _ ->
                 %{
                   "source_revision" => "unknown",
                   "source_dirty" => "unknown",
                   "source_fingerprint" => "unknown"
                 }
             end
           end).()

  @build_info Map.merge(@source, %{
                "version" => Mix.Project.config()[:version],
                "compile_elixir" => System.version(),
                "compile_otp" => System.otp_release()
              })

  @doc "Return compiled source/build facts and the current runtime's versions and OS pid."
  @spec get() :: {:ok, map()}
  def get do
    {:ok,
     Map.merge(@build_info, %{
       "runtime_elixir" => System.version(),
       "runtime_otp" => System.otp_release(),
       "os_pid" => System.pid()
     })}
  end

  # Deliberately rebuild this small module on every Mix compilation. Tracking only
  # HEAD or dirty/clean misses dirty-to-dirty changes and worktree ref updates.
  # This compiler predicate does no source I/O and is never used by diagnostics.
  @doc false
  def __mix_recompile__?, do: true
end
