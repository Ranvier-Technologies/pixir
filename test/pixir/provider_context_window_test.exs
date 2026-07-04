defmodule Pixir.ProviderContextWindowTest do
  # async: false — these drive `PIXIR_HOME` (a process-global env var) to isolate
  # `~/.pixir/config.json`, so they must not run concurrently with anything else
  # that reads the global root.
  use ExUnit.Case, async: false

  alias Pixir.Provider.ContextWindow

  setup do
    home =
      Path.join(
        System.tmp_dir!(),
        "pixir-window-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(home)
    prev_home = System.get_env("PIXIR_HOME")
    System.put_env("PIXIR_HOME", home)

    on_exit(fn ->
      File.rm_rf!(home)

      if prev_home,
        do: System.put_env("PIXIR_HOME", prev_home),
        else: System.delete_env("PIXIR_HOME")
    end)

    %{home: home}
  end

  defp write_config(home, map) do
    File.write!(Path.join(home, "config.json"), Jason.encode!(map))
  end

  defp tier_for(input_tokens) do
    assert {:ok, %{"available" => true, "tier" => tier}} =
             ContextWindow.assess(%{input_tokens: input_tokens}, "tier-model")

    tier
  end

  describe "window_tokens/1 (built-in table)" do
    test "every built-in catalog model has a conservative window" do
      for model <- ~w(gpt-5.5 gpt-5.4 gpt-5.4-mini gpt-5.3-codex gpt-5.3-codex-spark gpt-5.2) do
        assert {:ok, tokens} = ContextWindow.window_tokens(model)
        assert is_integer(tokens)
        assert tokens > 0
      end
    end

    test "the GPT-5 family uses the documented 272K max-input bound" do
      assert {:ok, 272_000} = ContextWindow.window_tokens("gpt-5.5")
    end

    test "gpt-5.3-codex-spark uses the real-time 128K SKU window" do
      assert {:ok, 128_000} = ContextWindow.window_tokens("gpt-5.3-codex-spark")

      assert {:ok,
              %{
                "input_tokens" => 125_000,
                "window_tokens" => 128_000,
                "tier" => "critical"
              }} = ContextWindow.assess(%{input_tokens: 125_000}, "gpt-5.3-codex-spark")
    end

    test "an unknown model is an explicit structured error, never a guess" do
      assert {:error, %{ok: false, error: %{kind: :context_window_unknown, details: details}}} =
               ContextWindow.window_tokens("mystery-model")

      assert details.model == "mystery-model"

      assert {:error, %{error: %{kind: :context_window_unknown}}} =
               ContextWindow.window_tokens(nil)

      assert {:error, %{error: %{kind: :context_window_unknown}}} =
               ContextWindow.window_tokens("")
    end
  end

  describe "window_tokens/1 (config override)" do
    test "a \"context_windows\" entry overrides the built-in value", %{home: home} do
      write_config(home, %{"context_windows" => %{"gpt-5.5" => 50_000}})

      assert {:ok, 50_000} = ContextWindow.window_tokens("gpt-5.5")
    end

    test "config can add a window for a model outside the built-in table", %{home: home} do
      write_config(home, %{"context_windows" => %{"my-local-model" => 32_000}})

      assert {:ok, 32_000} = ContextWindow.window_tokens("my-local-model")
    end

    test "an invalid override is ignored, not trusted", %{home: home} do
      write_config(home, %{"context_windows" => %{"gpt-5.5" => "lots", "weird-model" => -5}})

      # Built-in value stands for a known model …
      assert {:ok, 272_000} = ContextWindow.window_tokens("gpt-5.5")
      # … and a bad override cannot conjure a window for an unknown one.
      assert {:error, %{error: %{kind: :context_window_unknown}}} =
               ContextWindow.window_tokens("weird-model")
    end
  end

  describe "assess/2 (pressure tiers, ADR 0020)" do
    setup %{home: home} do
      write_config(home, %{"context_windows" => %{"tier-model" => 1_000}})
      :ok
    end

    test "0-70% of the window is silent" do
      assert tier_for(0) == "none"
      assert tier_for(350) == "none"
      assert tier_for(699) == "none"
    end

    test "70-80% is a light advisory" do
      assert tier_for(700) == "advisory"
      assert tier_for(799) == "advisory"
    end

    test "80-90% is a visible warning" do
      assert tier_for(800) == "warning"
      assert tier_for(899) == "warning"
    end

    test "90%+ is recovery-eligible (critical)" do
      assert tier_for(900) == "critical"
      assert tier_for(5_000) == "critical"
    end

    test "the assessment carries the gauge evidence" do
      assert {:ok, assessment} = ContextWindow.assess(%{input_tokens: 850}, "tier-model")

      assert assessment["input_tokens"] == 850
      assert assessment["window_tokens"] == 1_000
      assert_in_delta assessment["ratio"], 0.85, 0.0001
      assert assessment["model"] == "tier-model"
    end

    test "accepts the string-keyed usage_summary shape recorded in the Log" do
      assert {:ok, %{"tier" => "warning"}} =
               ContextWindow.assess(%{"input_tokens" => 850}, "tier-model")
    end

    test "an unknown model degrades to advisory-unavailable with no faked tier" do
      assert {:ok, assessment} = ContextWindow.assess(%{input_tokens: 999_999}, "mystery-model")

      assert assessment == %{
               "available" => false,
               "model" => "mystery-model",
               "tier" => "unavailable",
               "reason" => "context_window_unknown"
             }

      refute Map.has_key?(assessment, "ratio")
      refute Map.has_key?(assessment, "window_tokens")
    end

    test "a missing or malformed usage summary reads as zero pressure" do
      assert {:ok, %{"tier" => "none", "input_tokens" => 0}} =
               ContextWindow.assess(nil, "tier-model")

      assert {:ok, %{"tier" => "none", "input_tokens" => 0}} =
               ContextWindow.assess(%{"input_tokens" => "many"}, "tier-model")
    end
  end
end
