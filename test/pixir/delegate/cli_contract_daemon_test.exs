defmodule Pixir.Delegate.CLIContractDaemonTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Pixir.Delegate.CLIContract

  defmodule UnavailableDaemonClient do
    def call(_action, _body, _opts) do
      {:error,
       %{
         "ok" => false,
         "status" => "rejected",
         "kind" => "daemon_unavailable",
         "message" => "test daemon unavailable",
         "details" => %{
           "fallback_allowed" => true,
           "next_actions" => ["start_pixir_delegate_daemon_or_use_current_runtime_fallback"]
         }
       }}
    end
  end

  defmodule AuthFailedDaemonClient do
    def call(_action, _body, _opts) do
      {:error,
       %{
         "ok" => false,
         "status" => "rejected",
         "kind" => "daemon_auth_failed",
         "message" => "test daemon auth failed",
         "details" => %{"fallback_allowed" => false}
       }}
    end
  end

  defmodule ReachableDaemonClient do
    def call("delegate_attach", %{"handle" => handle}, _opts) do
      {:ok,
       %{
         "ok" => true,
         "status" => "running",
         "kind" => "delegate_attach",
         "delegate_id" => handle,
         "parent_session_id" => "parent-reachable",
         "complete" => false,
         "summary" => "attached through daemon",
         "attach" => %{
           "mode" => "one_shot_snapshot",
           "streaming" => false,
           "source" => "durable_session_log"
         },
         "owner" => %{
           "state" => "live_delegate_owner",
           "reachable" => true,
           "runtime_residency" => %{"model" => "daemon_ipc"}
         },
         "runtime_residency" => %{"model" => "daemon_ipc"}
       }}
    end

    def call(action, body, opts), do: UnavailableDaemonClient.call(action, body, opts)
  end

  defmodule SequenceDaemonClient do
    def call("delegate_attach", %{"handle" => handle}, _opts) do
      count = Process.get({__MODULE__, :attach_calls}, 0) + 1
      Process.put({__MODULE__, :attach_calls}, count)

      status =
        case count do
          1 -> "running"
          _ -> "completed"
        end

      {:ok,
       %{
         "ok" => true,
         "status" => status,
         "complete" => status == "completed",
         "kind" => "delegate_attach",
         "delegate_id" => handle,
         "parent_session_id" => "parent-sequence",
         "summary" => "sequence attach #{status}",
         "counts" => %{"total" => 1, status => 1},
         "retry_after_ms" => 1,
         "attach" => %{
           "mode" => "one_shot_snapshot",
           "streaming" => false,
           "source" => "durable_session_log",
           "status" => status,
           "complete" => status == "completed",
           "service_state" => "live_delegate_owner"
         },
         "owner" => %{
           "state" => "live_delegate_owner",
           "reachable" => true,
           "runtime_residency" => %{"model" => "daemon_ipc"}
         },
         "runtime_residency" => %{"model" => "daemon_ipc"}
       }}
    end

    def call(action, body, opts), do: UnavailableDaemonClient.call(action, body, opts)

    def follow(
          "delegate_attach_follow",
          %{"handle" => handle, "wait_horizon_ms" => wait},
          emit,
          _opts
        )
        when is_integer(wait) do
      Process.put({__MODULE__, :follow_calls}, Process.get({__MODULE__, :follow_calls}, 0) + 1)

      running = payload(handle, "running")
      completed = payload(handle, "completed")

      emit.(Pixir.Delegate.Progress.frame(running, 1, source: "live_owner_stream"))
      emit.(Pixir.Delegate.Progress.frame(completed, 2, source: "live_owner_stream"))

      {:ok,
       Pixir.Delegate.Progress.annotate(completed, %{
         "frame_count" => 2,
         "follow_requested" => true,
         "followed" => true,
         "follow_transport" => "daemon_stream",
         "wait_horizon_ms" => wait,
         "wait_horizon_exhausted" => false,
         "terminal_observed" => true,
         "follow_error_count" => 0,
         "source" => "live_owner_stream",
         "owner_backed" => true
       })}
    end

    defp payload(handle, status) do
      %{
        "ok" => true,
        "status" => status,
        "complete" => status == "completed",
        "kind" => "delegate_attach",
        "delegate_id" => handle,
        "parent_session_id" => "parent-sequence",
        "summary" => "sequence attach #{status}",
        "counts" => %{"total" => 1, status => 1},
        "retry_after_ms" => 1,
        "attach" => %{
          "mode" =>
            if(status == "completed", do: "owner_pushed_follow", else: "one_shot_snapshot"),
          "streaming" => status != "completed",
          "source" => "live_owner_stream",
          "status" => status,
          "complete" => status == "completed",
          "service_state" => "live_delegate_owner"
        },
        "owner" => %{
          "state" => "live_delegate_owner",
          "reachable" => true,
          "runtime_residency" => %{"model" => "daemon_ipc"}
        },
        "runtime_residency" => %{"model" => "daemon_ipc"}
      }
    end
  end

  defmodule FakeAsync do
    def start(request, spec, spec_meta, opts) do
      {:ok,
       %{
         "ok" => true,
         "status" => "running",
         "kind" => "delegate_start",
         "delegate_id" => "dlg1_local",
         "parent_session_id" => "parent-local",
         "workspace" => request.workspace,
         "task" => spec["task"],
         "planned_child_count" => spec_meta["planned_child_count"],
         "runtime_opts_seen" => Keyword.get(opts, :runtime_opts),
         "runtime_residency" => %{"model" => "current_beam_runtime"},
         "owner" => %{
           "state" => "live_delegate_owner",
           "runtime_residency" => %{"model" => "current_beam_runtime"}
         },
         "summary" => "started locally"
       }}
    end

    def status(handle, _opts) do
      {:ok,
       %{
         "ok" => false,
         "status" => "running",
         "kind" => "delegate_status",
         "delegate_id" => handle,
         "summary" => "status locally"
       }}
    end

    def attach(handle, _opts) do
      {:ok,
       %{
         "ok" => true,
         "status" => "running",
         "kind" => "delegate_attach",
         "delegate_id" => handle,
         "summary" => "attached locally",
         "attach" => %{"mode" => "one_shot_snapshot", "streaming" => false}
       }}
    end

    def cancel(handle, _opts) do
      {:ok,
       %{
         "ok" => true,
         "status" => "cancelled",
         "kind" => "delegate_cancel",
         "delegate_id" => handle,
         "summary" => "cancelled locally"
       }}
    end
  end

  defmodule FakeDaemonCommand do
    def run("foreground", _opts) do
      {:ok,
       %{
         "ok" => true,
         "status" => "running",
         "kind" => "delegate_daemon",
         "summary" => "fake daemon",
         after_render: fn -> send(self(), :fake_daemon_after_render) end
       }}
    end
  end

  setup do
    ws =
      Path.join(
        System.tmp_dir!(),
        "pixir-cli-contract-daemon-" <>
          Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf!(ws) end)
    %{ws: ws}
  end

  test "start requires a resident daemon when daemon is unavailable", %{ws: ws} do
    spec = Jason.encode!(%{"contract_version" => 1, "strategy" => "subagents", "task" => "x"})

    assert {:error,
            %{
              payload: %{
                "kind" => "daemon_required",
                "status" => "rejected",
                "details" => %{
                  "reason" => "start_without_resident_owner_would_not_survive_cli_process_exit",
                  "daemon_error" => %{"kind" => "daemon_unavailable"}
                }
              },
              exit_code: 5
            }} =
             CLIContract.run(["start", "--spec", "-", "--json"],
               workspace: ws,
               read_stdin: fn -> spec end,
               async: FakeAsync,
               daemon_client: UnavailableDaemonClient
             )
  end

  test "start preserves non-empty runtime_opts only through explicit current-runtime seam", %{
    ws: ws
  } do
    spec = Jason.encode!(%{"contract_version" => 1, "strategy" => "subagents", "task" => "x"})

    assert {:ok,
            %{
              payload: %{
                "kind" => "delegate_start",
                "runtime_opts_seen" => [provider: StubProvider],
                "daemon_fallback" => %{
                  "reason" => "daemon_runtime_opts_unsupported",
                  "fallback" => "current_runtime_or_durable_snapshot"
                }
              }
            }} =
             CLIContract.run(["start", "--spec", "-", "--json"],
               workspace: ws,
               read_stdin: fn -> spec end,
               async: FakeAsync,
               daemon_client: AuthFailedDaemonClient,
               async_opts: [allow_current_runtime_start?: true],
               runtime_opts: [provider: StubProvider]
             )
  end

  test "status attach and cancel fall back to local snapshots when daemon is unavailable", %{
    ws: ws
  } do
    assert {:ok,
            %{
              payload: %{
                "kind" => "delegate_status",
                "daemon_fallback" => %{"reason" => "daemon_unavailable"}
              }
            }} =
             CLIContract.run(["status", "dlg1_fake", "--json"],
               workspace: ws,
               async: FakeAsync,
               daemon_client: UnavailableDaemonClient
             )

    assert {:ok,
            %{
              payload: %{
                "kind" => "delegate_attach",
                "summary" => "attached locally",
                "daemon_fallback" => %{"reason" => "daemon_unavailable"}
              }
            }} =
             CLIContract.run(["attach", "dlg1_fake", "--json"],
               workspace: ws,
               async: FakeAsync,
               daemon_client: UnavailableDaemonClient
             )

    assert {:ok,
            %{
              payload: %{
                "kind" => "delegate_cancel",
                "daemon_fallback" => %{"reason" => "daemon_unavailable"}
              }
            }} =
             CLIContract.run(["cancel", "dlg1_fake", "--json"],
               workspace: ws,
               async: FakeAsync,
               daemon_client: UnavailableDaemonClient
             )
  end

  test "attach routes through daemon when reachable", %{ws: ws} do
    assert {:ok,
            %{
              payload: %{
                "kind" => "delegate_attach",
                "summary" => "attached through daemon",
                "owner" => %{
                  "state" => "live_delegate_owner",
                  "runtime_residency" => %{"model" => "daemon_ipc"}
                },
                "runtime_residency" => %{"model" => "daemon_ipc"}
              },
              exit_code: 0
            }} =
             CLIContract.run(["attach", "dlg1_fake", "--json"],
               workspace: ws,
               async: FakeAsync,
               daemon_client: ReachableDaemonClient
             )
  end

  test "attach progress emits one stderr frame from a live daemon owner", %{ws: ws} do
    stderr =
      capture_io(:stderr, fn ->
        result =
          CLIContract.run(["attach", "dlg1_fake", "--json", "--progress=stderr-jsonl"],
            workspace: ws,
            async: FakeAsync,
            daemon_client: ReachableDaemonClient
          )

        send(self(), {:attach_progress_result, result})
      end)

    assert_received {:attach_progress_result,
                     {:ok,
                      %{
                        payload: %{
                          "kind" => "delegate_attach",
                          "progress" => %{
                            "requested" => true,
                            "mode" => "stderr-jsonl",
                            "frame_count" => 1,
                            "owner_backed" => true,
                            "source" => "live_owner_snapshot"
                          },
                          "attach" => %{
                            "progress" => %{"stdout_contract" => "one_final_json_envelope"}
                          }
                        }
                      }}}

    assert [
             %{
               "type" => "delegate_progress",
               "sequence" => 1,
               "delegate_id" => "dlg1_fake",
               "parent_session_id" => "parent-reachable",
               "status" => "running",
               "owner_backed" => true,
               "source" => "live_owner_snapshot"
             }
           ] =
             stderr
             |> String.split("\n", trim: true)
             |> Enum.map(&Jason.decode!/1)
  end

  test "attach progress can follow a live owner until a bounded horizon observes terminal state",
       %{
         ws: ws
       } do
    Process.delete({SequenceDaemonClient, :attach_calls})
    Process.delete({SequenceDaemonClient, :follow_calls})

    stderr =
      capture_io(:stderr, fn ->
        result =
          CLIContract.run(
            [
              "attach",
              "dlg1_sequence",
              "--json",
              "--progress=stderr-jsonl",
              "--wait-horizon-ms",
              "50"
            ],
            workspace: ws,
            async: FakeAsync,
            daemon_client: SequenceDaemonClient
          )

        send(self(), {:attach_follow_result, result})
      end)

    assert_received {:attach_follow_result,
                     {:ok,
                      %{
                        payload: %{
                          "status" => "completed",
                          "progress" => %{
                            "frame_count" => 2,
                            "followed" => true,
                            "terminal_observed" => true,
                            "owner_backed" => true,
                            "source" => "live_owner_stream",
                            "follow_transport" => "daemon_stream"
                          }
                        }
                      }}}

    assert Process.get({SequenceDaemonClient, :follow_calls}) == 1
    assert Process.get({SequenceDaemonClient, :attach_calls}) == nil

    frames =
      stderr
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert Enum.map(frames, & &1["sequence"]) == [1, 2]
    assert Enum.map(frames, & &1["status"]) == ["running", "completed"]
    assert Enum.all?(frames, &(&1["source"] == "live_owner_stream"))
  end

  test "attach follow falls back to one durable snapshot when daemon follow is unsupported", %{
    ws: ws
  } do
    stderr =
      capture_io(:stderr, fn ->
        result =
          CLIContract.run(
            [
              "attach",
              "dlg1_fake",
              "--json",
              "--progress=stderr-jsonl",
              "--wait-horizon-ms",
              "50"
            ],
            workspace: ws,
            async: FakeAsync,
            daemon_client: ReachableDaemonClient
          )

        send(self(), {:attach_fallback_result, result})
      end)

    assert_received {:attach_fallback_result,
                     {:ok,
                      %{
                        payload: %{
                          "kind" => "delegate_attach",
                          "daemon_fallback" => %{"reason" => "daemon_follow_unsupported"},
                          "progress" => %{
                            "follow_requested" => true,
                            "followed" => false,
                            "follow_transport" => "durable_snapshot_fallback",
                            "source" => "durable_snapshot_after_daemon_fallback",
                            "owner_backed" => false
                          },
                          "attach" => %{
                            "streaming" => false,
                            "progress" => %{"stdout_contract" => "one_final_json_envelope"}
                          }
                        }
                      }}}

    assert [
             %{
               "type" => "delegate_progress",
               "sequence" => 1,
               "delegate_id" => "dlg1_fake",
               "source" => "durable_snapshot_after_daemon_fallback",
               "owner_backed" => false
             }
           ] =
             stderr
             |> String.split("\n", trim: true)
             |> Enum.map(&Jason.decode!/1)
  end

  test "auth failures are returned instead of silently falling back", %{ws: ws} do
    assert {:error,
            %{
              payload: %{
                "kind" => "daemon_auth_failed",
                "details" => %{"fallback_allowed" => false}
              },
              exit_code: 1
            }} =
             CLIContract.run(["status", "dlg1_fake", "--json"],
               workspace: ws,
               async: FakeAsync,
               daemon_client: AuthFailedDaemonClient
             )
  end

  test "daemon foreground returns an after-render blocker", %{ws: ws} do
    assert {:ok,
            %{
              payload: %{"kind" => "delegate_daemon", "status" => "running"},
              after_render: after_render
            }} =
             CLIContract.run(["daemon", "--foreground", "--json"],
               workspace: ws,
               daemon_command: FakeDaemonCommand
             )

    after_render.()
    assert_received :fake_daemon_after_render
  end
end
