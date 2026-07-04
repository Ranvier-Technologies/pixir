defmodule Pixir.ConfigTest do
  use ExUnit.Case, async: false

  alias Pixir.Config

  setup do
    home =
      Path.join(
        System.tmp_dir!(),
        "pixir-config-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}"
      )

    File.mkdir_p!(home)
    config_path = Path.join(home, "config.json")

    previous_home = System.get_env("PIXIR_HOME")
    previous_model_env = System.get_env("PIXIR_MODEL")
    previous_app_model = Application.get_env(:pixir, :model)
    previous_app_retries = Application.get_env(:pixir, :max_retries)
    previous_app_bash_timeout = Application.get_env(:pixir, :bash_timeout_ms)
    previous_app_bash_timeout_max = Application.get_env(:pixir, :bash_timeout_max_ms)
    previous_app_host_commands = Application.get_env(:pixir, :host_commands)

    System.put_env("PIXIR_HOME", home)
    System.delete_env("PIXIR_MODEL")
    Application.delete_env(:pixir, :model)
    Application.delete_env(:pixir, :max_retries)
    Application.delete_env(:pixir, :bash_timeout_ms)
    Application.delete_env(:pixir, :bash_timeout_max_ms)
    Application.delete_env(:pixir, :host_commands)

    on_exit(fn ->
      if previous_home,
        do: System.put_env("PIXIR_HOME", previous_home),
        else: System.delete_env("PIXIR_HOME")

      if previous_model_env,
        do: System.put_env("PIXIR_MODEL", previous_model_env),
        else: System.delete_env("PIXIR_MODEL")

      if previous_app_model,
        do: Application.put_env(:pixir, :model, previous_app_model),
        else: Application.delete_env(:pixir, :model)

      if previous_app_retries,
        do: Application.put_env(:pixir, :max_retries, previous_app_retries),
        else: Application.delete_env(:pixir, :max_retries)

      if previous_app_bash_timeout,
        do: Application.put_env(:pixir, :bash_timeout_ms, previous_app_bash_timeout),
        else: Application.delete_env(:pixir, :bash_timeout_ms)

      if previous_app_bash_timeout_max,
        do: Application.put_env(:pixir, :bash_timeout_max_ms, previous_app_bash_timeout_max),
        else: Application.delete_env(:pixir, :bash_timeout_max_ms)

      if previous_app_host_commands,
        do: Application.put_env(:pixir, :host_commands, previous_app_host_commands),
        else: Application.delete_env(:pixir, :host_commands)

      File.rm_rf!(home)
    end)

    %{home: home, config_path: config_path}
  end

  test "returns built-in defaults when config.json is missing", %{config_path: config_path} do
    result = Config.load(config_path: config_path)

    assert result["present"] == false
    assert result["warnings"] == []

    assert result["effective"] == %{
             "permission_default" => "auto",
             "reasoning" => %{"effort" => nil},
             "text" => %{"verbosity" => nil},
             "bash_timeout_ms" => 120_000,
             "bash_timeout_max_ms" => 600_000,
             "host_commands" => %{
               "max_concurrent" => 4,
               "queue_limit" => 16,
               "queue_timeout_ms" => 5_000
             },
             "max_retries" => 2,
             "stream_idle_timeout_ms" => 180_000,
             "compaction" => %{"tail_events" => 40, "model_assisted" => false},
             "model" => "gpt-5.5",
             "models" => nil,
             "context_windows" => %{}
           }
  end

  test "loads valid expanded config keys", %{config_path: config_path} do
    File.write!(
      config_path,
      Jason.encode!(%{
        "permission_default" => "ask",
        "reasoning" => %{"effort" => "high"},
        "text" => %{"verbosity" => "low"},
        "bash_timeout_ms" => 90_000,
        "bash_timeout_max_ms" => 300_000,
        "host_commands" => %{
          "max_concurrent" => 2,
          "queue_limit" => 3,
          "queue_timeout_ms" => 250
        },
        "max_retries" => 4,
        "stream_idle_timeout_ms" => 60_000,
        "compaction" => %{"tail_events" => 12, "model_assisted" => true},
        "model" => "gpt-5.3-codex",
        "models" => ["gpt-5.3-codex"],
        "context_windows" => %{"gpt-5.3-codex" => 64_000}
      })
    )

    result = Config.load(config_path: config_path)

    assert result["present"] == true
    assert result["warnings"] == []

    assert result["effective"]["permission_default"] == "ask"
    assert result["effective"]["reasoning"]["effort"] == "high"
    assert result["effective"]["text"]["verbosity"] == "low"
    assert result["effective"]["bash_timeout_ms"] == 90_000
    assert result["effective"]["bash_timeout_max_ms"] == 300_000

    assert result["effective"]["host_commands"] == %{
             "max_concurrent" => 2,
             "queue_limit" => 3,
             "queue_timeout_ms" => 250
           }

    assert result["effective"]["max_retries"] == 4
    assert result["effective"]["stream_idle_timeout_ms"] == 60_000
    assert result["effective"]["compaction"]["tail_events"] == 12
    assert result["effective"]["compaction"]["model_assisted"] == true
    assert result["effective"]["model"] == "gpt-5.3-codex"
    assert result["effective"]["models"] == ["gpt-5.3-codex"]
    assert result["effective"]["context_windows"] == %{"gpt-5.3-codex" => 64_000}
  end

  test "keeps bash timeout max at least as large as an explicit timeout and warns", %{
    config_path: config_path
  } do
    File.write!(
      config_path,
      Jason.encode!(%{
        "bash_timeout_ms" => 300_000,
        "bash_timeout_max_ms" => 120_000
      })
    )

    result = Config.load(config_path: config_path)

    assert Enum.any?(result["warnings"], fn warning ->
             warning["field"] == "bash_timeout_max_ms.min"
           end)

    assert result["effective"]["bash_timeout_ms"] == 300_000
    assert result["effective"]["bash_timeout_max_ms"] == 300_000
  end

  test "warns and ignores invalid fields", %{config_path: config_path} do
    File.write!(
      config_path,
      Jason.encode!(%{
        "permission_default" => "yolo",
        "reasoning" => %{"effort" => "turbo"},
        "text" => %{"verbosity" => "chatty"},
        "bash_timeout_ms" => "slow",
        "bash_timeout_max_ms" => 0,
        "host_commands" => %{
          "max_concurrent" => 0,
          "queue_limit" => "many",
          "queue_timeout_ms" => -1
        },
        "max_retries" => -1,
        "stream_idle_timeout_ms" => "forever",
        "compaction" => %{"tail_events" => 0, "model_assisted" => "yes"},
        "model" => 42,
        "models" => ["ok", 7],
        "context_windows" => %{"bad" => "nope"}
      })
    )

    result = Config.load(config_path: config_path)
    fields = MapSet.new(result["warnings"], & &1["field"])

    assert MapSet.member?(fields, "permission_default")
    assert MapSet.member?(fields, "reasoning.effort")
    assert MapSet.member?(fields, "text.verbosity")
    assert MapSet.member?(fields, "bash_timeout_ms")
    assert MapSet.member?(fields, "bash_timeout_max_ms")
    assert MapSet.member?(fields, "host_commands.max_concurrent")
    assert MapSet.member?(fields, "host_commands.queue_limit")
    assert MapSet.member?(fields, "host_commands.queue_timeout_ms")
    assert MapSet.member?(fields, "max_retries")
    assert MapSet.member?(fields, "stream_idle_timeout_ms")
    assert MapSet.member?(fields, "compaction.tail_events")
    assert MapSet.member?(fields, "compaction.model_assisted")
    assert MapSet.member?(fields, "model")
    assert MapSet.member?(fields, "models")
    assert MapSet.member?(fields, "context_windows")

    assert result["effective"]["permission_default"] == "auto"
    assert result["effective"]["reasoning"]["effort"] == nil
    assert result["effective"]["text"]["verbosity"] == nil
    assert result["effective"]["bash_timeout_ms"] == 120_000
    assert result["effective"]["bash_timeout_max_ms"] == 600_000

    assert result["effective"]["host_commands"] == %{
             "max_concurrent" => 4,
             "queue_limit" => 16,
             "queue_timeout_ms" => 5_000
           }

    assert result["effective"]["max_retries"] == 2
    assert result["effective"]["stream_idle_timeout_ms"] == 180_000
    assert result["effective"]["compaction"]["tail_events"] == 40
    assert result["effective"]["compaction"]["model_assisted"] == false
    assert result["effective"]["model"] == "gpt-5.5"
    assert result["effective"]["models"] == nil
    assert result["effective"]["context_windows"] == %{}
  end

  test "application config overrides file values", %{config_path: config_path} do
    File.write!(
      config_path,
      Jason.encode!(%{
        "max_retries" => 9,
        "bash_timeout_ms" => 1,
        "bash_timeout_max_ms" => 2,
        "host_commands" => %{
          "max_concurrent" => 9,
          "queue_limit" => 9,
          "queue_timeout_ms" => 9
        }
      })
    )

    Application.put_env(:pixir, :max_retries, 1)
    Application.put_env(:pixir, :bash_timeout_ms, 5_000)
    Application.put_env(:pixir, :bash_timeout_max_ms, 10_000)

    Application.put_env(:pixir, :host_commands,
      max_concurrent: 2,
      queue_limit: 0,
      queue_timeout_ms: 10
    )

    assert Config.max_retries(config_path: config_path) == 1
    assert Config.bash_timeout_ms(config_path: config_path) == 5_000
    assert Config.bash_timeout_max_ms(config_path: config_path) == 10_000

    assert {:ok,
            %{
              "max_concurrent" => 2,
              "queue_limit" => 0,
              "queue_timeout_ms" => 10
            }} = Config.host_commands(config_path: config_path)
  end

  test "PIXIR_MODEL overrides config model", %{config_path: config_path} do
    File.write!(config_path, Jason.encode!(%{"model" => "from-config"}))
    System.put_env("PIXIR_MODEL", "from-env")

    assert get_in(Config.load(config_path: config_path), ["effective", "model"]) == "from-env"
  end

  test "merge_provider_opts preserves explicit provider opts", %{config_path: config_path} do
    File.write!(
      config_path,
      Jason.encode!(%{
        "max_retries" => 9,
        "stream_idle_timeout_ms" => 77,
        "reasoning" => %{"effort" => "low"},
        "text" => %{"verbosity" => "high"}
      })
    )

    merged =
      Config.merge_provider_opts(
        [max_retries: 1, reasoning_effort: "high", text_verbosity: "medium"],
        config_path: config_path
      )

    assert merged[:max_retries] == 1
    assert merged[:reasoning_effort] == "high"
    assert merged[:text_verbosity] == "medium"
    assert merged[:stream_idle_timeout_ms] == 77
  end

  test "permission_default resolves to atoms", %{config_path: config_path} do
    File.write!(config_path, Jason.encode!(%{"permission_default" => "read_only"}))
    assert Config.permission_default(config_path: config_path) == :read_only
  end
end
