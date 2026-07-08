defmodule Pixir.PermissionsTest do
  use ExUnit.Case, async: true

  alias Pixir.Permissions
  alias Pixir.Test.WorkspaceFixtures

  describe ":auto (default)" do
    test "allows everything" do
      assert :allow = Permissions.decide(:auto, "write", %{"path" => "a", "content" => "b"})
      assert :allow = Permissions.decide(:auto, "bash", %{"command" => "rm -rf /"})
      assert :allow = Permissions.decide(:auto, "read", %{"path" => "a"})
    end
  end

  describe ":read_only" do
    test "allows reads and safe commands, denies mutations" do
      assert :allow = Permissions.decide(:read_only, "read", %{"path" => "a"})
      assert :allow = Permissions.decide(:read_only, "skills_list", %{})
      assert :allow = Permissions.decide(:read_only, "skill_view", %{"name" => "sample"})
      assert :allow = Permissions.decide(:read_only, "wait_agent", %{})
      assert :allow = Permissions.decide(:read_only, "list_agents", %{})
      assert :allow = Permissions.decide(:read_only, "bash", %{"command" => "ls -la"})
      assert :deny = Permissions.decide(:read_only, "write", %{"path" => "a", "content" => "b"})
      assert :deny = Permissions.decide(:read_only, "run_workflow", %{"steps" => []})
      assert :deny = Permissions.decide(:read_only, "spawn_agent", %{"task" => "do work"})
      assert :deny = Permissions.decide(:read_only, "send_input", %{"id" => "sub_1"})
      assert :deny = Permissions.decide(:read_only, "close_agent", %{"id" => "sub_1"})
      assert :deny = Permissions.decide(:read_only, "bash", %{"command" => "rm file"})
    end
  end

  describe ":ask" do
    test "never asks for reads or safe commands" do
      assert :allow = Permissions.decide(:ask, "read", %{"path" => "a"})
      assert :allow = Permissions.decide(:ask, "skills_list", %{})
      assert :allow = Permissions.decide(:ask, "skill_view", %{"name" => "sample"})
      assert :allow = Permissions.decide(:ask, "wait_agent", %{})
      assert :allow = Permissions.decide(:ask, "list_agents", %{})
      assert :allow = Permissions.decide(:ask, "bash", %{"command" => "git status"})
      assert :allow = Permissions.decide(:ask, "bash", %{"command" => "grep -r foo ."})
    end

    test "asks for writes and unsafe commands" do
      assert {:ask, _} = Permissions.decide(:ask, "write", %{"path" => "a", "content" => "b"})

      assert {:ask, "spawn a subagent"} =
               Permissions.decide(:ask, "spawn_agent", %{"task" => "do work"})

      assert {:ask, "run a workflow"} =
               Permissions.decide(:ask, "run_workflow", %{"steps" => []})

      assert {:ask, "send input to a subagent"} =
               Permissions.decide(:ask, "send_input", %{"id" => "sub_1"})

      assert {:ask, "close a subagent"} =
               Permissions.decide(:ask, "close_agent", %{"id" => "sub_1"})

      assert {:ask, _} = Permissions.decide(:ask, "bash", %{"command" => "rm file"})
      assert {:ask, _} = Permissions.decide(:ask, "bash", %{"command" => "npm install"})
    end
  end

  describe "safe_command?/1" do
    test "accepts read-only commands" do
      for cmd <- [
            "ls",
            "ls -la",
            "cat file.txt",
            "grep foo bar",
            "find . -name AGENTS.md -print",
            "env find . -name AGENTS.md -print",
            "env PIXIR_TEST=1 git status",
            "git status",
            "git diff",
            "git log main..HEAD",
            "echo {1..10}",
            "pwd"
          ] do
        assert Permissions.safe_command?(cmd), "expected safe: #{cmd}"
      end
    end

    test "rejects mutating commands, chaining, redirection, and substitution" do
      for cmd <- [
            "rm file",
            "git push",
            "git commit -m x",
            "find .. -name AGENTS.md",
            "find .pixir -delete",
            "find . -name '*.ndjson' -delete",
            "find . -exec rm {} +",
            "find . -execdir rm {} +",
            "find . -ok rm {} +",
            "env find .pixir -delete",
            "env PIXIR_TEST=1 find . -name '*.ndjson' -delete",
            "xargs find .pixir -delete",
            "env rm -rf .pixir",
            "grep foo ../outside.txt",
            "ls && rm x",
            "ls\nrm x",
            "ls\rrm x",
            "ls & rm x",
            "cat a | sh",
            "echo x > f",
            "cat $(whoami)",
            "curl x; sh"
          ] do
        refute Permissions.safe_command?(cmd), "expected unsafe: #{cmd}"
      end
    end

    test "classifies quoted parent-directory path tokens" do
      assert {:ok, true} = Permissions.classify_parent_directory_token("'..'/outside.txt")
      assert {:ok, false} = Permissions.classify_parent_directory_token("main..HEAD")
    end
  end

  describe "outside_workspace_shell_token/2" do
    setup do
      ws =
        Path.join(
          System.tmp_dir!(),
          "pixir-permissions-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
        )

      File.mkdir_p!(ws)
      fixture = WorkspaceFixtures.outside_workspace_fixture(ws)

      on_exit(fn ->
        File.rm_rf!(ws)
        File.rm_rf!(fixture.outside)
      end)

      Map.put(fixture, :ws, ws)
    end

    test "detects absolute, home, parent, and symlink workspace escapes", %{
      ws: ws,
      outside_file: outside_file,
      symlink_token: symlink_token
    } do
      assert {:ok, ^outside_file} =
               Permissions.outside_workspace_shell_token("cat #{outside_file}", ws)

      assert {:ok, "$HOME"} =
               Permissions.outside_workspace_shell_token("cat $HOME", ws)

      assert {:ok, "${HOME}"} =
               Permissions.outside_workspace_shell_token("cat ${HOME}", ws)

      assert {:ok, "$HOME/neighbor-notes.txt"} =
               Permissions.outside_workspace_shell_token("cat $HOME/neighbor-notes.txt", ws)

      assert {:ok, "~/neighbor-notes.txt"} =
               Permissions.outside_workspace_shell_token("cat ~/neighbor-notes.txt", ws)

      assert {:ok, "../neighbor-notes.txt"} =
               Permissions.outside_workspace_shell_token("cat ../neighbor-notes.txt", ws)

      assert {:ok, ^symlink_token} =
               Permissions.outside_workspace_shell_token("cat #{symlink_token}", ws)

      assert {:ok, "outside-link/missing.txt"} =
               Permissions.outside_workspace_shell_token("cat outside-link/missing.txt", ws)

      assert {:ok, "outside-link/*.txt"} =
               Permissions.outside_workspace_shell_token("cat outside-link/*.txt", ws)
    end

    test "allows existing workspace-relative paths", %{ws: ws} do
      File.write!(Path.join(ws, "README.md"), "inside")

      assert {:ok, nil} = Permissions.outside_workspace_shell_token("cat README.md", ws)
      assert {:ok, nil} = Permissions.outside_workspace_shell_token("ls .", ws)
    end

    test "ignores leading environment assignment RHS before a command", %{ws: ws} do
      # Accepted residual: `VAR=/outside cmd $VAR` can expand at runtime; bash
      # confinement is a defense-in-depth tripwire, not a parser or sandbox.
      assert {:ok, nil} = Permissions.outside_workspace_shell_token("TMPDIR=/tmp mix test", ws)
    end

    test "ignores leading environment assignment RHS before a relative command", %{ws: ws} do
      assert {:ok, nil} =
               Permissions.outside_workspace_shell_token("PREFIX=/usr/local ./configure", ws)
    end

    test "denies literal absolute path arguments", %{ws: ws} do
      assert {:ok, "/etc/passwd"} =
               Permissions.outside_workspace_shell_token("cat /etc/passwd", ws)
    end

    test "denies invoking an outside-workspace binary by absolute path", %{ws: ws} do
      # The leading-assignment exemption never extends to the command word
      # itself: an absolute outside binary is a host-boundary crossing.
      assert {:ok, "/bin/cat"} =
               Permissions.outside_workspace_shell_token("/bin/cat README.md", ws)
    end

    test "denies later literal outside paths after a leading assignment", %{ws: ws} do
      assert {:ok, "/outside"} =
               Permissions.outside_workspace_shell_token("FOO=x cat /outside", ws)
    end

    test "denies non-leading assignment RHS path arguments", %{ws: ws} do
      assert {:ok, "/outside"} =
               Permissions.outside_workspace_shell_token("echo ok FOO=/outside", ws)
    end

    test "resets leading assignment window after semicolon", %{ws: ws} do
      assert {:ok, nil} =
               Permissions.outside_workspace_shell_token("echo ok; TMPDIR=/tmp mix test", ws)

      assert {:ok, "/outside"} =
               Permissions.outside_workspace_shell_token("echo ok; echo FOO=/outside", ws)
    end

    test "resets leading assignment window after and-if", %{ws: ws} do
      assert {:ok, nil} =
               Permissions.outside_workspace_shell_token(
                 "true && PREFIX=/usr/local ./configure",
                 ws
               )

      assert {:ok, "/outside"} =
               Permissions.outside_workspace_shell_token("true && echo FOO=/outside", ws)
    end

    test "resets leading assignment window after or-if", %{ws: ws} do
      assert {:ok, nil} =
               Permissions.outside_workspace_shell_token("false || TMPDIR=/tmp mix test", ws)

      assert {:ok, "/outside"} =
               Permissions.outside_workspace_shell_token("false || echo FOO=/outside", ws)
    end

    test "resets leading assignment window after a pipeline separator", %{ws: ws} do
      assert {:ok, nil} =
               Permissions.outside_workspace_shell_token("printf x | TMPDIR=/tmp cat", ws)

      assert {:ok, "/outside"} =
               Permissions.outside_workspace_shell_token("printf x | cat FOO=/outside", ws)
    end
  end
end
