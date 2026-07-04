defmodule Pixir.ProviderModelTest do
  # async: false — mutates Application/System env and PIXIR_HOME.
  use ExUnit.Case, async: false

  alias Pixir.Provider

  setup do
    home =
      Path.join(
        System.tmp_dir!(),
        "pixir-cfg-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(home)
    prev_home = System.get_env("PIXIR_HOME")
    prev_model_env = System.get_env("PIXIR_MODEL")
    prev_app = Application.get_env(:pixir, :model)

    System.put_env("PIXIR_HOME", home)
    System.delete_env("PIXIR_MODEL")
    Application.delete_env(:pixir, :model)

    on_exit(fn ->
      if prev_home,
        do: System.put_env("PIXIR_HOME", prev_home),
        else: System.delete_env("PIXIR_HOME")

      if prev_model_env,
        do: System.put_env("PIXIR_MODEL", prev_model_env),
        else: System.delete_env("PIXIR_MODEL")

      if prev_app,
        do: Application.put_env(:pixir, :model, prev_app),
        else: Application.delete_env(:pixir, :model)

      File.rm_rf!(home)
    end)

    %{home: home}
  end

  test "falls back to the built-in default" do
    assert Provider.default_model() == "gpt-5.5"
  end

  test "reads the model from ~/.pixir/config.json", %{home: home} do
    File.write!(
      Path.join(home, "config.json"),
      Jason.encode!(%{"model" => "gpt-5.3-codex-spark"})
    )

    assert Provider.default_model() == "gpt-5.3-codex-spark"
  end

  test "PIXIR_MODEL overrides config.json", %{home: home} do
    File.write!(Path.join(home, "config.json"), Jason.encode!(%{"model" => "from-config"}))
    System.put_env("PIXIR_MODEL", "from-env")
    assert Provider.default_model() == "from-env"
  end

  test "application config wins over everything" do
    System.put_env("PIXIR_MODEL", "from-env")
    Application.put_env(:pixir, :model, "from-app")
    assert Provider.default_model() == "from-app"
  end
end
