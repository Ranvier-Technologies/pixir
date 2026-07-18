defmodule Pixir.CLISessionIdTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Pixir.CLI

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-cli-session-id-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)
    %{workspace: workspace}
  end

  test "resume and read-only Session commands exit 2 without echo or mutation", %{
    workspace: workspace
  } do
    hostile = "../../../outside;PWN"

    commands = [
      ["resume", hostile, "continue"],
      ["--json", "resume", hostile, "continue"],
      ["diagnose", "session", hostile, "--json"],
      ["tree", hostile, "--json"],
      ["compact", hostile, "--dry-run", "--json"],
      ["fork", hostile, "--dry-run", "--json"],
      ["inspect-replay", hostile, "--json"]
    ]

    File.cd!(workspace, fn ->
      for argv <- commands do
        {result, stdout, stderr} = capture_route(argv)
        assert result == {:error, 2}, inspect(argv)
        refute stdout =~ hostile
        refute stderr =~ hostile
        refute stdout =~ "PWN"
        refute stderr =~ "PWN"
      end
    end)

    refute File.exists?(Path.join(workspace, ".pixir"))
  end

  test "leading-hyphen Session ids are not echoed as unsupported options", %{workspace: workspace} do
    hostile = "-PWN"

    File.cd!(workspace, fn ->
      for argv <- [["resume", hostile, "continue"], ["--json", "resume", hostile, "continue"]] do
        {result, stdout, stderr} = capture_route(argv)
        assert result == {:error, 2}
        refute stdout =~ hostile
        refute stderr =~ hostile
      end
    end)

    refute File.exists?(Path.join(workspace, ".pixir"))
  end

  defp capture_route(argv) do
    parent = self()
    ref = make_ref()

    stderr =
      capture_io(:stderr, fn ->
        stdout =
          capture_io(fn ->
            send(parent, {ref, :result, CLI.route(argv)})
          end)

        send(parent, {ref, :stdout, stdout})
      end)

    assert_receive {^ref, :result, result}
    assert_receive {^ref, :stdout, stdout}
    {result, stdout, stderr}
  end
end
