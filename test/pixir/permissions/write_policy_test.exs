defmodule Pixir.Permissions.WritePolicyTest do
  use ExUnit.Case, async: true

  alias Pixir.Permissions.WritePolicy
  alias Pixir.Test.WorkspaceFixtures

  setup do
    ws =
      Path.join(
        System.tmp_dir!(),
        "pixir-write-policy-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(Path.join(ws, "src"))

    on_exit(fn -> File.rm_rf!(ws) end)
    %{ws: ws}
  end

  test "normalizes policy metadata and authorizes allowed writes", %{ws: ws} do
    assert {:ok, policy} =
             WritePolicy.normalize(%{
               "version" => 1,
               "metadata" => %{"id" => "task-c"},
               "allow_writes" => ["src/**"],
               "deny_writes" => ["src/secret.txt"],
               "bash" => "disabled"
             })

    assert %{
             "id" => "task-c",
             "hash" => "sha256:" <> _,
             "allow_writes" => ["src/**"],
             "bash" => "disabled"
           } = WritePolicy.metadata(policy)

    assert :allow =
             WritePolicy.authorize_tool(
               policy,
               "write",
               %{"path" => "src/app.ts", "content" => "ok"},
               ws
             )
  end

  test "normalizes operator-declared verify commands and authorizes byte-equal bash", %{ws: ws} do
    verify = ["mix format --check-formatted", "mix compile --warnings-as-errors"]

    assert {:ok, policy} =
             WritePolicy.normalize(%{
               "version" => 1,
               "metadata" => %{"id" => "verify-task"},
               "allow_writes" => ["src/**"],
               "bash" => %{"verify" => verify}
             })

    assert policy["bash"] == %{"verify" => verify}

    assert %{
             "id" => "verify-task",
             "allow_writes" => ["src/**"],
             "bash" => %{"verify" => ^verify}
           } = WritePolicy.metadata(policy)

    assert :allow =
             WritePolicy.authorize_tool(
               policy,
               "bash",
               %{"command" => "mix format --check-formatted"},
               ws
             )

    assert {:deny, %{error: %{kind: :bash_disabled, details: details}}} =
             WritePolicy.authorize_tool(
               policy,
               "bash",
               %{"command" => "mix format --check-formatted --migrate"},
               ws
             )

    assert details["matched_rule"] == "bash_disabled"
    assert details["verify_commands_declared"] == 2
    assert :allow = WritePolicy.authorize_tool(policy, "bash", %{"command" => "ls src"}, ws)
  end

  test "rejects verify test commands with the v1 future-work action" do
    assert {:error, %{error: %{kind: :invalid_args, message: message, details: details}}} =
             WritePolicy.normalize(%{
               "version" => 1,
               "allow_writes" => ["src/**"],
               "bash" => %{"verify" => ["mix test test/pixir"]}
             })

    assert message == "verify test commands are not accepted yet (v1 allows format/compile only)"
    assert details["next_action"] == "keep_test_execution_with_the_orchestrator"
    assert details["observed"] == "mix test test/pixir"
  end

  test "rejects unsafe verify command entries" do
    for command <- [
          "mix format --check-formatted; rm -rf src",
          "mix format --check-formatted && rm -rf src",
          "mix format --check-formatted | cat",
          "mix format --check-formatted `date`",
          "mix format --check-formatted $(date)",
          "mix format --check-formatted ../outside"
        ] do
      assert {:error, %{error: %{kind: :invalid_args, details: details}}} =
               WritePolicy.normalize(%{
                 "version" => 1,
                 "allow_writes" => ["src/**"],
                 "bash" => %{"verify" => [command]}
               })

      assert details["observed"] == command
    end
  end

  test "rejects unknown keys inside bash verify map" do
    assert {:error, %{error: %{kind: :invalid_args, details: details}}} =
             WritePolicy.normalize(%{
               "version" => 1,
               "allow_writes" => ["src/**"],
               "bash" => %{"verify" => [], "surprise" => true}
             })

    assert details["observed"] == ["surprise"]
    assert details["accepted_keys"] == ["verify"]
  end

  test "verify commands still hit workspace confinement before authorization", %{ws: ws} do
    {:ok, policy} =
      WritePolicy.normalize(%{
        "version" => 1,
        "allow_writes" => ["src/**"],
        "bash" => %{"verify" => ["mix format --check-formatted /etc/passwd"]}
      })

    assert {:deny, %{error: %{kind: :outside_workspace, details: details}}} =
             WritePolicy.authorize_tool(
               policy,
               "bash",
               %{"command" => "mix format --check-formatted /etc/passwd"},
               ws
             )

    assert details["matched_rule"] == "outside_workspace"
    assert details["token"] == "/etc/passwd"
  end

  test "spawn_agent child write_policy override remains denied", %{ws: ws} do
    {:ok, policy} =
      WritePolicy.normalize(%{
        "version" => 1,
        "allow_writes" => ["src/**"],
        "bash" => %{"verify" => ["mix compile --warnings-as-errors"]}
      })

    assert {:deny, %{error: %{kind: :write_policy_denied, details: details}}} =
             WritePolicy.authorize_tool(
               policy,
               "spawn_agent",
               %{"task" => "try", "write_policy" => %{"allow_writes" => ["**/*"]}},
               ws
             )

    assert details["matched_rule"] == "child_policy_override_unsupported"
  end

  test "denies unmatched, explicit-deny, state-dir, and unsafe bash paths", %{ws: ws} do
    {:ok, policy} =
      WritePolicy.normalize(%{
        "version" => 1,
        "metadata" => %{"id" => "task-c"},
        "allow_writes" => ["src/**"],
        "deny_writes" => ["src/secret.txt"]
      })

    assert {:deny, %{error: %{kind: :write_policy_denied, details: details}}} =
             WritePolicy.authorize_tool(policy, "write", %{"path" => "README.md"}, ws)

    assert details["matched_rule"] == "no_allow_match"

    assert {:deny, %{error: %{kind: :write_policy_denied, details: details}}} =
             WritePolicy.authorize_tool(policy, "write", %{"path" => "src/secret.txt"}, ws)

    assert details["matched_rule"] == "src/secret.txt"

    assert {:deny, %{error: %{kind: :write_policy_denied, details: details}}} =
             WritePolicy.authorize_tool(policy, "write", %{"path" => ".pixir/log"}, ws)

    assert details["matched_rule"] == ".pixir/**"

    assert {:deny, %{error: %{kind: :bash_disabled, details: details}}} =
             WritePolicy.authorize_tool(policy, "bash", %{"command" => "rm -rf src"}, ws)

    assert details["matched_rule"] == "bash_disabled"
    assert "use_native_read_tools" in details["next_actions"]
  end

  test "denies case variants of protected paths under broad allow", %{ws: ws} do
    {:ok, policy} = WritePolicy.normalize(%{"version" => 1, "allow_writes" => ["**/*"]})

    for {path, rule} <- [
          {".PIXIR/log.ndjson", ".pixir/**"},
          {".Git/config", ".git/**"},
          {"src/.ENV.local", "**/.env*"},
          {"src/Secrets/key.txt", "**/secrets/**"},
          {".pixir", ".pixir/**"},
          {".env", "**/.env*"}
        ] do
      assert {:deny, %{error: %{kind: :write_policy_denied, details: details}}} =
               WritePolicy.authorize_tool(policy, "write", %{"path" => path}, ws)

      assert details["matched_rule"] == rule
    end
  end

  test "uses a stricter bash allowlist under bounded policy", %{ws: ws} do
    {:ok, policy} = WritePolicy.normalize(%{"version" => 1, "allow_writes" => ["src/**"]})

    assert :allow = WritePolicy.authorize_tool(policy, "bash", %{"command" => "ls src"}, ws)

    for command <- [
          "find . -delete",
          "env rm src/file.txt",
          "python -c 'open(\"src/file.txt\", \"w\").write(\"x\")'",
          "ls src; rm -rf src",
          "ls src\nrm -rf src",
          "ls src\rrm -rf src",
          "ls src & rm -rf src",
          "cat src/file.txt > src/copy.txt"
        ] do
      assert {:deny, %{error: %{kind: :bash_disabled, details: details}}} =
               WritePolicy.authorize_tool(policy, "bash", %{"command" => command}, ws)

      assert details["matched_rule"] == "bash_disabled"
    end
  end

  test "denies safe-looking bash commands that reference paths outside the workspace", %{
    ws: ws
  } do
    fixture = WorkspaceFixtures.outside_workspace_fixture(ws)
    on_exit(fn -> File.rm_rf!(fixture.outside) end)

    {:ok, policy} = WritePolicy.normalize(%{"version" => 1, "allow_writes" => ["src/**"]})

    for {command, token} <- [
          {"cat #{fixture.outside_file}", fixture.outside_file},
          {"cat $HOME", "$HOME"},
          {"cat ${HOME}", "${HOME}"},
          {"cat $HOME/neighbor-notes.txt", "$HOME/neighbor-notes.txt"},
          {"cat ~/neighbor-notes.txt", "~/neighbor-notes.txt"},
          {"cat #{fixture.symlink_token}", fixture.symlink_token},
          {"cat outside-link/missing.txt", "outside-link/missing.txt"},
          {"cat outside-link/*.txt", "outside-link/*.txt"}
        ] do
      assert {:deny, %{error: %{kind: :outside_workspace, details: details}}} =
               WritePolicy.authorize_tool(policy, "bash", %{"command" => command}, ws)

      assert details["matched_rule"] == "outside_workspace"
      assert details["token"] == token
      assert details["tool"] == "bash"
    end

    assert :allow = WritePolicy.authorize_tool(policy, "bash", %{"command" => "ls src"}, ws)
  end

  test "any-segment allow rules match leaf targets, not descendant directories", %{ws: ws} do
    {:ok, policy} = WritePolicy.normalize(%{"version" => 1, "allow_writes" => ["**/config"]})

    assert :allow = WritePolicy.authorize_tool(policy, "write", %{"path" => "a/config"}, ws)

    assert {:deny, %{error: %{kind: :write_policy_denied, details: details}}} =
             WritePolicy.authorize_tool(policy, "write", %{"path" => "a/config/secret.txt"}, ws)

    assert details["matched_rule"] == "no_allow_match"
  end

  test "any-segment parent allow rules can narrow to covered child write sets" do
    {:ok, policy} =
      WritePolicy.normalize(%{
        "version" => 1,
        "allow_writes" => ["**/generated/**", "**/config", "**/prefix*"]
      })

    assert {:ok, narrowed} =
             WritePolicy.narrow_to_write_set(policy, [
               "app/generated/out.txt",
               "app/config",
               "app/prefix-value"
             ])

    assert narrowed["allow_writes"] == [
             "app/generated/out.txt",
             "app/config",
             "app/prefix-value"
           ]

    assert {:error, %{error: %{kind: :write_policy_denied, details: details}}} =
             WritePolicy.narrow_to_write_set(policy, ["app/config/secret.txt"])

    assert details["matched_rule"] == "not_within_parent_allow"
  end

  test "allows safe read-only bash but rejects symlink write targets", %{ws: ws} do
    File.mkdir_p!(Path.join(ws, "real"))
    File.ln_s!(Path.join(ws, "real"), Path.join(ws, "link"))
    File.write!(Path.join(ws, "real/target.txt"), "old")
    File.ln_s!(Path.join(ws, "real/target.txt"), Path.join(ws, "real/link.txt"))

    {:ok, policy} =
      WritePolicy.normalize(%{
        "version" => 1,
        "allow_writes" => ["link/**", "real/**"]
      })

    assert :allow = WritePolicy.authorize_tool(policy, "bash", %{"command" => "ls"}, ws)

    assert {:error, %{error: %{kind: :write_policy_denied, details: details}}} =
             WritePolicy.authorize_tool(policy, "write", %{"path" => "link/out.txt"}, ws)

    assert details["matched_rule"] == "symlink_path_component"

    assert {:error, %{error: %{kind: :write_policy_denied, details: details}}} =
             WritePolicy.authorize_tool(policy, "write", %{"path" => "real/link.txt"}, ws)

    assert details["matched_rule"] == "symlink_path_component"
  end

  test "denies unknown mutating tools under active policy", %{ws: ws} do
    {:ok, policy} = WritePolicy.normalize(%{"version" => 1, "allow_writes" => ["src/**"]})

    assert {:deny, %{error: %{kind: :write_policy_denied, details: details}}} =
             WritePolicy.authorize_tool(policy, "future_write_tool", %{}, ws)

    assert details["matched_rule"] == "unsupported_mutating_tool"
  end

  test "rejects absolute and parent-directory policy rules" do
    for rule <- ["/tmp/out.txt", "../out.txt", "src/../out.txt", "src/"] do
      assert {:error, %{error: %{kind: :invalid_args, details: details}}} =
               WritePolicy.normalize(%{"version" => 1, "allow_writes" => [rule]})

      assert details["rule"] == rule
    end
  end

  test "rehydrates runtime policy from durable metadata without changing hash" do
    {:ok, policy} =
      WritePolicy.normalize(%{
        "version" => 1,
        "metadata" => %{"id" => "restore-test", "owner" => "agent"},
        "allow_writes" => ["src/**"],
        "deny_writes" => ["src/secret.txt"]
      })

    metadata = WritePolicy.metadata(policy)

    assert {:ok, restored} = WritePolicy.from_metadata(metadata)
    assert restored["id"] == "restore-test"
    assert restored["hash"] == policy["hash"]
    assert restored["allow_writes"] == policy["allow_writes"]
    assert restored["deny_writes"] == policy["deny_writes"]
  end
end
