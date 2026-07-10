defmodule Pixir.Tools.RunVirtualCommands do
  @moduledoc """
  Model-visible Tool for one-shot commands in a bounded virtual overlay.

  The operator supplies the imported read set and limits through Turn context. Model
  arguments contain commands only. Commands run in a BEAM-native in-memory shell with
  no host binaries or network, never mutate the parent workspace, and return an
  unapplied `virtual_diff` artifact.
  """

  use Pixir.Tool

  alias Pixir.{Tool, VirtualOverlay}

  @impl Pixir.Tool
  def __tool__ do
    %{
      name: "run_virtual_commands",
      description:
        "Run commands in a bounded in-memory shell imported from an operator-owned read set. No host binaries or network are available, the parent workspace is never mutated, and the returned virtual_diff is not applied.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "commands" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Virtual shell commands to execute in order"
          }
        },
        "required" => ["commands"],
        "additionalProperties" => false
      }
    }
  end

  @impl Pixir.Tool
  def execute(%{"commands" => commands} = args, context) do
    with :ok <- validate_only_commands(args),
         :ok <- validate_commands(commands),
         {:ok, virtual_overlay} <- virtual_overlay_context(context),
         {:ok, artifact} <-
           VirtualOverlay.run(
             context.workspace,
             %{
               "read_set" => virtual_overlay.read_set,
               "commands" => commands,
               "limits" => virtual_overlay.limits
             },
             []
           ) do
      {:ok,
       %{
         "output" => summary(artifact),
         "virtual_diff" => artifact
       }}
    end
  end

  def execute(_args, _context),
    do: {:error, Tool.error(:invalid_args, "run_virtual_commands requires commands", %{})}

  @impl Pixir.Tool
  def dry_run(%{"commands" => commands} = args, context) do
    with :ok <- validate_only_commands(args),
         :ok <- validate_commands(commands),
         {:ok, virtual_overlay} <- virtual_overlay_context(context) do
      {:ok,
       %{
         "dry_run" => true,
         "tool" => "run_virtual_commands",
         "command_count" => length(commands),
         "effective_read_set_size" => length(virtual_overlay.read_set),
         "limits" => virtual_overlay.limits
       }}
    end
  end

  def dry_run(_args, _context),
    do: {:error, Tool.error(:invalid_args, "run_virtual_commands requires commands", %{})}

  defp validate_only_commands(args) do
    case Map.keys(args) -- ["commands"] do
      [] ->
        :ok

      unknown ->
        {:error,
         Tool.error(:invalid_args, "run_virtual_commands accepts commands only", %{
           "unknown" => Enum.sort(unknown)
         })}
    end
  end

  defp validate_commands(commands) when is_list(commands) do
    if Enum.all?(commands, &is_binary/1) do
      :ok
    else
      {:error,
       Tool.error(:invalid_args, "run_virtual_commands commands must be strings", %{
         "field" => "commands"
       })}
    end
  end

  defp validate_commands(_commands) do
    {:error,
     Tool.error(:invalid_args, "run_virtual_commands commands must be a list", %{
       "field" => "commands"
     })}
  end

  defp virtual_overlay_context(%{virtual_overlay: virtual_overlay})
       when is_map(virtual_overlay) do
    read_set = Map.get(virtual_overlay, :read_set)

    if is_list(read_set) and read_set != [] and Enum.all?(read_set, &non_empty_string?/1) do
      {:ok,
       %{
         read_set: read_set,
         limits: Map.get(virtual_overlay, :limits)
       }}
    else
      missing_virtual_overlay_context()
    end
  end

  defp virtual_overlay_context(_context), do: missing_virtual_overlay_context()

  defp missing_virtual_overlay_context do
    {:error,
     Tool.error(
       :invalid_args,
       "run_virtual_commands requires operator virtual overlay context",
       %{
         "required_context" => ["virtual_overlay.read_set"]
       }
     )}
  end

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""

  # The model-facing output must carry real feedback (command output and the
  # produced diffs), not only counts: the full artifact rides the durable
  # tool_result but never reaches the model channel, so this string is the
  # child's only way to see what its commands did. Every piece is already
  # bounded by the overlay limits; Tool.truncate is the channel ceiling.
  defp summary(artifact) do
    import = Map.get(artifact, "import", %{})
    changes = Map.get(artifact, "changes", [])
    artifact_summary = Map.get(artifact, "summary", %{})
    apply = Map.get(artifact, "apply", %{})

    header =
      "Virtual overlay completed: commands=#{length(Map.get(artifact, "commands", []))}, " <>
        "imported_files=#{Map.get(import, "file_count", 0)}, " <>
        "changed_files=#{length(changes)}, " <>
        "diff_bytes=#{Map.get(artifact_summary, "diff_bytes", 0)}, " <>
        "apply.status=#{Map.get(apply, "status", "unknown")}."

    [header, command_feedback(artifact), change_feedback(changes)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> Tool.truncate(16_000)
  end

  # ADR 0005 channel discipline: imported file content can carry ANSI/OSC and
  # other terminal-control bytes; the model channel gets none of them.
  # Alternations: CSI sequences, OSC sequences, then any remaining C0 control
  # (tab and newline excepted) or DEL.
  @terminal_controls ~r/\x1b\[[0-9;?]*[ -\/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|[\x00-\x08\x0b-\x1f\x7f]/

  defp command_feedback(artifact) do
    artifact
    |> Map.get("commands", [])
    |> Enum.map_join("\n", fn command ->
      exit_code = Map.get(command, "exit_code", "?")
      display = command |> Map.get("display", "") |> sanitize_stream()
      stdout = command |> Map.get("stdout", "") |> sanitize_stream()
      stderr = command |> Map.get("stderr", "") |> sanitize_stream()

      ["$ #{display} (exit #{exit_code})"]
      |> append_stream(stdout)
      |> append_stream(stderr)
      |> Enum.join("\n")
    end)
  end

  defp sanitize_stream(text) do
    text
    |> String.replace(@terminal_controls, "")
    |> String.trim_trailing()
  end

  defp append_stream(lines, ""), do: lines
  defp append_stream(lines, stream), do: lines ++ [stream]

  defp change_feedback(changes) do
    Enum.map_join(changes, "\n", fn change ->
      case get_in(change, ["diff", "text"]) do
        text when is_binary(text) and text != "" ->
          text

        _missing ->
          "#{Map.get(change, "operation", "?")} #{Map.get(change, "path", "?")} (no text diff)"
      end
    end)
  end
end
