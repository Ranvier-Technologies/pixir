defmodule Pixir.RecoveryCommandsTest do
  use ExUnit.Case, async: true

  alias Pixir.RecoveryCommands

  test "renders commands only for canonical Session ids" do
    assert {:ok, commands} = RecoveryCommands.commands("sess-1")
    assert commands["diagnose_command"] == "pixir diagnose session sess-1 --json"
    assert commands["resume_command"] =~ "pixir resume sess-1"
  end

  test "rejects hostile ids without reflecting them into command text" do
    hostile = "../../../outside;touch-PWN"

    assert {:error, %{error: %{kind: :invalid_args}} = error} =
             RecoveryCommands.commands(hostile)

    refute inspect(error) =~ hostile
    refute inspect(error) =~ "touch-PWN"
  end
end
