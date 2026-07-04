defmodule Mix.Tasks.Pixir.Smoke.Skills do
  @shortdoc "No-network smoke for ADR 0010 Agent Skills"

  @moduledoc """
  Verifies Pixir Agent Skills end-to-end without hitting the network:

    * creates repo/user/Pixir-global fixture Skills;
    * proves duplicate resolution and visible warnings;
    * executes `skills_list` and `skill_view`;
    * verifies a canonical `skill_activation` in the NDJSON Log;
    * verifies Provider input replays the activation snapshot;
    * proves ordinary `read` remains Workspace-confined.

  Usage:

      mix pixir.smoke.skills
  """

  use Mix.Task

  alias Pixir.{Auth, Log, Provider, SessionSupervisor, Skills}
  alias Pixir.Tools.{Executor, Read}

  @impl Mix.Task
  def run(_args) do
    old_home = System.get_env("HOME")
    old_pixir_home = System.get_env("PIXIR_HOME")

    scratch = scratch_dir()
    workspace = Path.join(scratch, "workspace")
    user_home = Path.join(scratch, "home")
    pixir_home = Path.join(scratch, "pixir-home")

    try do
      System.put_env("HOME", user_home)
      System.put_env("PIXIR_HOME", pixir_home)
      Mix.Task.run("app.start")

      create_fixtures(workspace, user_home, pixir_home)

      with :ok <- prove_discovery(workspace),
           {:ok, sid, history} <- prove_tools_and_log(workspace),
           :ok <- prove_provider_replay(history),
           :ok <- prove_read_confinement(workspace) do
        Mix.shell().info("""

        Agent Skills smoke passed. ✓
          workspace: #{workspace}
          session:   #{sid}
          events:    #{length(history)} canonical
        """)
      else
        {:error, stage, reason} -> fail(stage, reason)
      end
    after
      restore_env("HOME", old_home)
      restore_env("PIXIR_HOME", old_pixir_home)
      File.rm_rf!(scratch)
    end
  end

  defmodule NoOAuth do
    def refresh_skew_ms, do: 60_000
  end

  defp prove_discovery(workspace) do
    {:ok, %{skills: skills, warnings: warnings}} = Skills.discover(workspace)
    selected = Enum.find(skills, &(&1.name == "collision"))

    cond do
      selected == nil ->
        {:error, "discovery", "missing collision skill"}

      selected.scope != "repo" ->
        {:error, "discovery", "collision precedence selected #{selected.scope}, expected repo"}

      warnings == [] ->
        {:error, "discovery", "duplicate warning was not visible"}

      true ->
        Mix.shell().info("Step 1/4 — discovery and precedence passed. ✓")
        :ok
    end
  end

  defp prove_tools_and_log(workspace) do
    {:ok, sid, _pid} = SessionSupervisor.start_session(workspace: workspace, role: :build)
    ctx = %{session_id: sid, workspace: workspace, call_id: "c1", permission: %{mode: :auto}}

    with {:ok, %{"skills" => skills, "warnings" => [_ | _]}} <-
           Executor.execute_call(%{name: "skills_list", args: %{}}, ctx),
         true <- Enum.any?(skills, &(&1["name"] == "collision")) || {:error, "list missing"},
         {:ok, %{"activated" => true}} <-
           Executor.run(%{call_id: "c1", name: "skill_view", args: %{"name" => "collision"}}, ctx),
         {:ok, %{"activated" => false}} <-
           Executor.run(
             %{
               call_id: "c2",
               name: "skill_view",
               args: %{"name" => "collision", "path" => "references/note.md"}
             },
             %{ctx | call_id: "c2"}
           ),
         {:ok, history} <- Log.fold(sid, workspace: workspace) do
      activations = Enum.filter(history, &(&1.type == :skill_activation))

      if length(activations) == 1 and hd(activations).data["content"] =~ "Repo collision skill" do
        File.write!(
          Path.join(workspace, ".agents/skills/collision/SKILL.md"),
          "# Changed on disk after activation\n"
        )

        Mix.shell().info("Step 2/4 — tools and NDJSON activation passed. ✓")
        {:ok, sid, history}
      else
        {:error, "activation log", "expected exactly one repo activation snapshot"}
      end
    else
      {:error, reason} -> {:error, "tools/log", reason}
      other -> {:error, "tools/log", other}
    end
  end

  defp prove_provider_replay(history) do
    name = :"skills_smoke_auth_#{System.unique_integer([:positive])}"
    path = Path.join(System.tmp_dir!(), "pixir-skills-smoke-auth-#{name}.json")

    try do
      {:ok, _pid} =
        Auth.start_link(name: name, store_path: path, env_api_key: "sk-smoke", oauth: NoOAuth)

      transport = fn request, acc, feed ->
        send(self(), {:provider_body, Jason.decode!(request.body)})
        acc = feed.({:status, 200}, acc)
        {:ok, feed.({:data, sse(%{type: "response.completed"})}, acc)}
      end

      {:ok, _} = Provider.stream(%{history: history}, auth: name, transport: transport)

      receive do
        {:provider_body, body} ->
          input_text =
            body["input"]
            |> Enum.flat_map(&Map.get(&1, "content", []))
            |> Enum.map_join("\n", &Map.get(&1, "text", ""))

          if input_text =~ "<skill name=\"collision\"" and
               input_text =~ "Repo collision skill" and
               not String.contains?(input_text, "Changed on disk") do
            Mix.shell().info("Step 3/4 — Provider replay injection passed. ✓")
            :ok
          else
            {:error, "provider replay", "activation snapshot missing from input"}
          end
      after
        1_000 -> {:error, "provider replay", "provider body was not captured"}
      end
    after
      File.rm_rf!(path)
    end
  end

  defp prove_read_confinement(workspace) do
    ctx = %{session_id: "smoke", workspace: workspace, call_id: "read"}

    case Read.execute(%{"path" => "../home/.agents/skills/collision/SKILL.md"}, ctx) do
      {:error, %{error: %{kind: :outside_workspace}}} ->
        Mix.shell().info("Step 4/4 — workspace read confinement passed. ✓")
        :ok

      other ->
        {:error, "read confinement", other}
    end
  end

  defp create_fixtures(workspace, user_home, pixir_home) do
    File.mkdir_p!(Path.join(workspace, ".git"))

    write_skill(
      Path.join(workspace, ".agents/skills/collision"),
      "collision",
      "Repo collision skill",
      "Repo collision skill body."
    )

    write_skill(
      Path.join(user_home, ".agents/skills/collision"),
      "collision",
      "User collision skill",
      "User collision skill body."
    )

    write_skill(
      Path.join(pixir_home, "skills/global-only"),
      "global-only",
      "Pixir-global skill",
      "Global skill body."
    )
  end

  defp write_skill(dir, name, description, body) do
    File.mkdir_p!(Path.join(dir, "references"))

    File.write!(Path.join(dir, "SKILL.md"), """
    ---
    name: #{name}
    description: #{description}
    ---

    # #{description}

    #{body}
    """)

    File.write!(Path.join(dir, "references/note.md"), "supporting file for #{name}\n")
  end

  defp sse(map), do: "data: " <> Jason.encode!(map) <> "\n\n"

  defp scratch_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "pixir-skills-smoke-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      )

    File.mkdir_p!(dir)
    dir
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp fail(stage, reason) do
    Mix.shell().error("✗ #{stage}: #{inspect(reason)}")
    exit({:shutdown, 1})
  end
end
