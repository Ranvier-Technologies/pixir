defmodule Pixir.Tools.RunVirtualCommands do
  @moduledoc """
  Model-visible Tool for one-shot commands in a bounded virtual overlay.

  The operator supplies the imported read set and limits through Turn context. Model
  arguments contain commands and an optional boolean `deliverable`. Commands within
  one invocation share virtual edits; the next invocation reimports host files.
  Canonical Logs/artifacts still persist on disk, but no Session scratch is retained.
  No host binaries, network, parent workspace mutation, or automatic apply is available.
  Delivery intent is canonical result metadata outside the unchanged v1 artifact.
  """

  use Pixir.Tool

  alias Pixir.{Tool, VirtualOverlay}

  @lifetime "Commands within ONE call share virtual edits; the next call reimports host files. Canonical Logs/artifacts persist on disk. No host binaries/network, parent mutation, or automatic apply."

  @impl Pixir.Tool
  def __tool__ do
    %{
      name: "run_virtual_commands",
      description:
        "Run commands in a bounded in-memory shell imported from an operator-owned read set. " <>
          @lifetime <>
          " Set deliverable: true to select THIS successfully produced artifact for delivery; later unmarked calls cannot replace it. A later explicit mark replaces it, including an empty diff. Without any mark, the latest successful artifact is selected.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "commands" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "Virtual shell commands to execute in order within this one invocation"
          },
          "deliverable" => %{
            "type" => "boolean",
            "description" =>
              "Select this successfully produced virtual_diff for delivery. Optional; omitted/false retains legacy selection when no explicit mark exists."
          }
        },
        "required" => ["commands"],
        "additionalProperties" => false
      }
    }
  end

  @impl Pixir.Tool
  def execute(%{"commands" => commands} = args, context) do
    with :ok <- validate_args(args),
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
      deliverable = Map.get(args, "deliverable", false)

      {:ok,
       %{
         "output" => summary(artifact, deliverable),
         "virtual_diff" => artifact,
         "deliverable" => deliverable
       }}
    end
  end

  def execute(_args, _context),
    do: {:error, Tool.error(:invalid_args, "run_virtual_commands requires commands", %{})}

  @impl Pixir.Tool
  def dry_run(%{"commands" => commands} = args, context) do
    with :ok <- validate_args(args),
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

  defp validate_args(args) do
    case Map.keys(args) -- ["commands", "deliverable"] do
      [] ->
        if is_boolean(Map.get(args, "deliverable", false)) do
          :ok
        else
          {:error,
           Tool.error(:invalid_args, "deliverable must be a boolean", %{"field" => "deliverable"})}
        end

      unknown ->
        {:error,
         Tool.error(
           :invalid_args,
           "run_virtual_commands accepts commands and deliverable only",
           %{
             "unknown" => Enum.sort(unknown)
           }
         )}
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

    case VirtualOverlay.validate_read_set(read_set) do
      :ok ->
        {:ok,
         %{
           read_set: read_set,
           limits: Map.get(virtual_overlay, :limits)
         }}

      {:error, %{index: index, reason: reason}} ->
        {:error,
         Tool.error(:invalid_args, "operator virtual overlay read_set is unsafe", %{
           "field" => "virtual_overlay.read_set",
           "index" => index,
           "reason" => reason
         })}

      {:error, _reason} ->
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

  # Reserve independent budgets BEFORE rendering streams: command outcomes must not
  # disappear behind an earlier flood. Full (operator-bounded) evidence stays in the
  # canonical artifact. These sections plus headers fit strictly within 16,000 bytes.
  defp summary(artifact, deliverable) do
    commands = artifact["commands"]
    changes = artifact["changes"]
    {statuses, omitted_commands, truncated_displays} = command_statuses(commands)
    {excerpts, omitted_excerpts, truncated_excerpts} = excerpts(commands, changes)

    Enum.join(
      [
        "Virtual overlay completed: commands=#{length(commands)}, imported_files=#{artifact["import"]["file_count"]}, changed_files=#{length(changes)}, diff_bytes=#{artifact["summary"]["diff_bytes"]}, apply.status=#{artifact["apply"]["status"]}, deliverable=#{deliverable}.",
        @lifetime,
        "Command statuses (before excerpts):",
        statuses,
        "Feedback cuts: omitted_commands=#{omitted_commands}, truncated_displays=#{truncated_displays}, omitted_excerpts=#{omitted_excerpts}, truncated_excerpts=#{truncated_excerpts}. Excerpts are bounded; full operator-bounded artifact evidence remains in the canonical Log (artifact diff truncated=#{artifact["summary"]["truncated"]}).",
        excerpts
      ],
      "\n"
    )
  end

  # ADR 0005: neutralize CSI, OSC, remaining C0 (except tab/newline), and DEL
  # for ALL model-facing imported content, including command displays and diffs.
  @terminal_controls ~r/\x1b\[[0-9;?]*[ -\/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|[\x00-\x08\x0b-\x1f\x7f]/

  defp sanitize_stream(text) do
    text |> String.replace(@terminal_controls, "") |> String.trim_trailing()
  end

  defp command_statuses(commands) do
    {lines, _bytes, shown, truncated} =
      Enum.reduce_while(commands, {[], 0, 0, 0}, fn command, {lines, bytes, shown, truncated} ->
        {display, omitted} = clip(sanitize_stream(command["display"]), 240)

        line =
          "#{command["id"]} $ #{display} (exit #{command["exit_code"]}) status=#{command["status"]}\n"

        if bytes + byte_size(line) <= 6_000 do
          {:cont,
           {[line | lines], bytes + byte_size(line), shown + 1,
            truncated + if(omitted > 0, do: 1, else: 0)}}
        else
          {:halt, {lines, bytes, shown, truncated}}
        end
      end)

    {lines |> Enum.reverse() |> Enum.join(), length(commands) - shown, truncated}
  end

  defp excerpts(commands, changes) do
    streams =
      Enum.flat_map(commands, fn command ->
        for stream <- ["stdout", "stderr"], command[stream] != "" do
          {"#{command["id"]} #{stream}", command[stream]}
        end
      end)

    diffs =
      Enum.map(changes, fn change ->
        {"#{change["operation"]} #{change["path"]}",
         get_in(change, ["diff", "text"]) || "(no text diff)"}
      end)

    entries = streams ++ diffs
    shown = Enum.take(entries, 40)
    budget = min(2_000, div(8_000, max(length(shown), 1)))

    {rendered, truncated} =
      Enum.map_reduce(shown, 0, fn {label, text}, count ->
        {label, label_cut} = clip(sanitize_stream(label), 100)
        {text, text_cut} = clip(sanitize_stream(text), budget - byte_size(label) - 4)
        {label <> ":\n" <> text <> "\n", count + if(label_cut + text_cut > 0, do: 1, else: 0)}
      end)

    {Enum.join(rendered), length(entries) - length(shown), truncated}
  end

  defp clip(text, budget) do
    text = String.replace_invalid(text)
    {Tool.truncate(text, {:total_bytes, budget}), if(byte_size(text) > budget, do: 1, else: 0)}
  end
end
