defmodule Pixir.Test.WorkspaceFixtures do
  @moduledoc false

  def outside_workspace_fixture(ws) do
    outside =
      Path.join(
        System.tmp_dir!(),
        "pixir-outside-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(outside)
    outside_file = Path.join(outside, "neighbor-notes.txt")
    File.write!(outside_file, "neutral bait")
    symlink = Path.join(ws, "outside-link")
    File.ln_s!(outside, symlink)

    %{
      outside: outside,
      outside_file: outside_file,
      symlink: symlink,
      symlink_token: "outside-link/neighbor-notes.txt"
    }
  end
end
