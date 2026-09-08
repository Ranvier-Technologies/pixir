defmodule Pixir.Test.HomeIsolation do
  @moduledoc false

  def install! do
    previous_home = System.get_env("PIXIR_HOME")

    home =
      Path.join(
        System.tmp_dir!(),
        "pixir-test-home-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      )

    File.mkdir_p!(home)
    System.put_env("PIXIR_HOME", home)

    ExUnit.after_suite(fn _result ->
      restore_home(previous_home)
      File.rm_rf!(home)
    end)

    :ok
  end

  defp restore_home(nil), do: System.delete_env("PIXIR_HOME")
  defp restore_home(home), do: System.put_env("PIXIR_HOME", home)
end
