defmodule Pixir.Delegate.HandleTest do
  use ExUnit.Case, async: true

  alias Pixir.Delegate.Handle

  test "bare parent Session ids are validated without trimming" do
    hostile = " valid "

    for result <- [Handle.build(hostile), Handle.resolve(hostile)] do
      assert {:error, %{error: %{kind: :invalid_args}} = error} = result
      refute inspect(error) =~ hostile
    end
  end

  test "decoded Delegate handles reject hostile and invalid UTF-8 Session ids" do
    hostile = "../../../outside;PWN"

    handles = [
      "dlg1_" <> Base.url_encode64(hostile, padding: false),
      "dlg1_" <> Base.url_encode64(<<255>>, padding: false)
    ]

    for handle <- handles do
      assert {:error, %{error: %{kind: :invalid_args}} = error} = Handle.resolve(handle)
      refute inspect(error) =~ hostile
      refute inspect(error) =~ "PWN"
    end
  end
end
