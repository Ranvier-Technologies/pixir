defmodule Pixir.Tools.SpawnAgent do
  @moduledoc "Spawn or queue a Subagent for a bounded task (ADR 0011)."

  use Pixir.Tool

  alias Pixir.{Subagents, Tool}
  alias Pixir.Permissions.WritePolicy

  @impl Pixir.Tool
  def __tool__ do
    %{
      name: "spawn_agent",
      description: "Spawn or queue a supervised Subagent for an explicitly delegated task.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "task" => %{"type" => "string", "description" => "Bounded task for the Subagent"},
          "agent" => %{"type" => "string", "description" => "Agent role name, default default"},
          "timeout_ms" => %{
            "type" => "integer",
            "minimum" => 1,
            "description" =>
              "Per-worker execution deadline in ms; exceeding it interrupts the child Session"
          },
          "max_threads" => %{"type" => "integer", "description" => "Parent concurrency cap"},
          "max_depth" => %{
            "type" => "integer",
            "minimum" => 0,
            "description" =>
              "Absolute delegation depth cap from root; root children run at depth 1"
          },
          "workspace_mode" => %{
            "type" => "string",
            "enum" => ["isolated", "shared"],
            "description" =>
              "isolated (default) or shared. virtual_overlay is modeled for delegation context, but is not accepted here until runtime support lands."
          }
        },
        "required" => ["task"]
      }
    }
  end

  @impl Pixir.Tool
  def execute(%{"task" => task} = args, context) when is_binary(task) and task != "" do
    opts = subagent_opts(context)

    # index is delegate-runner evidence (tasks[] position), and id is
    # runtime-owned durable identity. Dropping them here is defense in depth;
    # the enforcement barrier is that Subagents.Manager.build_spec/3 does not
    # read either value from args. attachments, model, reasoning_effort, and
    # web_search are operator knobs (delegate spec / ACP _meta), not a
    # capability the spawning model may grant its children.
    args =
      Map.drop(args, ["index", "id", "attachments", "model", "reasoning_effort", "web_search"])

    with {:ok, agent} <- Subagents.spawn_agent(context.session_id, args, opts) do
      {:ok, %{"output" => render(agent), "subagent" => agent}}
    end
  end

  def execute(_args, _context),
    do: {:error, Tool.error(:invalid_args, "task is required", %{})}

  @impl Pixir.Tool
  def dry_run(%{"task" => task} = args, context) when is_binary(task) and task != "" do
    {:ok,
     %{
       "dry_run" => true,
       "would" => "spawn_agent",
       "task" => task,
       "agent" => Map.get(args, "agent", "default"),
       "timeout_ms" => Map.get(args, "timeout_ms"),
       "max_depth" => Map.get(args, "max_depth")
     }
     |> maybe_put("write_policy", WritePolicy.metadata(get_in(context, [:permission, :policy])))}
  end

  def dry_run(_args, _context),
    do: {:error, Tool.error(:invalid_args, "task is required", %{})}

  defp subagent_opts(context) do
    [
      workspace: context.workspace,
      provider: Map.get(context, :provider, Pixir.Provider),
      provider_opts: Map.get(context, :provider_opts, []),
      permission_mode: get_in(context, [:permission, :mode]) || :auto,
      write_policy: get_in(context, [:permission, :policy]),
      skills_opts: Map.get(context, :skills_opts, []),
      agents_opts: Map.get(context, :agents_opts, []),
      depth: Map.get(context, :subagent_depth, 0)
    ]
  end

  defp render(agent) do
    child =
      case agent["child_session_id"] do
        id when is_binary(id) -> "; child_session_id=#{id}"
        _ -> ""
      end

    depth =
      case {agent["depth"], agent["max_depth"]} do
        {depth, max_depth} when is_integer(depth) and is_integer(max_depth) ->
          "; depth=#{depth}/max_depth=#{max_depth}"

        _ ->
          ""
      end

    "Spawned #{agent["id"]} (#{agent["agent"]}) with status #{agent["status"]}#{child}#{depth}."
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
