defmodule Pixir.Providers.RegistryTest do
  use ExUnit.Case, async: false

  alias Pixir.Providers.Registry

  defmodule UnknownProvider do
  end

  defmodule CallableProvider do
    def stream(_request, _opts), do: {:error, :not_called}
  end

  test "resolve routes claude model ids to Anthropic and everything else to OpenAI" do
    assert Registry.resolve("claude-fable-5").provider == Pixir.Providers.Anthropic
    assert Registry.resolve("gpt-5.5").provider == Pixir.Provider
    assert Registry.resolve("unknown-model").provider == Pixir.Provider
    assert Registry.resolve(nil).provider == Pixir.Provider
  end

  test "canonical request selection rejects non-callable explicit Provider identities" do
    selection = fn provider_intent ->
      %{provider_intent: provider_intent, request: %{}, provider_opts: []}
    end

    invalid = [
      {:explicit, nil},
      {:explicit, false},
      {:explicit, true},
      {:explicit, :not_a_real_module_atom},
      {:direct, Pixir.Issue317UnloadedProvider}
    ]

    for provider_intent <- invalid do
      assert {:error,
              %{
                error: %{
                  kind: :invalid_config,
                  details: %{field: :provider, reason: :invalid_resolved_request}
                }
              }} = Registry.resolve_request(selection.(provider_intent), raw_config: %{})
    end

    assert {:ok, resolved} =
             Registry.resolve_request(
               selection.({:explicit, CallableProvider}),
               raw_config: %{}
             )

    assert Pixir.Providers.ResolvedProviderRequest.provider(resolved) == CallableProvider
  end

  test "entry_for resolves known providers and falls back for unknown modules" do
    assert Registry.entry_for(Pixir.Provider).provider == Pixir.Provider
    assert Registry.entry_for(Pixir.Providers.Anthropic).provider == Pixir.Providers.Anthropic
    assert Registry.entry_for(UnknownProvider).provider == Pixir.Provider
  end

  test "merged catalog includes OpenAI and Anthropic models with one advertised default" do
    models = Registry.models()

    assert Enum.any?(models, &(&1["id"] == "gpt-5.5"))
    assert Enum.any?(models, &(&1["id"] == "claude-fable-5"))
    assert Enum.any?(models, &(&1["id"] == "claude-opus-4-8"))
    assert Enum.any?(models, &(&1["id"] == "claude-sonnet-5"))
    assert Enum.any?(models, &(&1["id"] == "claude-haiku-4-5-20251001"))
    assert Enum.count(models, &(&1["default"] == true)) == 1
  end

  test "model_supported checks the merged catalog" do
    assert Registry.model_supported?("claude-fable-5")
    assert Registry.model_supported?("gpt-5.5")
    refute Registry.model_supported?("unknown-model")
    refute Registry.model_supported?(nil)
  end

  test "anthropic_models config overrides built-ins without claiming the picker default" do
    home = Path.join(System.tmp_dir!(), "pixir-registry-#{System.unique_integer([:positive])}")
    previous_home = System.get_env("PIXIR_HOME")

    try do
      File.mkdir_p!(home)
      System.put_env("PIXIR_HOME", home)

      File.write!(
        Path.join(home, "config.json"),
        Jason.encode!(%{"anthropic_models" => ["claude-refreshed-test"]})
      )

      anthropic = Registry.entry_for(Pixir.Providers.Anthropic)

      assert Enum.map(anthropic.models, & &1["id"]) == [
               "claude-fable-5",
               "claude-refreshed-test"
             ]

      # Routing default (entry.default_model) is claude-fable-5, but catalog
      # entries never claim the ACP picker default: the merged catalog
      # advertises exactly one, the OpenAI session default.
      assert anthropic.default_model == "claude-fable-5"
      refute Enum.any?(anthropic.models, & &1["default"])
    after
      if previous_home,
        do: System.put_env("PIXIR_HOME", previous_home),
        else: System.delete_env("PIXIR_HOME")

      File.rm_rf!(home)
    end
  end

  test "capabilities expose provider dialect metadata" do
    openai = Registry.entry_for(Pixir.Provider)
    anthropic = Registry.entry_for(Pixir.Providers.Anthropic)

    assert openai.capabilities.reasoning_dialect == nil
    assert openai.capabilities.prompt_cache == :prompt_cache_key
    assert openai.capabilities.prompt_contract_version == nil
    assert openai.capabilities.tool_dialect == :responses
    assert openai.capabilities.hosted_tools == true

    assert anthropic.capabilities.reasoning_dialect == "anthropic"
    assert anthropic.capabilities.prompt_cache == :cache_control
    assert anthropic.capabilities.prompt_contract_version == "pa1"
    assert anthropic.capabilities.tool_dialect == :anthropic
    assert anthropic.capabilities.hosted_tools == false
  end

  test "auth metadata is provider-specific" do
    openai = Registry.entry_for(Pixir.Provider)
    anthropic = Registry.entry_for(Pixir.Providers.Anthropic)

    assert openai.auth == %{
             env_var: "OPENAI_API_KEY",
             scheme: :oauth_or_api_key,
             login_supported: true
           }

    assert anthropic.auth == %{
             env_var: "ANTHROPIC_API_KEY",
             scheme: :api_key_header,
             login_supported: false
           }
  end
end
