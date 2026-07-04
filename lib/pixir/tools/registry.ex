defmodule Pixir.Tools.Registry do
  @moduledoc """
  Compile-time map of tool name → module for the v0.1 built-ins (`read`, `write`,
  `bash`). The Executor resolves calls through `fetch/1`; the Provider advertises the
  catalogue via `responses_specs/0`.
  """

  alias Pixir.Provider

  alias Pixir.Tools.{
    Bash,
    CloseAgent,
    Edit,
    ListAgents,
    Read,
    ResourceView,
    RunWorkflow,
    SendInput,
    SkillView,
    SkillsList,
    SpawnAgent,
    UpdatePlan,
    WaitAgent,
    Write
  }

  @tools %{
    "read" => Read,
    "resource_view" => ResourceView,
    "write" => Write,
    "edit" => Edit,
    "skills_list" => SkillsList,
    "skill_view" => SkillView,
    "spawn_agent" => SpawnAgent,
    "wait_agent" => WaitAgent,
    "send_input" => SendInput,
    "close_agent" => CloseAgent,
    "list_agents" => ListAgents,
    "run_workflow" => RunWorkflow,
    "bash" => Bash,
    # Always available (benign); plan mode's system prompt + `:read_only` posture
    # steer the model to use it as the architect tool (D.3).
    "update_plan" => UpdatePlan
  }

  @doc "All registered tool names."
  @spec names() :: [String.t()]
  def names, do: @tools |> Map.keys() |> Enum.sort()

  @doc "All registered tool modules."
  @spec modules() :: [module()]
  def modules do
    @tools
    |> Enum.sort_by(fn {name, _module} -> name end)
    |> Enum.map(fn {_name, module} -> module end)
  end

  @doc "Resolve a tool name to its module."
  @spec fetch(String.t()) :: {:ok, module()} | {:error, map()}
  def fetch(name) when is_binary(name) do
    case Map.fetch(@tools, name) do
      {:ok, module} ->
        {:ok, module}

      :error ->
        {:error, Pixir.Tool.error(:unknown_tool, "no such tool", %{name: name, known: names()})}
    end
  end

  @doc "Tool specs for the Responses API `tools` field."
  @spec responses_specs() :: [map()]
  def responses_specs do
    @tools
    |> Enum.sort_by(fn {name, _module} -> name end)
    |> Enum.map(fn {_name, module} -> Provider.tool_spec(module.__tool__()) end)
  end
end
