defmodule Pixir.Providers.RegistryTest do
  use ExUnit.Case, async: false

  alias Pixir.Providers.Registry

  defmodule UnknownProvider do
  end

  test "resolve routes claude model ids to Anthropic and everything else to OpenAI" do
    assert Registry.resolve("claude-fable-5").provider == Pixir.Providers.Anthropic
    assert Registry.resolve("gpt-5.5").provider == Pixir.Provider
    assert Registry.resolve("unknown-model").provider == Pixir.Provider
    assert Registry.resolve(nil).provider == Pixir.Provider
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
