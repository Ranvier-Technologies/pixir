defmodule Pixir.ConfigTest do
  use ExUnit.Case, async: false

  alias Pixir.Config

  defmodule HostileWebSearchValue do
    defstruct [:secret]
  end

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
    previous_app_web_search = Application.get_env(:pixir, :web_search)

    System.put_env("PIXIR_HOME", home)
    System.delete_env("PIXIR_MODEL")
    Application.delete_env(:pixir, :model)
    Application.delete_env(:pixir, :max_retries)
    Application.delete_env(:pixir, :bash_timeout_ms)
    Application.delete_env(:pixir, :bash_timeout_max_ms)
    Application.delete_env(:pixir, :host_commands)
    Application.delete_env(:pixir, :web_search)

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

      if previous_app_web_search,
        do: Application.put_env(:pixir, :web_search, previous_app_web_search),
        else: Application.delete_env(:pixir, :web_search)

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
             "web_search" => nil,
             "compaction" => %{"tail_events" => 40, "model_assisted" => false},
             "model" => "gpt-5.5",
             "models" => nil,
             "anthropic_models" => nil,
             "models_refreshed_at" => nil,
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
        "web_search" => %{
          "enabled" => true,
          "search_context_size" => "medium",
          "include_sources" => false
        },
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

    assert result["effective"]["web_search"] == %{
             "enabled" => true,
             "search_context_size" => "medium",
             "include_sources" => false
           }

    assert result["effective"]["compaction"]["tail_events"] == 12
    assert result["effective"]["compaction"]["model_assisted"] == true
    assert result["effective"]["model"] == "gpt-5.3-codex"
    assert result["effective"]["models"] == ["gpt-5.3-codex"]
    assert result["effective"]["context_windows"] == %{"gpt-5.3-codex" => 64_000}
  end

  test "web_search explicit disable stays unwarned and malformed lists warn without crashing",
       %{config_path: config_path} do
    File.write!(config_path, Jason.encode!(%{"web_search" => %{"enabled" => false}}))

    result = Config.load(config_path: config_path)
    assert result["warnings"] == []
    assert result["effective"]["web_search"] == nil

    File.write!(config_path, Jason.encode!(%{"web_search" => [1, 2, 3]}))

    result = Config.load(config_path: config_path)
    assert Enum.any?(result["warnings"], &(&1["field"] == "web_search"))
    assert result["effective"]["web_search"] == nil
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
        "web_search" => %{"enabled" => true, "unknown" => true},
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
    assert MapSet.member?(fields, "web_search")
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
    assert result["effective"]["web_search"] == nil
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

  test "blank models are ignored consistently across load, snapshot, and file_model", %{
    config_path: config_path
  } do
    for blank <- ["", "   "] do
      File.write!(config_path, Jason.encode!(%{"model" => blank}))

      loaded = Config.load(config_path: config_path)
      assert loaded["effective"]["model"] == "gpt-5.5"
      assert Enum.any?(loaded["warnings"], &(&1["field"] == "model"))

      assert {:ok, snapshot} = Config.request_snapshot(config_path: config_path)
      assert snapshot.model == "gpt-5.5"
      assert snapshot.model_source == :default
      assert Config.file_model(config_path: config_path) == "gpt-5.5"
    end
  end

  test "invalid UTF-8 models warn and fall back consistently" do
    invalid = <<255>>
    raw = %{"model" => invalid}

    loaded = Config.load(raw_config: raw)
    assert loaded["effective"]["model"] == "gpt-5.5"
    assert Enum.any?(loaded["warnings"], &(&1["field"] == "model"))

    assert {:ok, snapshot} = Config.request_snapshot(raw_config: raw)
    assert snapshot.model == "gpt-5.5"
    assert snapshot.model_source == :default
    assert Config.file_model(raw_config: raw) == "gpt-5.5"
    refute inspect(loaded) =~ inspect(invalid)
  end

  test "model catalogs and refresh stamps keep Config.load JSON-serializable" do
    invalid = <<255, 254>>

    loaded =
      Config.load(
        raw_config: %{
          "models" => ["gpt-5.5", invalid],
          "anthropic_models" => [invalid],
          "models_refreshed_at" => invalid
        }
      )

    assert loaded["effective"]["models"] == nil
    assert loaded["effective"]["anthropic_models"] == nil
    assert loaded["effective"]["models_refreshed_at"] == nil

    for field <- ["models", "anthropic_models", "models_refreshed_at"] do
      assert Enum.any?(loaded["warnings"], &(&1["field"] == field))
    end

    assert {:ok, _json} = Jason.encode(loaded)
    refute inspect(loaded) =~ inspect(invalid)
  end

  test "trimmed app and env model precedence stays identical in snapshots and projections" do
    loader = fn _opts ->
      {:ok,
       %{
         present?: true,
         origin: :programmatic,
         document: %{"model" => " file-model "}
       }}
    end

    System.put_env("PIXIR_MODEL", " env-model ")
    Application.put_env(:pixir, :model, "   ")

    loaded = Config.load(raw_config: %{"model" => " file-model "})
    assert loaded["effective"]["model"] == "env-model"
    assert Config.file_model(raw_config: %{"model" => " file-model "}) == "env-model"

    assert {:ok, env_snapshot} =
             Config.request_snapshot(request_snapshot_loader: loader)

    assert env_snapshot.model == "env-model"
    assert env_snapshot.model_source == :env

    Application.put_env(:pixir, :model, " app-model ")

    assert Config.load(raw_config: %{"model" => " file-model "})["effective"]["model"] ==
             "app-model"

    assert {:ok, app_snapshot} =
             Config.request_snapshot(request_snapshot_loader: loader)

    assert app_snapshot.model == "app-model"
    assert app_snapshot.model_source == :application
  end

  test "merge_provider_opts preserves explicit provider opts", %{config_path: config_path} do
    File.write!(
      config_path,
      Jason.encode!(%{
        "max_retries" => 9,
        "stream_idle_timeout_ms" => 77,
        "web_search" => %{"enabled" => true},
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
    assert merged[:web_search] == %{"enabled" => true}
    assert merged[:stream_idle_timeout_ms] == 77
  end

  test "permission_default resolves to atoms", %{config_path: config_path} do
    File.write!(config_path, Jason.encode!(%{"permission_default" => "read_only"}))
    assert Config.permission_default(config_path: config_path) == :read_only
  end

  test "request_snapshot resolves model and open backend from one loader invocation" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    loader = fn opts ->
      refute Keyword.has_key?(opts, :request_snapshot_loader)
      assert Agent.get_and_update(calls, &{&1, &1 + 1}) == 0

      {:ok,
       %{
         present?: true,
         origin: :file,
         document:
           Jason.encode!(%{
             "model" => "gpt-first",
             "max_retries" => 7,
             "stream_idle_timeout_ms" => 12_345,
             "reasoning" => %{"effort" => "high"},
             "text" => %{"verbosity" => "low"},
             "web_search" => %{"enabled" => true, "search_context_size" => "medium"},
             "responses_backend" => %{
               "mode" => "open_responses",
               "responses_url" => "https://first.example/v1/responses",
               "auth" => %{"policy" => "none"}
             }
           })
       }}
    end

    assert {:ok, snapshot} = Config.request_snapshot(request_snapshot_loader: loader)
    assert Agent.get(calls, & &1) == 1
    assert snapshot.model == "gpt-first"
    assert snapshot.model_source == :file
    assert snapshot.config_present?
    assert snapshot.provider_defaults.max_retries == 7
    assert snapshot.provider_defaults.stream_idle_timeout_ms == 12_345
    assert snapshot.provider_defaults.reasoning_effort == "high"
    assert snapshot.provider_defaults.text_verbosity == "low"

    assert snapshot.provider_defaults.web_search == %{
             "enabled" => true,
             "search_context_size" => "medium"
           }

    assert Pixir.Providers.ResponsesBackend.endpoint(snapshot.responses_backend) ==
             {:responses_url, "https://first.example/v1/responses"}
  end

  test "responses_backend keeps successful absent and explicit values inside ok tuples" do
    assert {:ok, :absent} = Config.responses_backend(raw_config: %{})

    assert {:ok, backend} =
             Config.responses_backend(
               raw_config: %{"responses_backend" => %{"mode" => "chatgpt_codex"}}
             )

    assert Pixir.Providers.ResponsesBackend.mode(backend) == :chatgpt_codex

    assert {:error, %{error: %{kind: :invalid_config}}} =
             Config.responses_backend(raw_config: %{"responses_backend" => %{"mode" => "future"}})
  end

  test "invalid reasoning and text warnings never echo configured values" do
    sentinel = "SECRET_INVALID_ENUM_VALUE"

    result =
      Config.load(
        raw_config: %{
          "reasoning" => %{"effort" => sentinel},
          "text" => %{"verbosity" => sentinel}
        }
      )

    assert Enum.any?(result["warnings"], &(&1["field"] == "reasoning.effort"))
    assert Enum.any?(result["warnings"], &(&1["field"] == "text.verbosity"))
    refute inspect(result) =~ sentinel
    assert {:ok, _json} = Jason.encode(result)
  end

  test "whole-document structs fail closed without raising or leaking" do
    sentinel = "https://SECRET.example/v1/responses"
    struct = URI.parse(sentinel)

    loaded = Config.load(raw_config: struct)
    assert loaded["error"] == %{kind: :invalid_json, position: 0}
    refute inspect(loaded) =~ sentinel
    assert {:ok, _json} = Jason.encode(loaded)

    assert {:error,
            %{
              error: %{
                kind: :invalid_config,
                details: %{field: :config, reason: :invalid_json}
              }
            } = payload} = Config.request_snapshot(raw_config: struct)

    refute inspect(payload) =~ sentinel

    assert {:error,
            %{error: %{kind: :invalid_config, details: %{reason: :invalid_loader_result}}}} =
             Config.request_snapshot(
               request_snapshot_loader: fn _opts ->
                 {:ok, %{present?: true, origin: :programmatic, document: struct}}
               end
             )
  end

  test "whole-value web search and context-window structs stay total and redacted" do
    sentinel = "https://SECRET.example/v1/responses"
    uri = URI.parse(sentinel)

    for value <- [uri, DateTime.utc_now(), MapSet.new([:enabled])] do
      loaded = Config.load(raw_config: %{"web_search" => value})
      assert Enum.any?(loaded["warnings"], &(&1["field"] == "web_search"))
      assert loaded["effective"]["web_search"] == nil
      refute inspect(loaded) =~ sentinel
      assert {:ok, snapshot} = Config.request_snapshot(raw_config: %{"web_search" => value})
      assert snapshot.provider_defaults.web_search == nil
    end

    loaded = Config.load(raw_config: %{"context_windows" => uri})
    assert Enum.any?(loaded["warnings"], &(&1["field"] == "context_windows"))
    assert loaded["effective"]["context_windows"] == %{}
    refute inspect(loaded) =~ sentinel

    loaded = Config.load(raw_config: %{"context_windows" => %{uri => 128_000}})
    assert Enum.any?(loaded["warnings"], &(&1["field"] == "context_windows"))
    assert loaded["effective"]["context_windows"] == %{}
    refute inspect(loaded) =~ sentinel
    assert {:ok, _json} = Jason.encode(loaded)
  end

  test "struct-shaped nested config parents cannot smuggle validated defaults" do
    sentinel = "https://NESTED_CONFIG_SECRET.example/token"

    raw = %{
      "reasoning" => Map.put(URI.parse(sentinel), "effort", "high"),
      "text" => Map.put(DateTime.utc_now(), "verbosity", "low"),
      "compaction" =>
        DateTime.utc_now()
        |> Map.put("tail_events", 7)
        |> Map.put("model_assisted", true),
      "host_commands" => Map.put(URI.parse(sentinel), "max_concurrent", 9)
    }

    loaded = Config.load(raw_config: raw)
    warnings = MapSet.new(loaded["warnings"], & &1["field"])

    assert MapSet.member?(warnings, "reasoning.effort")
    assert MapSet.member?(warnings, "text.verbosity")
    assert MapSet.member?(warnings, "compaction")
    assert MapSet.member?(warnings, "host_commands")
    assert loaded["effective"]["reasoning"]["effort"] == nil
    assert loaded["effective"]["text"]["verbosity"] == nil
    assert loaded["effective"]["compaction"] == %{"tail_events" => 40, "model_assisted" => false}

    assert loaded["effective"]["host_commands"] == %{
             "max_concurrent" => 4,
             "queue_limit" => 16,
             "queue_timeout_ms" => 5_000
           }

    refute inspect(loaded) =~ sentinel

    assert {:ok, snapshot} = Config.request_snapshot(raw_config: raw)
    assert snapshot.provider_defaults.reasoning_effort == nil
    assert snapshot.provider_defaults.text_verbosity == nil
    refute inspect(snapshot) =~ sentinel
  end

  test "programmatic nested config keys normalize atom forms and reject collisions" do
    assert {:ok, atom_snapshot} =
             Config.request_snapshot(
               raw_config: %{
                 "reasoning" => %{effort: "high"},
                 "text" => %{verbosity: "low"}
               }
             )

    assert atom_snapshot.provider_defaults.reasoning_effort == "high"
    assert atom_snapshot.provider_defaults.text_verbosity == "low"

    collision = %{
      "reasoning" => %{"effort" => "low", effort: "high"},
      "text" => %{"verbosity" => "high", verbosity: "low"}
    }

    loaded = Config.load(raw_config: collision)
    assert loaded["effective"]["reasoning"]["effort"] == nil
    assert loaded["effective"]["text"]["verbosity"] == nil
    assert Enum.any?(loaded["warnings"], &(&1["field"] == "reasoning.effort"))
    assert Enum.any?(loaded["warnings"], &(&1["field"] == "text.verbosity"))

    assert {:ok, collision_snapshot} = Config.request_snapshot(raw_config: collision)
    assert collision_snapshot.provider_defaults.reasoning_effort == nil
    assert collision_snapshot.provider_defaults.text_verbosity == nil
  end

  test "file snapshots reject duplicate non-profile keys at any nested depth", %{
    config_path: config_path
  } do
    File.write!(
      config_path,
      ~s({"reasoning":{"effort":"high","effort":"low"},"model":"gpt-5.5"})
    )

    loaded = Config.load(config_path: config_path)
    assert loaded["error"] == %{kind: :invalid_config}

    assert {:error,
            %{
              error: %{
                kind: :invalid_config,
                details: %{field: :config, reason: :unknown_field}
              }
            }} = Config.request_snapshot(config_path: config_path)
  end

  test "improper config lists stay total across application and raw snapshots" do
    improper_web_search = [{:enabled, true} | :secret_tail]
    improper_models = ["gpt-5.5" | :secret_tail]

    Application.put_env(:pixir, :web_search, improper_web_search)

    assert {:ok, app_snapshot} = Config.request_snapshot(raw_config: %{})
    assert app_snapshot.provider_defaults.web_search == nil

    Application.delete_env(:pixir, :web_search)

    assert {:ok, raw_snapshot} =
             Config.request_snapshot(
               raw_config: %{
                 "web_search" => improper_web_search,
                 "models" => improper_models
               }
             )

    assert raw_snapshot.provider_defaults.web_search == nil
    assert raw_snapshot.model == "gpt-5.5"

    loaded = Config.load(raw_config: %{"models" => improper_models})
    assert loaded["effective"]["models"] == nil
    assert Enum.any?(loaded["warnings"], &(&1["field"] == "models"))
  end

  test "request_snapshot loader failures stay bounded, structured, JSON-safe, and redacted" do
    sentinel = "LOADER_SECRET_SENTINEL"

    cases = [
      {{:not_a_loader, sentinel}, :invalid_loader_type},
      {fn -> :bad_arity end, :invalid_loader_arity},
      {fn _opts -> {:ok, :invalid_document} end, :invalid_loader_result},
      {fn _opts -> {:error, {:secret, sentinel}} end, :invalid_loader_result},
      {fn _opts -> raise sentinel end, :loader_execution_failed},
      {fn _opts -> throw(sentinel) end, :loader_execution_failed},
      {fn _opts -> exit(sentinel) end, :loader_execution_failed}
    ]

    for {loader, reason} <- cases do
      assert {:error,
              %{
                ok: false,
                error: %{
                  kind: :invalid_config,
                  message: message,
                  details: %{field: :request_snapshot_loader, reason: ^reason} = details
                }
              } = payload} = Config.request_snapshot(request_snapshot_loader: loader)

      assert is_binary(message) and byte_size(message) in 1..240
      assert map_size(details) == 2
      assert match?({:ok, _}, Jason.encode(payload))
      refute inspect(payload) =~ sentinel
      refute inspect(payload) =~ "#Function"
    end
  end

  test "request_snapshot loader accepts only closed sanitized source errors" do
    for {source_error, reason} <- [
          {%{kind: :read_failed}, :read_failed},
          {%{kind: :invalid_json, position: 17}, :invalid_json}
        ] do
      assert {:error,
              %{
                error: %{
                  kind: :invalid_config,
                  details: %{field: :config, reason: ^reason}
                }
              }} =
               Config.request_snapshot(
                 request_snapshot_loader: fn _opts -> {:error, source_error} end
               )
    end

    sentinel = "LOADER_SOURCE_ERROR_SECRET"

    rejected = [
      %{kind: :read_failed, detail: sentinel},
      %{kind: :invalid_json, position: -1},
      %{kind: :invalid_json, position: 2, source: sentinel},
      %{kind: :unknown, value: sentinel}
    ]

    for source_error <- rejected do
      assert {:error,
              %{
                error: %{
                  kind: :invalid_config,
                  details: %{
                    field: :request_snapshot_loader,
                    reason: :invalid_loader_result
                  }
                }
              } = error} =
               Config.request_snapshot(
                 request_snapshot_loader: fn _opts -> {:error, source_error} end
               )

      refute inspect(error) =~ sentinel
    end
  end

  test "nested structs in raw or application web_search config are ignored safely" do
    unsafe = %{"filters" => Date.utc_today()}

    loaded = Config.load(raw_config: %{"web_search" => unsafe})
    assert loaded["effective"]["web_search"] == nil
    assert Enum.any?(loaded["warnings"], &(&1["field"] == "web_search"))

    assert {:ok, raw_snapshot} =
             Config.request_snapshot(raw_config: %{"web_search" => unsafe})

    assert raw_snapshot.provider_defaults.web_search == nil

    Application.put_env(:pixir, :web_search, unsafe)
    assert Config.load(raw_config: %{})["effective"]["web_search"] == nil
    assert {:ok, app_snapshot} = Config.request_snapshot(raw_config: %{})
    assert app_snapshot.provider_defaults.web_search == nil
  end

  test "rejected web_search warnings never inspect or echo hostile values" do
    sentinel = "HOSTILE_WEB_SEARCH_SENTINEL"
    hostile = %{"filters" => %HostileWebSearchValue{secret: sentinel}}

    loaded = Config.load(raw_config: %{"web_search" => hostile})
    assert loaded["effective"]["web_search"] == nil

    assert [%{"field" => "web_search", "message" => "invalid value; ignoring"}] =
             loaded["warnings"]

    refute inspect(loaded) =~ sentinel

    Application.put_env(:pixir, :web_search, hostile)
    assert Config.load(raw_config: %{})["effective"]["web_search"] == nil
  end

  test "invalid web_search map keys never enter errors or warnings" do
    sentinel = "HOSTILE_WEB_SEARCH_KEY_SENTINEL"
    hostile_key = %HostileWebSearchValue{secret: sentinel}
    unsafe = %{hostile_key => "value"}

    loaded = Config.load(raw_config: %{"web_search" => unsafe})
    assert loaded["effective"]["web_search"] == nil

    assert [%{"field" => "web_search", "message" => "invalid value; ignoring"}] =
             loaded["warnings"]

    refute inspect(loaded) =~ sentinel

    assert {:ok, snapshot} =
             Config.request_snapshot(raw_config: %{"web_search" => unsafe})

    assert snapshot.provider_defaults.web_search == nil
  end

  test "web_search normalized key collisions fail closed instead of last-write-win" do
    for web_search <- [
          %{:enabled => false, "enabled" => true},
          %{:filters => %{"first" => true}, "filters" => %{"second" => true}}
        ] do
      loaded = Config.load(raw_config: %{"web_search" => web_search})
      assert loaded["effective"]["web_search"] == nil
      assert Enum.any?(loaded["warnings"], &(&1["field"] == "web_search"))

      assert {:ok, snapshot} =
               Config.request_snapshot(raw_config: %{"web_search" => web_search})

      assert snapshot.provider_defaults.web_search == nil
    end
  end

  test "invalid permission defaults never enter warnings or request snapshots" do
    sentinel = "HOSTILE_PERMISSION_DEFAULT_SENTINEL"
    hostile = %HostileWebSearchValue{secret: sentinel}
    raw = %{"permission_default" => hostile}

    loaded = Config.load(raw_config: raw)
    assert loaded["effective"]["permission_default"] == "auto"

    assert [
             %{
               "field" => "permission_default",
               "message" => "invalid value; expected auto, ask, or read_only"
             }
           ] = loaded["warnings"]

    refute inspect(loaded) =~ sentinel

    assert {:ok, snapshot} = Config.request_snapshot(raw_config: raw)
    assert snapshot.model == "gpt-5.5"
    refute inspect(snapshot) =~ sentinel
  end

  test "load warns and omits duplicate literal profile keys while snapshot fails closed", %{
    config_path: config_path
  } do
    File.write!(
      config_path,
      ~s({"model":"gpt-5.4-mini","responses_backend":{"mode":"open_responses","responses_url":"https://first.example/v1/responses","responses_url":"https://secret.example/v1/responses","auth":{"policy":"none"}}})
    )

    loaded = Config.load(config_path: config_path)
    assert loaded["present"]
    refute Map.has_key?(loaded["effective"], "responses_backend")

    assert Enum.any?(loaded["warnings"], fn warning ->
             warning["field"] == "responses_backend" and warning["reason"] == "unknown_field"
           end)

    refute inspect(loaded) =~ "secret.example"

    assert {:error, %{error: %{kind: :invalid_config, details: %{reason: :unknown_field}}}} =
             Config.request_snapshot(config_path: config_path)
  end

  test "programmatic normalized profile-key collisions warn in load and fail in snapshots" do
    raw = %{
      :responses_backend => %{"mode" => "chatgpt_codex"},
      "responses_backend" => %{"mode" => "future"}
    }

    loaded = Config.load(raw_config: raw)
    refute Map.has_key?(loaded["effective"], "responses_backend")

    assert [%{"field" => "responses_backend", "reason" => "unknown_field"}] =
             loaded["warnings"]

    assert {:error,
            %{
              error: %{
                kind: :invalid_config,
                details: %{field: :config, reason: :unknown_field}
              }
            }} = Config.request_snapshot(raw_config: raw)
  end

  test "malformed whole-file JSON never projects source bytes", %{config_path: config_path} do
    sentinel = "https://SECRET.example/v1/responses"
    bytes = ~s({"responses_backend":{"responses_url":"#{sentinel}"})
    File.write!(config_path, bytes)

    loaded = Config.load(config_path: config_path)
    assert %{kind: :invalid_json, position: position} = loaded["error"]
    assert position in 0..byte_size(bytes)
    assert Map.keys(loaded["error"]) |> Enum.sort() == [:kind, :position]
    refute inspect(loaded) =~ sentinel
    assert match?({:ok, _}, Jason.encode(loaded))

    assert {:error,
            %{error: %{kind: :invalid_config, details: %{field: :config, reason: :invalid_json}}}} =
             Config.request_snapshot(config_path: config_path)
  end

  test "valid and malformed profile load projections never expose endpoint values" do
    open = %{
      "mode" => "open_responses",
      "responses_url" => "https://private.example/v1/responses",
      "auth" => %{"policy" => "none"}
    }

    valid = Config.load(raw_config: %{"responses_backend" => open})
    assert valid["effective"]["responses_backend"]["mode"] == "open_responses"
    assert valid["effective"]["responses_backend"]["endpoint_kind"] == "responses_url"
    refute inspect(valid) =~ "private.example"

    malformed = Config.load(raw_config: %{"responses_backend" => Map.put(open, "mode", "future")})
    refute Map.has_key?(malformed["effective"], "responses_backend")
    assert hd(malformed["warnings"])["reason"] == "unknown_mode"
    refute inspect(malformed) =~ "private.example"
  end
end
