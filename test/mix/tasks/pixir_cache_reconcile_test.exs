defmodule Mix.Tasks.Pixir.Cache.ReconcileTest do
  use ExUnit.Case, async: false

  test "folds provider_usage cache evidence and classifies pa1 zero-cache calls as below minimum" do
    sessions_dir =
      Path.join(System.tmp_dir!(), "pixir-cache-reconcile-#{System.unique_integer([:positive])}")

    File.mkdir_p!(sessions_dir)

    events = [
      provider_usage(
        %{
          "prompt_contract_version" => "px3",
          "toolset_hash" => "legacy",
          "skill_index_hash" => "legacy",
          "session_family_hash" => "legacy"
        },
        %{"input_tokens" => 80, "cached_tokens" => 64}
      ),
      provider_usage(
        %{
          "prompt_contract_version" => "pa1",
          "toolset_hash" => "tools",
          "skill_index_hash" => "skills",
          "session_family_hash" => "family"
        },
        %{
          "input_tokens" => 100,
          "cache" => %{"creation_tokens" => 30, "read_tokens" => 20}
        }
      ),
      provider_usage(
        %{
          "prompt_contract_version" => "pa1",
          "toolset_hash" => "tools",
          "skill_index_hash" => "skills",
          "session_family_hash" => "family"
        },
        %{
          "input_tokens" => 50,
          "cache" => %{"creation_tokens" => 0, "read_tokens" => 0}
        }
      )
    ]

    File.write!(
      Path.join(sessions_dir, "one.ndjson"),
      Enum.map_join(events, "\n", &Jason.encode!/1)
    )

    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    try do
      Mix.Tasks.Pixir.Cache.Reconcile.run(["--sessions-dir", sessions_dir])
      assert_receive {:mix_shell, :info, [json]}
      payload = Jason.decode!(json)
      [pa1, legacy] = payload["families"]

      assert pa1["prompt_contract_version"] == "pa1"
      assert pa1["calls"] == 2
      assert pa1["input_tokens"] == 150
      assert pa1["creation_tokens"] == 30
      assert pa1["read_tokens"] == 20
      assert pa1["hit_rate"] == 20 / 200
      assert pa1["below_minimum_count"] == 1

      # Pre-cache-map events fold their OpenAI cached_tokens as reads.
      assert legacy["prompt_contract_version"] == "px3"
      assert legacy["read_tokens"] == 64
      assert legacy["hit_rate"] == 64 / 144
      assert legacy["below_minimum_count"] == 0
    after
      Mix.shell(previous_shell)
      File.rm_rf!(sessions_dir)
    end
  end

  # Mirrors the real event shape: Turn merges the cache metadata FLAT into the
  # event data (record_provider_usage/6), never under a nested key.
  defp provider_usage(metadata, summary) do
    %{
      "type" => "provider_usage",
      "data" => Map.merge(metadata, %{"usage_summary" => summary})
    }
  end
end
