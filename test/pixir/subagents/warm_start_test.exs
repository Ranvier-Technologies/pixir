defmodule Pixir.Subagents.WarmStartTest do
  use ExUnit.Case, async: false

  import Pixir.Test.RawLogHelpers

  alias Pixir.{Event, Fork, Log, Paths, Provider.Cache, SessionResources, Subagents, Tool}
  alias Pixir.Permissions.WritePolicy
  alias Pixir.Subagents.WarmStart

  setup do
    ws = Path.join(System.tmp_dir!(), "pixir-warm-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf!(ws) end)
    {:ok, ws: ws}
  end

  defp seed_log(ws, events) do
    events
    |> Enum.with_index()
    |> Enum.each(fn {event, seq} ->
      assert {:ok, _} = Log.append(Event.with_seq(event, seq), workspace: ws)
    end)
  end

  describe "validate/2" do
    test "accepts an existing non-empty session in the workspace", %{ws: ws} do
      seed = "seed-ok"

      seed_log(ws, [
        Event.user_message(seed, "read the file"),
        Event.assistant_message(seed, "ok")
      ])

      assert {:ok, %{"seed_session_id" => ^seed, "fork_root_session_id" => ^seed}} =
               WarmStart.validate(seed, workspace: ws)
    end

    test "rejects a seed session that does not exist", %{ws: ws} do
      assert {:error, error} = WarmStart.validate("seed-missing", workspace: ws)
      assert error_kind(error) == :not_found
      assert next_actions(error) != []
    end

    test "rejects a seed session whose log is empty of replayable events", %{ws: ws} do
      seed = "seed-empty"
      seed_log(ws, [Event.provider_usage(seed, %{"usage_summary" => %{"total_tokens" => 1}})])

      assert {:error, error} = WarmStart.validate(seed, workspace: ws)
      assert error_kind(error) == :not_found
      assert next_actions(error) != []
    end

    test "rejects a seed session id that is not a valid session id", %{ws: ws} do
      assert {:error, error} = WarmStart.validate("../escape", workspace: ws)
      assert error_kind(error) == :invalid_args
    end

    test "rejects a seed session that lives outside the delegate workspace", %{ws: ws} do
      other =
        Path.join(System.tmp_dir!(), "pixir-warm-other-#{System.unique_integer([:positive])}")

      File.mkdir_p!(other)
      on_exit(fn -> File.rm_rf!(other) end)

      seed = "seed-elsewhere"
      seed_log(other, [Event.user_message(seed, "hello")])

      assert {:error, error} = WarmStart.validate(seed, workspace: ws)
      assert error_kind(error) == :not_found
    end
  end

  describe "seed_child_log/3" do
    test "writes the full replayable prefix with child ids and child-local seqs", %{ws: ws} do
      seed = "seed-full"

      seed_log(ws, [
        Event.user_message(seed, "first"),
        Event.assistant_message(seed, "second"),
        Event.provider_usage(seed, %{"usage_summary" => %{"total_tokens" => 5}}),
        Event.user_message(seed, "third")
      ])

      child = "child-full"
      assert {:ok, result} = seed_child_log(child, seed, workspace: ws)

      assert result["seed_session_id"] == seed
      assert result["warm_started"] == true
      assert result["replay_event_count"] == 3

      assert {:ok, history} = Log.fold(child, workspace: ws)
      assert Enum.all?(history, &(&1.session_id == child))
      assert Enum.map(history, & &1.seq) == Enum.to_list(0..(length(history) - 1))

      [fork | rest] = history
      assert fork.type == :session_fork
      assert fork.seq == 0
      assert fork.data["parent_session_id"] == seed
      assert fork.data["fork_root_session_id"] == seed
      assert fork.data["replay_event_count"] == 3
      assert fork.data["strategy"] == "replay_v1"

      replayed = Enum.take(rest, 3)
      assert Enum.map(replayed, & &1.type) == [:user_message, :assistant_message, :user_message]
      assert Enum.map(replayed, & &1.data["text"]) == ["first", "second", "third"]
    end

    # Warm start reads the seed through Log.fold/2, a cold read path. Every other test
    # here builds the seed with the same Event constructors the decoder round-trips, so
    # a decode regression could not fail them. This one seeds from raw NDJSON bytes.
    test "replays a prefix seeded from raw NDJSON on disk", %{ws: ws} do
      seed = "seed-raw"

      write_raw_log(ws, seed, [
        raw_event(seed, 0, "user_message", %{"text" => "first"}),
        raw_event(seed, 1, "assistant_message", %{"text" => "second"}),
        raw_event(seed, 2, "provider_usage", %{"usage_summary" => %{"total_tokens" => 5}}),
        raw_event(seed, 3, "user_message", %{"text" => "third"})
      ])

      child = "child-raw"
      assert {:ok, result} = seed_child_log(child, seed, workspace: ws)
      assert result["warm_started"] == true
      assert result["replay_event_count"] == 3

      assert {:ok, history} = Log.fold(child, workspace: ws)
      assert Enum.all?(history, &(&1.session_id == child))
      assert Enum.map(history, & &1.seq) == Enum.to_list(0..(length(history) - 1))

      [fork | rest] = history
      assert fork.type == :session_fork
      assert fork.data["parent_session_id"] == seed
      assert fork.data["replay_event_count"] == 3

      replayed = Enum.take(rest, 3)
      assert Enum.map(replayed, & &1.type) == [:user_message, :assistant_message, :user_message]
      assert Enum.map(replayed, & &1.data["text"]) == ["first", "second", "third"]
    end

    # An isolated child runs in a snapshot dir that excludes .pixir, so its Log lives
    # somewhere other than the seed's workspace. The seq-0 lineage record must name the
    # child's OWN workspace, not the seed's, or the record misreports where the child
    # actually is (#435).
    test "the seq-0 record names the child's own workspace when they differ", %{ws: ws} do
      seed = "seed-cross-ws"

      seed_log(ws, [
        Event.user_message(seed, "first"),
        Event.assistant_message(seed, "second")
      ])

      child_ws = Path.join(ws, "child-root")
      File.mkdir_p!(child_ws)
      child = "child-cross-ws"

      assert {:ok, result} =
               seed_child_log(child, seed,
                 workspace: ws,
                 child_workspace: child_ws,
                 permission_posture: permission_posture(child_ws, %{workspace_mode: "isolated"})
               )

      assert result["child_workspace"] == child_ws

      # the Log really lives in the child workspace, not the seed's
      assert {:ok, history} = Log.fold(child, workspace: child_ws)

      [fork | _rest] = history
      assert fork.type == :session_fork
      assert fork.seq == 0
      assert fork.data["parent_workspace"] == ws
      assert fork.data["child_workspace"] == child_ws
      refute fork.data["child_workspace"] == fork.data["parent_workspace"]

      assert {:ok, posture} = Subagents.resume_posture(child, workspace: child_ws)
      assert posture.permission_mode == :read_only
      assert posture.workspace_mode == "isolated"
      assert posture.workspace == child_ws
    end

    test "never replays provider_usage, history_compaction, session_fork, branch_summary", %{
      ws: ws
    } do
      seed = "seed-excluded"

      seed_log(ws, [
        Event.session_fork(seed, %{
          "parent_session_id" => "grand",
          "fork_root_session_id" => "root"
        }),
        Event.user_message(seed, "keep"),
        Event.provider_usage(seed, %{"usage_summary" => %{"total_tokens" => 5}}),
        Event.history_compaction(seed, %{"summary" => "compacted"}),
        Event.branch_summary(seed, %{"summary" => "branchy"})
      ])

      child = "child-excluded"
      assert {:ok, _} = seed_child_log(child, seed, workspace: ws)
      assert {:ok, history} = Log.fold(child, workspace: ws)

      replayed = Enum.drop(history, 1)

      refute Enum.any?(
               replayed,
               &(&1.type in [:provider_usage, :history_compaction, :branch_summary])
             )

      refute Enum.any?(replayed, &(&1.type == :session_fork))
    end

    test "inherits the seed's fork root when the seed was itself forked", %{ws: ws} do
      seed = "seed-forked"

      seed_log(ws, [
        Event.session_fork(seed, %{
          "parent_session_id" => "grand",
          "fork_root_session_id" => "root-family"
        }),
        Event.user_message(seed, "hello")
      ])

      child = "child-forked"
      assert {:ok, result} = seed_child_log(child, seed, workspace: ws)
      assert result["fork_root_session_id"] == "root-family"

      assert {:ok, history} = Log.fold(child, workspace: ws)
      assert Fork.fork_root_session_id(history, child) == "root-family"
    end

    test "appends a runtime-authored boundary marker after the replayed prefix", %{ws: ws} do
      seed = "seed-marker"
      seed_log(ws, [Event.user_message(seed, "one"), Event.assistant_message(seed, "two")])

      child = "child-marker"
      assert {:ok, _} = seed_child_log(child, seed, workspace: ws)
      assert {:ok, history} = Log.fold(child, workspace: ws)

      marker = Enum.at(history, -2)
      posture = List.last(history)
      assert marker.type == :user_message
      assert marker.data["lineage_boundary"] == true
      assert marker.data["author"] == "runtime"
      assert marker.data["seed_session_id"] == seed

      assert posture.type == :subagent_event
      assert posture.data["event"] == "permission_posture"

      text = marker.data["text"]
      assert text =~ seed
      assert text =~ ~r/historical evidence/i
      assert text =~ ~r/may have changed/i
      assert text =~ ~r/only .*follows/i
      assert text =~ ~r/re-?verif/i

      # The marker and current posture are the final atomic pair in the seeded
      # Log; the child's first new user message is appended after them by Turn.
      assert Enum.at(history, -3).type == :assistant_message
      assert posture.seq == marker.seq + 1
    end

    test "creates current posture immediately after the runtime boundary", %{ws: ws} do
      seed = "seed-atomic-posture"
      seed_log(ws, [Event.user_message(seed, "one"), Event.assistant_message(seed, "two")])

      child = "child-atomic-posture"

      assert {:ok, _} =
               seed_child_log(child, seed,
                 workspace: ws,
                 permission_posture: permission_posture(ws)
               )

      assert {:ok, history} = Log.fold(child, workspace: ws)
      [boundary, posture] = Enum.take(history, -2)

      assert boundary.type == :user_message
      assert boundary.data["marker_kind"] == WarmStart.boundary_marker_kind()
      assert posture.type == :subagent_event
      assert posture.data["event"] == "permission_posture"
      assert posture.seq == boundary.seq + 1
    end

    test "the seeding fold owns posture lineage instead of an earlier validation snapshot", %{
      ws: ws
    } do
      seed = "seed-lineage-race"
      seed_log(ws, [Event.user_message(seed, "one")])

      assert {:ok, %{"fork_root_session_id" => ^seed}} = WarmStart.validate(seed, workspace: ws)

      assert {:ok, _} =
               Log.append(
                 Event.with_seq(
                   Event.session_fork(seed, %{
                     "parent_session_id" => "new-parent",
                     "fork_root_session_id" => "new-root"
                   }),
                   1
                 ),
                 workspace: ws
               )

      child = "child-lineage-race"
      assert {:ok, result} = seed_child_log(child, seed, workspace: ws)
      assert result["fork_root_session_id"] == "new-root"

      assert {:ok, history} = Log.fold(child, workspace: ws)
      posture = List.last(history)
      assert posture.data["event"] == "permission_posture"
      assert posture.data["warm_start"]["fork_root_session_id"] == "new-root"
      assert posture.data["warm_start"]["replay_event_count"] == 1
    end

    test "nested warm segments restore their own bounded and read-only posture", %{ws: ws} do
      root = "seed-root-auto-nested"

      seed_log(ws, [
        Event.subagent_event(root, %{
          "event" => "permission_posture",
          "scope" => "session",
          "lineage" => "root",
          "source" => "root_session_start",
          "permission_mode" => "auto",
          "write_policy" => nil,
          "workspace_mode" => "shared",
          "workspace" => ws
        }),
        Event.user_message(root, "root context")
      ])

      {:ok, bounded_policy} =
        WritePolicy.normalize(%{
          "version" => 1,
          "metadata" => %{"id" => "nested-bounded"},
          "allow_writes" => ["lib/**"],
          "deny_writes" => [],
          "bash" => "disabled"
        })

      bounded_child = "child-bounded-nested"

      assert {:ok, _} =
               seed_child_log(bounded_child, root,
                 workspace: ws,
                 permission_posture:
                   permission_posture(ws, %{
                     subagent_id: "sub_bounded",
                     permission_mode: :auto,
                     write_policy: bounded_policy
                   })
               )

      assert {:ok, bounded} = Subagents.resume_posture(bounded_child, workspace: ws)
      assert bounded.permission_mode == :auto
      assert bounded.write_policy["hash"] == bounded_policy["hash"]
      assert bounded.lineage == :child

      read_only_child = "child-read-only-nested"

      assert {:ok, _} =
               seed_child_log(read_only_child, bounded_child,
                 workspace: ws,
                 permission_posture:
                   permission_posture(ws, %{
                     subagent_id: "sub_read_only",
                     parent_session_id: bounded_child
                   })
               )

      assert {:ok, history} = Log.fold(read_only_child, workspace: ws)
      assert Enum.count(history, &(&1.data["lineage_boundary"] == true)) == 2

      assert Enum.count(
               history,
               &(&1.type == :subagent_event and &1.data["event"] == "permission_posture")
             ) == 3

      assert {:ok, read_only} = Subagents.resume_posture(read_only_child, workspace: ws)
      assert read_only.permission_mode == :read_only
      assert read_only.write_policy == nil
      assert read_only.lineage == :child

      nested_fork = "fork-of-nested-warm"
      assert {:ok, _} = Fork.fork(read_only_child, workspace: ws, child_session_id: nested_fork)
      assert {:ok, forked_posture} = Subagents.resume_posture(nested_fork, workspace: ws)
      assert forked_posture.permission_mode == :read_only
      assert forked_posture.write_policy == nil
      assert forked_posture.lineage == :child
    end

    test "refuses to seed into a child session id that already has a Log", %{ws: ws} do
      seed = "seed-clash"
      seed_log(ws, [Event.user_message(seed, "one")])

      child = "child-clash"
      seed_log(ws, [Event.user_message(child, "already here")])

      assert {:error, error} = seed_child_log(child, seed, workspace: ws)
      assert error_kind(error) == :already_exists
    end

    test "leaves no partial child Log when the seed is unusable", %{ws: ws} do
      child = "child-no-partial"
      assert {:error, _} = seed_child_log(child, "seed-absent", workspace: ws)
      assert {:ok, false} = Log.exists(child, workspace: ws)
    end

    test "rejects malformed posture without reflecting arbitrary values", %{ws: ws} do
      seed = "seed-malformed-posture"
      child = "child-malformed-posture"
      secret = "C5A_SECRET_POSTURE_SENTINEL"
      seed_log(ws, [Event.user_message(seed, "one")])

      assert {:error, error} =
               WarmStart.seed_child_log(child, seed,
                 workspace: ws,
                 permission_posture: %{secret => secret}
               )

      assert error_kind(error) == :invalid_args
      refute inspect(error) =~ secret
      assert {:ok, false} = Log.exists(child, workspace: ws)
    end

    test "copies referenced Session Resources into the child store without rewriting descriptors",
         %{
           ws: ws
         } do
      seed = "seed-resources"
      bytes = "payload bytes"
      encoded = Base.encode64(bytes)

      {:ok, [descriptor]} =
        SessionResources.ingest_attachments(
          seed,
          [
            %{
              "type" => "image",
              "name" => "screen.png",
              "mimeType" => "image/png",
              "dataUrl" => "data:image/png;base64,#{encoded}"
            }
          ],
          workspace: ws
        )

      seed_log(ws, [
        Event.user_message(seed, "look at this", resources: [descriptor]),
        Event.assistant_message(seed, "ok")
      ])

      child = "child-resources"
      assert {:ok, _} = seed_child_log(child, seed, workspace: ws)

      assert {:ok, data_url} = SessionResources.data_url(child, descriptor, workspace: ws)
      assert data_url == "data:image/png;base64,#{encoded}"

      assert {:ok, child_history} = Log.fold(child, workspace: ws)
      replayed_message = Enum.find(child_history, &(&1.data["text"] == "look at this"))
      assert replayed_message.data["resources"] == [descriptor]

      [replayed_descriptor] = replayed_message.data["resources"]
      assert replayed_descriptor["store_ref"] =~ "session://#{seed}/resources/"
    end

    test "copies referenced Session Resources into a cross-workspace child store", %{ws: ws} do
      seed = "seed-cross-workspace-resources"
      child = "child-cross-workspace-resources"
      child_ws = Path.join(ws, "isolated-resource-child")
      File.mkdir_p!(child_ws)
      bytes = "isolated payload bytes"

      [descriptor] = seed_with_resources(ws, seed, [bytes])

      assert {:ok, _} =
               seed_child_log(child, seed,
                 workspace: ws,
                 child_workspace: child_ws,
                 permission_posture: permission_posture(child_ws, %{workspace_mode: "isolated"})
               )

      assert {:ok, data_url} =
               SessionResources.data_url(child, descriptor, workspace: child_ws)

      assert data_url == "data:image/png;base64,#{Base.encode64(bytes)}"
      assert_child_resource_dirs_absent(ws, child)
      assert Path.wildcard(Paths.session_resources_dir(child, child_ws) <> ".staging*") == []

      assert {:ok, child_history} = Log.fold(child, workspace: child_ws)
      replayed_message = Enum.find(child_history, &(&1.data["text"] == "resource message"))
      assert replayed_message.data["resources"] == [descriptor]
    end

    test "compensates deterministic partial resource copies in shared and cross workspaces", %{
      ws: ws
    } do
      fail_second_copy = fn
        %{index: 0} -> :ok
        %{index: 1} -> {:error, :injected_copy_failure}
      end

      for {mode, child_ws} <- [
            {"shared", ws},
            {"isolated", Path.join(ws, "isolated-copy-compensation")}
          ] do
        File.mkdir_p!(child_ws)
        seed = "seed-copy-compensation-#{mode}"
        child = "child-copy-compensation-#{mode}"
        descriptors = seed_with_resources(ws, seed, ["first", "second"])

        assert {:error, %{error: %{kind: :write_failed}}} =
                 seed_child_log(child, seed,
                   workspace: ws,
                   child_workspace: child_ws,
                   permission_posture: permission_posture(child_ws, %{workspace_mode: mode}),
                   resource_copy_failpoint: fail_second_copy
                 )

        assert_seed_payloads_readable(ws, seed, descriptors)
        assert_child_resource_dirs_absent(child_ws, child)
        assert_child_resource_dirs_absent(ws, child)
        assert {:ok, false} = Log.exists(child, workspace: child_ws)
      end
    end

    test "compensates finalized resources when Log creation fails in shared and cross workspaces",
         %{ws: ws} do
      for {mode, child_ws} <- [
            {"shared", ws},
            {"isolated", Path.join(ws, "isolated-log-compensation")}
          ] do
        File.mkdir_p!(child_ws)
        seed = "seed-log-compensation-#{mode}"
        child = "child-log-compensation-#{mode}"
        descriptors = seed_with_resources(ws, seed, ["finalized"])
        test_pid = self()

        log_create_failpoint = fn ^child, _events, log_opts ->
          final = Paths.session_resources_dir(child, Keyword.fetch!(log_opts, :workspace))
          send(test_pid, {:warm_log_create_saw_final_resources, mode, File.dir?(final)})
          {:error, Tool.error(:log_write_failed, "injected Log.create_session failure", %{})}
        end

        assert {:error, %{error: %{kind: :log_write_failed}}} =
                 seed_child_log(child, seed,
                   workspace: ws,
                   child_workspace: child_ws,
                   permission_posture: permission_posture(child_ws, %{workspace_mode: mode}),
                   log_create_fun: log_create_failpoint
                 )

        assert_received {:warm_log_create_saw_final_resources, ^mode, true}
        assert_seed_payloads_readable(ws, seed, descriptors)
        assert_child_resource_dirs_absent(child_ws, child)
        assert_child_resource_dirs_absent(ws, child)
        assert {:ok, false} = Log.exists(child, workspace: child_ws)
      end
    end
  end

  describe "cache family" do
    test "a warm-started child shares the seed's session-family segment", %{ws: ws} do
      seed = "seed-cache"
      seed_log(ws, [Event.user_message(seed, "one"), Event.assistant_message(seed, "two")])

      child = "child-cache"
      cold = "cold-cache"
      assert {:ok, _} = seed_child_log(child, seed, workspace: ws)

      assert {:ok, warm_history} = Log.fold(child, workspace: ws)
      warm_root = Fork.fork_root_session_id(warm_history, child)

      base = %{model: "gpt-5", mode: :auto, tools: ["read"], skill_index: []}

      {:ok, seed_meta} = Cache.metadata(Map.put(base, :session_id, seed))

      {:ok, warm_meta} =
        Cache.metadata(Map.merge(base, %{session_id: child, fork_root_session_id: warm_root}))

      {:ok, cold_meta} = Cache.metadata(Map.put(base, :session_id, cold))

      assert warm_meta["session_family_hash"] == seed_meta["session_family_hash"]
      assert warm_meta["prompt_cache_key"] == seed_meta["prompt_cache_key"]
      refute warm_meta["prompt_cache_key"] == cold_meta["prompt_cache_key"]
    end
  end

  defp seed_with_resources(workspace, seed, payloads) do
    attachments =
      Enum.map(payloads, fn bytes ->
        %{
          "type" => "image",
          "name" => "#{bytes}.png",
          "mimeType" => "image/png",
          "dataUrl" => "data:image/png;base64,#{Base.encode64(bytes)}"
        }
      end)

    assert {:ok, descriptors} =
             SessionResources.ingest_attachments(seed, attachments, workspace: workspace)

    seed_log(workspace, [
      Event.user_message(seed, "resource message", resources: descriptors),
      Event.assistant_message(seed, "resource reply")
    ])

    descriptors
  end

  defp assert_seed_payloads_readable(workspace, seed, descriptors) do
    Enum.each(descriptors, fn descriptor ->
      assert {:ok, data_url} =
               SessionResources.data_url(seed, descriptor, workspace: workspace)

      assert String.starts_with?(data_url, "data:image/png;base64,")
    end)
  end

  defp assert_child_resource_dirs_absent(workspace, child_session_id) do
    final = Paths.session_resources_dir(child_session_id, workspace)
    refute File.exists?(final)
    assert Path.wildcard(final <> ".staging*") == []
  end

  defp seed_child_log(child, seed, opts) do
    posture_workspace = Keyword.get(opts, :child_workspace, Keyword.fetch!(opts, :workspace))

    opts =
      Keyword.put_new(
        opts,
        :permission_posture,
        permission_posture(Path.expand(posture_workspace))
      )

    WarmStart.seed_child_log(child, seed, opts)
  end

  defp permission_posture(ws, overrides \\ %{}) do
    Map.merge(
      %{
        subagent_id: "sub_atomic",
        parent_session_id: "parent_atomic",
        permission_mode: :read_only,
        write_policy: nil,
        workspace_mode: "shared",
        workspace: ws
      },
      overrides
    )
  end

  defp error_kind(%{error: %{kind: kind}}), do: kind
  defp error_kind(%{"error" => %{"kind" => kind}}) when is_binary(kind), do: String.to_atom(kind)
  defp error_kind(%{"kind" => kind}) when is_binary(kind), do: String.to_atom(kind)
  defp error_kind(other), do: flunk("unexpected error shape: #{inspect(other)}")

  defp next_actions(%{error: %{details: details}}),
    do: Map.get(details, :next_actions) || Map.get(details, "next_actions") || []

  defp next_actions(%{"error" => %{"details" => details}}),
    do: Map.get(details, "next_actions") || []

  defp next_actions(_other), do: []
end
