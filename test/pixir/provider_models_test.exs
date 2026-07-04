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

  defp write_config(home, map) do
    File.write!(Path.join(home, "config.json"), Jason.encode!(map))
  end

  describe "models/0 (built-in)" do
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
    end
  end
end
