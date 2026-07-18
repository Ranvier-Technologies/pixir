defmodule PixirMonitor.Projection.UnitIdentityTest do
  @moduledoc "Contract pins for delimiter-free logical-unit identity components."
  use ExUnit.Case, async: true

  alias PixirMonitor.Projection.UnitIdentity

  test "accepts the runtime safe-id charset" do
    for id <- ["a", "A0", "review_main", "sub-worker-1"] do
      assert UnitIdentity.component(id) == {:ok, id}
    end
  end

  test "rejects delimiters, unsafe prefixes, blanks, and non-strings" do
    for id <- ["", " ", "review:main", "review.main", "_review", String.duplicate("a", 257), false, 1, %{}] do
      assert {:error, %{kind: "run_unit_identity_invalid"}} =
               UnitIdentity.component(id)
    end
  end
end
