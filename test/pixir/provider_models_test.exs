defmodule Pixir.ProviderModelsTest do
  # async: false — these drive `PIXIR_HOME` (a process-global env var) to isolate
  # `~/.pixir/config.json`, so they must not run concurrently with anything else
  # that reads the global root.
  use ExUnit.Case, async: false

  alias Pixir.Provider

  setup do
    home =
      Path.join(
        System.tmp_dir!(),
        "pixir-models-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(home)
    prev_home = System.get_env("PIXIR_HOME")
    prev_model = System.get_env("PIXIR_MODEL")
    # Pin a clean global root and clear the env model override so resolution is
    # deterministic (built-in default unless the test writes a config).
    System.put_env("PIXIR_HOME", home)
    System.delete_env("PIXIR_MODEL")

    on_exit(fn ->
      File.rm_rf!(home)

      if prev_home,
        do: System.put_env("PIXIR_HOME", prev_home),
        else: System.delete_env("PIXIR_HOME")

      if prev_model,
        do: System.put_env("PIXIR_MODEL", prev_model),
        else: System.delete_env("PIXIR_MODEL")
    end)

    %{home: home}
  end

  test "Astra max survives Config and the body preview", %{home: home} do
    write_config(home, %{"model" => "gpt-6-astra", "reasoning" => %{"effort" => "max"}})
    assert Pixir.Config.reasoning_effort() == "max"
    assert {:ok, body} = Provider.request_body_preview(%{})
    assert body["reasoning"] == %{"effort" => "max"}
  end

  test "explicit Astra max is emitted and incompatible model/backend overrides refuse it" do
    assert {:ok, body} =
             Provider.request_body_preview(%{model: "gpt-6-astra", reasoning_effort: "max"})

    assert body["reasoning"] == %{"effort" => "max"}

    for model <- ["gpt-5.5", "unknown-astra", "gpt-6-astra-preview"] do
      assert {:error,
              %{
                error: %{
                  kind: :invalid_config,
                  details: %{reason: :unsupported_reasoning_effort, field: :reasoning_effort}
                }
              }} =
               Provider.request_body_preview(%{model: model}, reasoning_effort: "max")
    end

    backend = %{
      "mode" => "open_responses",
      "responses_url" => "https://example.invalid/v1/responses",
      "auth" => %{"policy" => "none"}
    }

    assert {:error,
            %{
              error: %{
                kind: :invalid_config,
                details: %{reason: :unsupported_reasoning_effort, field: :reasoning_effort}
              }
            }} =
             Provider.request_body_preview(%{model: "gpt-6-astra", reasoning_effort: "max"},
               responses_backend: backend
             )
  end

  defmodule StaticAuth do
    use GenServer
    def start_link(test), do: GenServer.start_link(__MODULE__, test)
    def init(test), do: {:ok, test}

    def handle_call(:request_headers, _from, test) do
      send(test, :effort_auth_called)
      {:reply, {:ok, []}, test}
    end
  end

  test "stream sends exactly previewed max and rejects invalid overrides before auth or transport" do
    auth = start_supervised!({StaticAuth, self()})
    test = self()

    transport = fn request, acc, reduce ->
      send(test, {:effort_body, Jason.decode!(request.body)})
      acc = reduce.({:status, 200}, acc)

      event = %{
        "type" => "response.completed",
        "response" => %{"status" => "completed", "output" => []}
      }

      {:ok, reduce.({:data, "data: " <> Jason.encode!(event) <> "\n\n"}, acc)}
    end

    request = %{model: "gpt-6-astra", reasoning_effort: :max}
    assert {:ok, preview} = Provider.request_body_preview(request)
    assert {:ok, _} = Provider.stream(request, auth: auth, transport: transport)
    assert_receive :effort_auth_called
    assert_receive {:effort_body, ^preview}

    for {request, extra} <- [
          {%{model: "gpt-5.5"}, [reasoning_effort: "max", model: "gpt-6-astra"]},
          {%{model: "gpt-6-astra"},
           [reasoning_effort: "max", base_url: "https://example.invalid"]},
          {%{"model" => "gpt-5.5", "reasoning_effort" => " max "}, []}
        ] do
      assert {:error,
              %{
                error: %{
                  kind: :invalid_config,
                  details: %{reason: :unsupported_reasoning_effort, field: :reasoning_effort}
                }
              }} = Provider.stream(request, [auth: auth, transport: transport] ++ extra)

      refute_receive :effort_auth_called
      refute_receive {:effort_body, _}
    end

    collision = %{:model => "gpt-6-astra", :reasoning_effort => nil, "reasoning_effort" => "max"}

    assert {:error,
            %{
              kind: :invalid_args,
              details: %{"field" => "reasoning_effort", "reason" => "normalized_key_collision"}
            }} =
             Provider.stream(collision, auth: auth, transport: transport)

    refute_receive :effort_auth_called
    refute_receive {:effort_body, _}
  end

  test "body preview preserves non-max behavior and explicit omission" do
    for effort <- ["low", "medium", "high", "xhigh"] do
      for model <- ["gpt-6-astra", "gpt-5.5", "unknown-model"] do
        assert {:ok, body} =
                 Provider.request_body_preview(%{model: model, reasoning_effort: effort})

        assert body["reasoning"] == %{"effort" => effort}
      end
    end

    for effort <- [nil, "default"] do
      assert {:ok, body} =
               Provider.request_body_preview(%{model: "gpt-5.5", reasoning_effort: effort},
                 reasoning_effort: "max"
               )

      refute Map.has_key?(body, "reasoning")
    end

    assert {:ok, body} =
             Provider.request_body_preview(%{
               "model" => "gpt-6-astra",
               "reasoning_effort" => " max "
             })

    assert body["reasoning"] == %{"effort" => "max"}
  end

  test "model and backend overrides are authoritative over retained Config max", %{home: home} do
    write_config(home, %{"model" => "gpt-6-astra", "reasoning" => %{"effort" => "max"}})

    assert {:error,
            %{
              error: %{
                kind: :invalid_config,
                details: %{reason: :unsupported_reasoning_effort, field: :reasoning_effort}
              }
            }} = Provider.request_body_preview(%{}, model: "gpt-5.5")

    assert {:ok, body} = Provider.request_body_preview(%{}, reasoning_effort: "high")
    assert body["reasoning"] == %{"effort" => "high"}

    backend = %{
      "mode" => "open_responses",
      "responses_url" => "https://api.openai.com/v1/responses",
      "auth" => %{"policy" => "none"}
    }

    assert {:error,
            %{
              error: %{
                kind: :invalid_config,
                details: %{reason: :unsupported_reasoning_effort, field: :reasoning_effort}
              }
            }} = Provider.request_body_preview(%{}, responses_backend: backend)

    write_config(home, %{
      "model" => "gpt-5.5",
      "responses_backend" => backend,
      "reasoning" => %{"effort" => "max"}
    })

    assert {:ok, body} =
             Provider.request_body_preview(%{model: "gpt-6-astra"},
               responses_backend: %{"mode" => "chatgpt_codex"}
             )

    assert body["reasoning"] == %{"effort" => "max"}
  end

  defp write_config(home, map) do
    File.write!(Path.join(home, "config.json"), Jason.encode!(map))
  end

  describe "models/0 (built-in)" do
    test "advertises Astra without changing the default" do
      assert "gpt-6-astra" in Provider.built_in_models()
      assert Provider.default_model() == "gpt-5.5"

      assert %{"id" => "gpt-6-astra", "name" => "gpt-6-astra", "default" => false} in Provider.models()

      assert Provider.model_supported?("gpt-6-astra")
    end

    test "lists the built-in catalog with exactly one default" do
      models = Provider.models()

      assert is_list(models)
      assert Enum.all?(models, &match?(%{"id" => _, "name" => _, "default" => _}, &1))

      defaults = Enum.filter(models, & &1["default"])
      assert length(defaults) == 1
      assert hd(defaults)["id"] == Provider.default_model()

      ids = Enum.map(models, & &1["id"])
      assert "gpt-5.5" in ids
      assert ids == Enum.uniq(ids)
    end
  end

  describe "models/0 (config override)" do
    test "a config \"models\" array replaces the built-in list", %{home: home} do
      write_config(home, %{"models" => ["custom-a", "custom-b"]})

      ids = Provider.models() |> Enum.map(& &1["id"])

      assert "custom-a" in ids
      assert "custom-b" in ids
      # The built-in slugs are gone (config replaces, not merges)…
      refute "gpt-5.4" in ids
      refute "gpt-6-astra" in ids
      assert ids == ["gpt-5.5", "custom-a", "custom-b"]
    end

    test "the active default is always present and flagged, even if config omits it", %{
      home: home
    } do
      # config narrows to a list that excludes the resolved default
      write_config(home, %{"model" => "gpt-5.5", "models" => ["other-1", "other-2"]})

      models = Provider.models()
      ids = Enum.map(models, & &1["id"])

      assert "gpt-5.5" in ids
      assert Enum.find(models, &(&1["id"] == "gpt-5.5"))["default"] == true
      assert length(Enum.filter(models, & &1["default"])) == 1
    end

    test "a malformed/empty \"models\" array falls back to the built-in list", %{home: home} do
      write_config(home, %{"models" => []})
      assert Provider.models() |> Enum.map(& &1["id"]) |> Enum.member?("gpt-5.5")

      write_config(home, %{"models" => [123, %{"x" => 1}]})
      assert Provider.models() |> Enum.map(& &1["id"]) |> Enum.member?("gpt-5.5")
    end
  end

  describe "model_supported?/1" do
    test "true for a catalog id, false otherwise" do
      assert Provider.model_supported?(Provider.default_model())
      assert Provider.model_supported?("gpt-5.5")
      refute Provider.model_supported?("totally-bogus")
      refute Provider.model_supported?(nil)
      refute Provider.model_supported?(123)
    end

    test "honors a config override", %{home: home} do
      write_config(home, %{"models" => ["only-this"]})
      assert Provider.model_supported?("only-this")
      refute Provider.model_supported?("gpt-5.4")
      refute Provider.model_supported?("gpt-6-astra")
    end

    test "honors a config override explicitly including Astra", %{home: home} do
      write_config(home, %{"models" => ["gpt-6-astra"]})
      assert Provider.model_supported?("gpt-6-astra")
      assert Enum.map(Provider.models(), & &1["id"]) == ["gpt-5.5", "gpt-6-astra"]
      assert Provider.default_model() == "gpt-5.5"
    end
  end
end
