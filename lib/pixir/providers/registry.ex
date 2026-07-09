defmodule Pixir.Providers.Registry do
  @moduledoc """
  Provider catalog and routing metadata for Pixir provider dialects.
  """

  alias Pixir.Providers.Anthropic

  @type entry :: %{
          provider: module(),
          default_model: String.t(),
          models: [map()],
          auth: %{
            env_var: String.t(),
            scheme: :oauth_or_api_key | :api_key_header,
            login_supported: boolean()
          },
          capabilities: %{
            reasoning_dialect: nil | String.t(),
            prompt_cache: :prompt_cache_key | :cache_control,
            prompt_contract_version: nil | String.t(),
            tool_dialect: :responses | :anthropic,
            hosted_tools: boolean()
          }
        }

  @anthropic_models [
    %{"id" => "claude-fable-5", "name" => "claude-fable-5", "default" => false},
    %{"id" => "claude-opus-4-8", "name" => "claude-opus-4-8", "default" => false},
    %{"id" => "claude-sonnet-5", "name" => "claude-sonnet-5", "default" => false},
    %{
      "id" => "claude-haiku-4-5-20251001",
      "name" => "claude-haiku-4-5-20251001",
      "default" => false
    }
  ]

  @doc "Resolve a model id to the provider entry that owns its dialect."
  @spec resolve(String.t() | nil) :: entry()
  def resolve("claude-" <> _), do: anthropic_entry()
  def resolve(_model), do: openai_entry()

  @doc "Resolve a provider module to its registry entry. Unknown modules use OpenAI defaults."
  @spec entry_for(module()) :: entry()
  def entry_for(Pixir.Provider), do: openai_entry()
  def entry_for(Anthropic), do: anthropic_entry()
  def entry_for(_provider), do: openai_entry()

  @doc "Merged provider model catalog advertised by ACP."
  @spec models() :: [map()]
  def models, do: openai_entry().models ++ anthropic_entry().models

  @doc "Whether `model_id` is in the merged provider catalog."
  @spec model_supported?(String.t()) :: boolean()
  def model_supported?(model_id) when is_binary(model_id) do
    Enum.any?(models(), &(&1["id"] == model_id))
  end

  def model_supported?(_model_id), do: false

  defp openai_entry do
    %{
      provider: Pixir.Provider,
      default_model: Pixir.Provider.default_model(),
      models: Pixir.Provider.models(),
      auth: %{
        env_var: "OPENAI_API_KEY",
        scheme: :oauth_or_api_key,
        login_supported: true
      },
      capabilities: %{
        reasoning_dialect: nil,
        prompt_cache: :prompt_cache_key,
        prompt_contract_version: nil,
        tool_dialect: :responses,
        hosted_tools: true
      }
    }
  end

  defp anthropic_entry do
    %{
      provider: Anthropic,
      default_model: "claude-fable-5",
      models: @anthropic_models,
      auth: %{
        env_var: "ANTHROPIC_API_KEY",
        scheme: :api_key_header,
        login_supported: false
      },
      capabilities: %{
        reasoning_dialect: "anthropic",
        prompt_cache: :cache_control,
        prompt_contract_version: Anthropic.Prompt.prompt_contract_version(),
        tool_dialect: :anthropic,
        hosted_tools: false
      }
    }
  end
end
