defmodule Pixir.Tools.RegistryTest do
  use ExUnit.Case, async: true

  alias Pixir.Providers.Anthropic.Tools, as: AnthropicTools
  alias Pixir.Tools.Registry

  test "anthropic_specs matches Anthropic projection of Responses specs" do
    assert {:ok, projected} = AnthropicTools.project(Registry.responses_specs())
    assert Registry.anthropic_specs() == projected
  end
end
