defmodule Pixir.Test.OperatorState do
  @moduledoc false

  # Planted names that must never appear in the six #563 assertions. If a test
  # still sees these after isolate!/1, discovery is reading an undeclared root.
  @operator_model "operator-bleed-model"
  @operator_skill "operator-bleed"
  @operator_global_skill "operator-global-bleed"

  @doc "Model id planted in the fake operator `config.json`."
  def operator_model, do: @operator_model

  @doc "User-scope Skill name planted under `~/.agents/skills`."
  def operator_skill, do: @operator_skill

  @doc "Pixir-global Skill name planted under `$PIXIR_HOME/skills`."
  def operator_global_skill, do: @operator_global_skill

  @doc """
  Isolate `PIXIR_HOME` from the operator's real `~/.pixir`.

  With `plant: true` (the default), a real-looking `config.json` is written to a
  sibling planted root first. Isolation then redirects `PIXIR_HOME` at an empty
  dir. Deleting the redirect leaves the planted model / `compaction.native`
  false on the discovery path.
  """
  @spec isolate_pixir_home!(keyword()) :: map()
  def isolate_pixir_home!(opts \\ []) do
    isolate!(Keyword.merge([home: false, plant: true], opts))
  end

  @doc """
  Isolate both `PIXIR_HOME` and `HOME` (Skills `user_home`).

  Skills discovery walks repo `.agents/skills`, `$HOME/.agents/skills`, and
  `$PIXIR_HOME/skills`. ACP tests that pin an exact index need every root
  declared. Do not call this around `mix escript.build`: Mix/Hex read HOME.
  """
  @spec isolate_discovery_roots!(keyword()) :: map()
  def isolate_discovery_roots!(opts \\ []) do
    isolate!(Keyword.merge([home: true, plant: true], opts))
  end

  @doc """
  Point env at the planted operator roots without isolating.

  Used by the gate test to prove the planted state is visible on the leak path.
  """
  @spec expose_planted!(keyword()) :: map()
  def expose_planted!(opts \\ []) do
    isolate!(Keyword.merge([home: true, plant: true, isolate: false], opts))
  end

  @spec isolate!(keyword()) :: map()
  def isolate!(opts \\ []) do
    isolate? = Keyword.get(opts, :isolate, true)
    isolate_home? = Keyword.get(opts, :home, true)
    plant? = Keyword.get(opts, :plant, true)

    root = tmp_root()
    planted_pixir = Path.join(root, "planted-pixir")
    planted_home = Path.join(root, "planted-home")
    isolated_pixir = Path.join(root, "isolated-pixir")
    isolated_home = Path.join(root, "isolated-home")

    File.mkdir_p!(planted_pixir)
    File.mkdir_p!(planted_home)
    File.mkdir_p!(isolated_pixir)
    File.mkdir_p!(isolated_home)

    if plant?, do: write_operator_files!(planted_pixir, planted_home)

    previous_pixir = System.get_env("PIXIR_HOME")
    previous_home = System.get_env("HOME")

    pixir_home = if(isolate?, do: isolated_pixir, else: planted_pixir)
    user_home = if(isolate?, do: isolated_home, else: planted_home)

    System.put_env("PIXIR_HOME", pixir_home)
    if isolate_home?, do: System.put_env("HOME", user_home)

    ExUnit.Callbacks.on_exit(fn ->
      restore_env("PIXIR_HOME", previous_pixir)

      if isolate_home? do
        restore_env("HOME", previous_home)
      end

      File.rm_rf!(root)
    end)

    %{
      root: root,
      planted_pixir_home: planted_pixir,
      planted_user_home: planted_home,
      pixir_home: pixir_home,
      user_home: user_home
    }
  end

  defp write_operator_files!(pixir_home, user_home) do
    File.write!(
      Path.join(pixir_home, "config.json"),
      Jason.encode!(%{
        "model" => @operator_model,
        "compaction" => %{"native" => false}
      })
    )

    write_skill!(
      Path.join([user_home, ".agents", "skills", @operator_skill]),
      @operator_skill,
      "Operator user-scope skill that must not enter declared fixtures"
    )

    write_skill!(
      Path.join([pixir_home, "skills", @operator_global_skill]),
      @operator_global_skill,
      "Operator PIXIR_HOME skill that must not enter declared fixtures"
    )
  end

  defp write_skill!(dir, name, description) do
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "SKILL.md"), """
    ---
    name: #{name}
    description: #{description}
    ---

    # #{description}
    """)
  end

  defp tmp_root do
    path =
      Path.join(
        System.tmp_dir!(),
        "pixir-operator-state-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
