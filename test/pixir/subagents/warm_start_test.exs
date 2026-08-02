defmodule Pixir.Subagents.WarmStartTest do
  use ExUnit.Case, async: false

  import Pixir.Test.RawLogHelpers

  alias Pixir.{Event, Fork, Log, Provider.Cache}
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
      assert {:ok, result} = WarmStart.seed_child_log(child, seed, workspace: ws)

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
      assert {:ok, result} = WarmStart.seed_child_log(child, seed, workspace: ws)
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
               WarmStart.seed_child_log(child, seed, workspace: ws, child_workspace: child_ws)

      assert result["child_workspace"] == child_ws

      # the Log really lives in the child workspace, not the seed's
      assert {:ok, history} = Log.fold(child, workspace: child_ws)

      [fork | _rest] = history
      assert fork.type == :session_fork
      assert fork.seq == 0
      assert fork.data["parent_workspace"] == ws
      assert fork.data["child_workspace"] == child_ws
      refute fork.data["child_workspace"] == fork.data["parent_workspace"]
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
      assert {:ok, _} = WarmStart.seed_child_log(child, seed, workspace: ws)
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
      assert {:ok, result} = WarmStart.seed_child_log(child, seed, workspace: ws)
      assert result["fork_root_session_id"] == "root-family"

      assert {:ok, history} = Log.fold(child, workspace: ws)
      assert Fork.fork_root_session_id(history, child) == "root-family"
    end

    test "appends a runtime-authored boundary marker after the replayed prefix", %{ws: ws} do
      seed = "seed-marker"
      seed_log(ws, [Event.user_message(seed, "one"), Event.assistant_message(seed, "two")])

      child = "child-marker"
      assert {:ok, _} = WarmStart.seed_child_log(child, seed, workspace: ws)
      assert {:ok, history} = Log.fold(child, workspace: ws)

      marker = List.last(history)
      assert marker.type == :user_message
      assert marker.data["lineage_boundary"] == true
      assert marker.data["author"] == "runtime"
      assert marker.data["seed_session_id"] == seed

      text = marker.data["text"]
      assert text =~ seed
      assert text =~ ~r/historical evidence/i
      assert text =~ ~r/may have changed/i
      assert text =~ ~r/only .*follows/i
      assert text =~ ~r/re-?verif/i

      # The marker is the last event in the seeded Log: the child's first new
      # user message is appended after it by the Turn.
      assert Enum.at(history, -2).type == :assistant_message
    end

    test "refuses to seed into a child session id that already has a Log", %{ws: ws} do
      seed = "seed-clash"
      seed_log(ws, [Event.user_message(seed, "one")])

      child = "child-clash"
      seed_log(ws, [Event.user_message(child, "already here")])

      assert {:error, error} = WarmStart.seed_child_log(child, seed, workspace: ws)
      assert error_kind(error) == :already_exists
    end

    test "leaves no partial child Log when the seed is unusable", %{ws: ws} do
      child = "child-no-partial"
      assert {:error, _} = WarmStart.seed_child_log(child, "seed-absent", workspace: ws)
      assert {:ok, false} = Log.exists(child, workspace: ws)
    end

    test "copies referenced Session Resources into the child store", %{ws: ws} do
      seed = "seed-resources"
      bytes = "payload bytes"
      encoded = Base.encode64(bytes)

      {:ok, [descriptor]} =
        Pixir.SessionResources.ingest_attachments(
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
      assert {:ok, _} = WarmStart.seed_child_log(child, seed, workspace: ws)

      assert {:ok, data_url} = Pixir.SessionResources.data_url(child, descriptor, workspace: ws)
      assert data_url == "data:image/png;base64,#{encoded}"
    end
  end

  describe "cache family" do
    test "a warm-started child shares the seed's session-family segment", %{ws: ws} do
      seed = "seed-cache"
      seed_log(ws, [Event.user_message(seed, "one"), Event.assistant_message(seed, "two")])

      child = "child-cache"
      cold = "cold-cache"
      assert {:ok, _} = WarmStart.seed_child_log(child, seed, workspace: ws)

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
