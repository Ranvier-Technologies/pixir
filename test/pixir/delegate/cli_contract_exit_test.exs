defmodule Pixir.Delegate.CLIContractExitTest do
  use ExUnit.Case, async: true

  alias Pixir.Delegate.CLIContract

  defmodule StatusRunner do
    def run(_request, _spec, _spec_meta, _runtime_opts) do
      status = Process.get({__MODULE__, :status})
      classification = Process.get({__MODULE__, :classification})

      payload = %{
        "ok" => status == "completed",
        "status" => status,
        "kind" => "delegate_result",
        "summary" => "fake delegate #{status}"
      }

      payload =
        if classification do
          Map.put(payload, "timeout_diagnostics", %{"classification" => classification})
        else
          payload
        end

      {:ok, payload}
    end
  end

  test "attached delegate timeout diagnostics preserve public reason-code vocabulary" do
    spec = Jason.encode!(%{"contract_version" => 1, "strategy" => "subagents", "task" => "x"})

    cases = [
      {"partial", "spawn_failure", "spawn_failed"},
      {"timed_out", "child_timeout", "child_timed_out"},
      {"partial", "child_failure", "child_failed"},
      {"partial", "child_cancelled", "cancelled"},
      {"partial", "partial_terminal_mix", "partial"},
      {"timed_out", "wait_horizon_exhausted_with_queued_work",
       "wait_horizon_exhausted_with_queued_work"},
      {"timed_out", "wait_horizon_exhausted_with_running_work",
       "wait_horizon_exhausted_with_running_work"},
      {"partial", "wait_horizon_exhausted_with_queued_work",
       "wait_horizon_exhausted_with_queued_work"},
      {"partial", "wait_horizon_exhausted_with_running_work",
       "wait_horizon_exhausted_with_running_work"}
    ]

    try do
      for {status, classification, expected_reason_code} <- cases do
        Process.put({StatusRunner, :status}, status)
        Process.put({StatusRunner, :classification}, classification)

        assert {:ok,
                %{
                  exit_code: 6,
                  payload: %{
                    "status" => ^status,
                    "timeout_diagnostics" => %{"classification" => ^classification},
                    "reason_code" => reason_code
                  }
                }} =
                 CLIContract.run(["--spec", "-", "--json"],
                   read_stdin: fn -> spec end,
                   runner: StatusRunner
                 )

        assert reason_code == expected_reason_code
      end
    after
      Process.delete({StatusRunner, :classification})
    end
  end

  test "attached delegate terminal incomplete statuses exit 6 by default" do
    spec = Jason.encode!(%{"contract_version" => 1, "strategy" => "subagents", "task" => "x"})

    expected_reason_codes = %{
      "partial" => "partial",
      "timed_out" => "child_timed_out",
      "failed" => "failed",
      "cancelled" => "cancelled"
    }

    for status <- ~w(partial timed_out failed cancelled) do
      Process.delete({StatusRunner, :classification})
      Process.put({StatusRunner, :status}, status)

      assert {:ok,
              %{
                exit_code: 6,
                payload: %{
                  "status" => ^status,
                  "ok" => false,
                  "schema_version" => 4,
                  "command_ok" => true,
                  "work_complete" => false,
                  "outcome" => ^status,
                  "reason_code" => reason_code
                }
              }} =
               CLIContract.run(["--spec", "-", "--json"],
                 read_stdin: fn -> spec end,
                 runner: StatusRunner
               )

      assert reason_code == expected_reason_codes[status]
    end
  end

  test "attached delegate completed status exits 0" do
    spec = Jason.encode!(%{"contract_version" => 1, "strategy" => "subagents", "task" => "x"})
    Process.delete({StatusRunner, :classification})
    Process.put({StatusRunner, :status}, "completed")

    assert {:ok,
            %{
              exit_code: 0,
              payload: %{
                "status" => "completed",
                "ok" => true,
                "schema_version" => 4,
                "command_ok" => true,
                "work_complete" => true,
                "outcome" => "completed",
                "reason_code" => "completed"
              }
            }} =
             CLIContract.run(["--spec", "-", "--json"],
               read_stdin: fn -> spec end,
               runner: StatusRunner
             )
  end
end
