defmodule Pixir.Tools.AtomicWrite do
  @moduledoc false

  @doc false
  @spec write(Path.t(), iodata()) :: {:ok, nil} | {:error, term()}
  def write(path, content) do
    with {:ok, mode} <- replacement_mode(path) do
      temporary =
        Path.join(
          Path.dirname(path),
          ".pixir-tmp-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
        )

      # Exclusive creation never follows or truncates an existing file or symlink.
      # Only an invocation that successfully opened this name owns its cleanup.
      case File.open(temporary, [:write, :binary, :exclusive]) do
        {:ok, device} ->
          try do
            with :ok <- apply_mode(temporary, mode),
                 :ok <- :file.write(device, content),
                 :ok <- File.close(device),
                 :ok <- File.rename(temporary, path) do
              {:ok, nil}
            end
          after
            _ = File.close(device)
            _ = File.rm(temporary)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp replacement_mode(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular, mode: mode}} -> {:ok, Bitwise.band(mode, 0o777)}
      {:ok, _} -> {:ok, nil}
      {:error, :enoent} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  # New files retain the creation mode selected by the filesystem and umask.
  # Existing regular files retain only ordinary rwx bits, never setuid/setgid.
  defp apply_mode(_temporary, nil), do: :ok
  defp apply_mode(temporary, mode), do: File.chmod(temporary, mode)
end
