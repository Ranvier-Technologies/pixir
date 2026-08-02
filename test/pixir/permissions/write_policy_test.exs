defmodule Pixir.Permissions.WritePolicyTest do
  use ExUnit.Case, async: true

  alias Pixir.Permissions.WritePolicy
  alias Pixir.Test.WorkspaceFixtures

  # `path_not_inspectable` is reached by making a directory unreadable, and mode
  # bits do not stop root. Under root the rule is unreachable, so the test that
  # pins it is skipped *with a reason* rather than softened into an assertion
  # that any outcome is acceptable — a soft pass would report a green CI never
  # proved.
  @root_skip (case System.cmd("id", ["-u"], stderr_to_stdout: true) do
                {"0" <> _, 0} ->
                  [skip: "chmod 0o000 does not deny root: path_not_inspectable is unreachable"]

                _ ->
                  []
              end)

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

  test "operator-declared verify prefixes admit non-Elixir verify commands", %{ws: ws} do
    assert {:ok, policy} =
             WritePolicy.normalize(%{
               "version" => 1,
               "metadata" => %{"id" => "pnpm-task"},
               "allow_writes" => ["src/**"],
               "bash" => %{
                 "verify_prefixes" => ["pnpm typecheck"],
                 "verify" => ["pnpm typecheck"]
               }
             })

    assert policy["bash"] == %{
             "verify_prefixes" => ["pnpm typecheck"],
             "verify" => ["pnpm typecheck"]
           }

    assert %{"bash" => %{"verify_prefixes" => ["pnpm typecheck"]}} = WritePolicy.metadata(policy)

    assert :allow =
             WritePolicy.authorize_tool(policy, "bash", %{"command" => "pnpm typecheck"}, ws)

    assert {:deny, %{error: %{kind: :bash_disabled}}} =
             WritePolicy.authorize_tool(policy, "bash", %{"command" => "pnpm build"}, ws)
  end

  test "a single-token operator prefix admits any command starting with it" do
    assert {:ok, policy} =
             WritePolicy.normalize(%{
               "version" => 1,
               "allow_writes" => ["src/**"],
               "bash" => %{
                 "verify_prefixes" => ["cargo", "npm run"],
                 "verify" => ["cargo check", "cargo fmt --check", "npm run lint"]
               }
             })

    assert policy["bash"]["verify"] == ["cargo check", "cargo fmt --check", "npm run lint"]
  end

  test "a non-Elixir verify command is rejected when no allowlist is declared" do
    assert {:error, %{error: %{kind: :invalid_args, details: details}}} =
             WritePolicy.normalize(%{
               "version" => 1,
               "allow_writes" => ["src/**"],
               "bash" => %{"verify" => ["pnpm typecheck"]}
             })

    assert details["observed"] == "pnpm typecheck"
    assert details["accepted_prefixes"] == ["mix format", "mix compile"]
  end

  test "rejection details report the allowlist in force for the policy" do
    assert {:error, %{error: %{kind: :invalid_args, details: details}}} =
             WritePolicy.normalize(%{
               "version" => 1,
               "allow_writes" => ["src/**"],
               "bash" => %{
                 "verify_prefixes" => ["pnpm typecheck"],
                 "verify" => ["mix format --check-formatted"]
               }
             })

    assert details["observed"] == "mix format --check-formatted"
    assert details["accepted_prefixes"] == ["pnpm typecheck"]
  end

  test "the default policy hash is byte-identical to the pre-allowlist hash" do
    assert {:ok, policy} =
             WritePolicy.normalize(%{
               "version" => 1,
               "metadata" => %{"id" => "hash-probe"},
               "allow_writes" => ["src/**"],
               "bash" => %{
                 "verify" => ["mix format --check-formatted", "mix compile --warnings-as-errors"]
               }
             })

    assert policy["bash"] == %{
             "verify" => ["mix format --check-formatted", "mix compile --warnings-as-errors"]
           }

    assert policy["hash"] ==
             "sha256:b425fb551b5fd68fe3a3ccda136c72d1c129780e40200fea0336ca9145af7d54"
  end

  test "every per-entry filter still rejects under an operator-declared allowlist" do
    declare = fn verify ->
      WritePolicy.normalize(%{
        "version" => 1,
        "allow_writes" => ["src/**"],
        "bash" => %{"verify_prefixes" => ["pnpm typecheck"], "verify" => verify}
      })
    end

    for command <- [
          "pnpm typecheck; rm -rf src",
          "pnpm typecheck && rm -rf src",
          "pnpm typecheck | cat",
          "pnpm typecheck `date`",
          "pnpm typecheck $(date)",
          "pnpm typecheck ../outside",
          ""
        ] do
      assert {:error, %{error: %{kind: :invalid_args, details: details}}} = declare.([command])
      assert details["observed"] == command
      assert details["accepted_prefixes"] == ["pnpm typecheck"]
    end

    assert {:error, %{error: %{kind: :invalid_args, details: details}}} = declare.([42])
    assert details["observed"] == 42

    assert {:error, %{error: %{kind: :invalid_args, details: details}}} =
             declare.(List.duplicate("pnpm typecheck", 9))

    assert details["observed_count"] == 9
    assert details["accepted_max"] == 8
  end

  test "allowlisted verify commands still hit workspace confinement", %{ws: ws} do
    {:ok, policy} =
      WritePolicy.normalize(%{
        "version" => 1,
        "allow_writes" => ["src/**"],
        "bash" => %{
          "verify_prefixes" => ["pnpm typecheck"],
          "verify" => ["pnpm typecheck /etc/passwd"]
        }
      })

    assert {:deny, %{error: %{kind: :write_policy_denied, details: details}}} =
             WritePolicy.authorize_tool(
               policy,
               "bash",
               %{"command" => "pnpm typecheck /etc/passwd"},
               ws
             )

    assert details["matched_rule"] == "outside_workspace"
  end

  test "the operator allowlist declaration itself fails closed on malformed input" do
    declare = fn prefixes ->
      WritePolicy.normalize(%{
        "version" => 1,
        "allow_writes" => ["src/**"],
        "bash" => %{"verify_prefixes" => prefixes, "verify" => []}
      })
    end

    assert {:error, %{error: %{kind: :invalid_args, details: details}}} = declare.("pnpm")
    assert details["observed"] == "pnpm"

    assert {:error, %{error: %{kind: :invalid_args, details: details}}} = declare.([])
    assert details["observed"] == []

    for bad <- ["", "   ", "pnpm && rm", "pnpm | cat", "pnpm ../outside", "pnpm; rm"] do
      assert {:error, %{error: %{kind: :invalid_args, details: details}}} = declare.([bad])
      assert details["observed"] == String.trim(bad)
    end

    assert {:error, %{error: %{kind: :invalid_args, details: details}}} = declare.([42])
    assert details["observed"] == 42

    assert {:error, %{error: %{kind: :invalid_args, details: details}}} =
             declare.(["a b c"])

    assert details["observed"] == "a b c"

    assert {:error, %{error: %{kind: :invalid_args, details: details}}} =
             declare.(List.duplicate("pnpm typecheck", 9))

    assert details["observed_count"] == 9
    assert details["accepted_max"] == 8
  end

  test "an operator allowlist survives the metadata round trip and fails closed on tampering" do
    {:ok, policy} =
      WritePolicy.normalize(%{
        "version" => 1,
        "metadata" => %{"id" => "allowlist-roundtrip"},
        "allow_writes" => ["src/**"],
        "bash" => %{"verify_prefixes" => ["pnpm typecheck"], "verify" => ["pnpm typecheck"]}
      })

    metadata = WritePolicy.metadata(policy)

    assert {:ok, restored} = WritePolicy.from_metadata(metadata)
    assert restored["hash"] == policy["hash"]
    assert restored["bash"] == policy["bash"]

    forged = Map.put(metadata, "bash", %{"verify_prefixes" => ["rm"], "verify" => ["rm -rf src"]})

    assert {:error, %{error: %{kind: :invalid_args, details: details}}} =
             WritePolicy.from_metadata(forged)

    assert details["matched_rule"] == "metadata_hash_mismatch"
  end

  test "narrowing preserves the operator allowlist and keeps the hash verifiable" do
    {:ok, policy} =
      WritePolicy.normalize(%{
        "version" => 1,
        "metadata" => %{"id" => "allowlist-narrow"},
        "allow_writes" => ["src/**"],
        "bash" => %{"verify_prefixes" => ["pnpm typecheck"], "verify" => ["pnpm typecheck"]}
      })

    assert {:ok, narrowed} = WritePolicy.narrow_to_write_set(policy, ["src/app.ts"])

    assert narrowed["bash"] == policy["bash"]
    assert narrowed["hash"] != policy["hash"]

    assert {:ok, restored} = WritePolicy.from_metadata(WritePolicy.metadata(narrowed))
    assert restored["hash"] == narrowed["hash"]
    assert restored["bash"]["verify_prefixes"] == ["pnpm typecheck"]
  end

  test "mix test stays rejected under the Elixir default" do
    assert {:error, %{error: %{kind: :invalid_args, details: details}}} =
             WritePolicy.normalize(%{
               "version" => 1,
               "allow_writes" => ["src/**"],
               "bash" => %{"verify" => ["mix test"]}
             })

    assert details["next_action"] == "keep_test_execution_with_the_orchestrator"
    assert details["accepted_prefixes"] == ["mix format", "mix compile"]
  end

  test "rejects verify test commands with the v1 future-work action" do
    assert {:error, %{error: %{kind: :invalid_args, details: details}}} =
             WritePolicy.normalize(%{
               "version" => 1,
               "allow_writes" => ["src/**"],
               "bash" => %{"verify" => ["mix test test/pixir"]}
             })

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
    assert details["accepted_keys"] == ["verify", "verify_prefixes"]
  end

  test "verify commands still hit workspace confinement before authorization", %{ws: ws} do
    {:ok, policy} =
      WritePolicy.normalize(%{
        "version" => 1,
        "allow_writes" => ["src/**"],
        "bash" => %{"verify" => ["mix format --check-formatted /etc/passwd"]}
      })

    assert {:deny, %{error: %{kind: :write_policy_denied, details: details}}} =
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
    # A denial with no path and no command still has to name what was aimed at,
    # or the confession ships an entry the coordinator cannot reconcile. The
    # aim of a targetless denial is the tool itself.
    assert details["normalized_path"] == "spawn_agent"
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

  # Under a bounded write policy an outside-workspace token is a boundary probe,
  # so the kind is `write_policy_denied` and it strikes (#446); `matched_rule`
  # keeps naming the rule that actually refused the command.
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
      assert {:deny, %{error: %{kind: :write_policy_denied, details: details}}} =
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

  test "narrowed policies survive the posture metadata round-trip" do
    {:ok, policy} =
      WritePolicy.normalize(%{
        "version" => 1,
        "metadata" => %{"id" => "narrow-roundtrip"},
        "allow_writes" => ["app/**"]
      })

    assert {:ok, narrowed} = WritePolicy.narrow_to_write_set(policy, ["app/out.txt"])

    assert narrowed["hash"] != policy["hash"]

    assert {:ok, restored} = WritePolicy.from_metadata(WritePolicy.metadata(narrowed))
    assert restored["hash"] == narrowed["hash"]
    assert restored["allow_writes"] == ["app/out.txt"]
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

  # Confinement and root denials are policy denials like any other: they strike
  # in Turn and land in the `write_denials` confession, where the coordinator
  # reconciles each entry against the policy that refused it. A denial that
  # arrives without `policy_id`/`policy_hash`/`policy_version` cannot be
  # attributed to a policy at all, so identity has to survive every raise site,
  # not only the allowlist ones that go through `denial/4`.
  test "every confinement denial carries the policy identity", %{ws: ws} do
    File.mkdir_p!(Path.join(ws, "real"))
    File.ln_s!(Path.join(ws, "real"), Path.join(ws, "link"))

    {:ok, policy} =
      WritePolicy.normalize(%{
        "version" => 1,
        "metadata" => %{"id" => "task-c"},
        "allow_writes" => ["**/*"]
      })

    denials = [
      {"path_outside_workspace", "../outside.txt"},
      {"workspace_root_not_writable", "."},
      {"symlink_path_component", "link/out.txt"}
    ]

    for {expected_rule, path} <- denials do
      assert {:error, %{error: %{kind: :write_policy_denied, details: details}}} =
               WritePolicy.authorize_tool(policy, "write", %{"path" => path}, ws),
             "expected #{expected_rule} denial for #{path}"

      assert details["matched_rule"] == expected_rule
      assert details["tool"] == "write"
      assert details["policy_id"] == "task-c"
      assert details["policy_hash"] == policy["hash"]
      assert details["policy_version"] == 1
    end
  end

  # The stamp half of the contract: the denial details carry the aim
  # (`requested_path`) *and* the failing component in its own key, so nothing
  # downstream has to reconstruct either. Which of them the confession reports
  # as the target is pinned where it is actually decided — end to end through
  # the Executor and the Log, in `Pixir.Tools.ExecutorTest`.
  test "a symlink denial stamps the requested path and the failing component", %{ws: ws} do
    File.mkdir_p!(Path.join(ws, "real/deep"))
    File.ln_s!(Path.join(ws, "real"), Path.join(ws, "link"))

    {:ok, policy} =
      WritePolicy.normalize(%{
        "version" => 1,
        "metadata" => %{"id" => "task-c"},
        "allow_writes" => ["**/*"]
      })

    assert {:error, %{error: %{kind: :write_policy_denied, details: details}}} =
             WritePolicy.authorize_tool(policy, "write", %{"path" => "link/deep/out.txt"}, ws)

    assert details["matched_rule"] == "symlink_path_component"
    assert details["requested_path"] == "link/deep/out.txt"
    assert details["symlink_component"] == "link"
    assert details["normalized_path"] == "link"
  end

  # The fourth confinement rule, reached when a parent directory cannot be
  # stat-ed. Under root it is unreachable (see `@root_skip`), so the test is
  # skipped with a reason rather than accepting any outcome: the denial itself
  # is asserted unconditionally wherever the rule *is* reachable.
  @tag @root_skip
  test "an uninspectable path denial carries the policy identity too", %{ws: ws} do
    locked = Path.join(ws, "locked")
    File.mkdir_p!(locked)
    File.chmod!(locked, 0o000)
    on_exit(fn -> File.chmod(locked, 0o755) end)

    {:ok, policy} =
      WritePolicy.normalize(%{
        "version" => 1,
        "metadata" => %{"id" => "task-c"},
        "allow_writes" => ["**/*"]
      })

    assert {:error, %{error: %{kind: :write_policy_denied, details: details}}} =
             WritePolicy.authorize_tool(policy, "write", %{"path" => "locked/deep/f.txt"}, ws),
           "expected a path_not_inspectable denial for an unreadable parent directory"

    assert details["matched_rule"] == "path_not_inspectable"
    assert details["requested_path"] == "locked/deep/f.txt"
    assert details["tool"] == "write"
    assert details["policy_id"] == "task-c"
    assert details["policy_hash"] == policy["hash"]
    assert details["policy_version"] == 1
  end

  # The confined path is the only record of what the worker aimed at: the target
  # never gets normalized, so `requested_path` is what the confession reports.
  test "an outside-workspace write reports the path it requested", %{ws: ws} do
    {:ok, policy} = WritePolicy.normalize(%{"version" => 1, "allow_writes" => ["**/*"]})

    assert {:error, %{error: %{kind: :write_policy_denied, details: details}}} =
             WritePolicy.authorize_tool(policy, "write", %{"path" => "../escape.txt"}, ws)

    assert details["requested_path"] == "../escape.txt"
    assert details["normalized_path"] == nil
  end

  test "denies unknown mutating tools under active policy", %{ws: ws} do
    {:ok, policy} = WritePolicy.normalize(%{"version" => 1, "allow_writes" => ["src/**"]})

    assert {:deny, %{error: %{kind: :write_policy_denied, details: details}}} =
             WritePolicy.authorize_tool(policy, "future_write_tool", %{}, ws)

    assert details["matched_rule"] == "unsupported_mutating_tool"
    assert details["normalized_path"] == "future_write_tool"
  end

  test "rejects absolute and parent-directory policy rules" do
    for rule <- ["/tmp/out.txt", "../out.txt", "src/../out.txt", "src/"] do
      assert {:error, %{error: %{kind: :invalid_args, details: details}}} =
               WritePolicy.normalize(%{"version" => 1, "allow_writes" => [rule]})

      assert details["rule"] == rule
    end
  end

  test "rejects durable metadata whose allow list was forged under a narrow hash" do
    {:ok, narrow} =
      WritePolicy.normalize(%{
        "version" => 1,
        "metadata" => %{"id" => "forgery-test"},
        "allow_writes" => ["src/**"]
      })

    forged =
      narrow
      |> WritePolicy.metadata()
      |> Map.put("allow_writes", ["**/*"])

    assert {:error, %{error: %{kind: :invalid_args, details: details}}} =
             WritePolicy.from_metadata(forged)

    assert details["matched_rule"] == "metadata_hash_mismatch"
    assert details["stored_hash"] == narrow["hash"]
    refute details["computed_hash"] == narrow["hash"]
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
