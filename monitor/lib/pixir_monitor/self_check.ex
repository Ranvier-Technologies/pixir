defmodule PixirMonitor.SelfCheck do
  @moduledoc """
  Exercises the built monitor over its real loopback Bandit listener.

  The check performs bootstrap internally, keeps capability and session bytes out of
  output, then verifies embedded assets and the versioned authoritative Runs envelope.
  """

  @timeout 5_000

  @spec run() :: {:ok, map()} | {:error, map()}
  def run do
    with {:ok, _apps} <- Application.ensure_all_started(:pixir_monitor),
         {:ok, port} <- PixirMonitor.PortRegistry.wait(@timeout),
         {:ok, launch} <- PixirMonitor.Vault.issue_launch(),
         {:ok, cookie} <- bootstrap(port, launch),
         :ok <- verify_consumed(port, launch),
         :ok <- verify_asset(port, cookie, "app.js"),
         :ok <- verify_asset(port, cookie, "app.css"),
         :ok <- verify_runs(port, cookie) do
      {:ok,
       %{
         ok: true,
         check: "pixir_monitor_loopback",
         listener: "127.0.0.1",
         bootstrap: "one_use_accepted",
         assets: ["app.js", "app.css"],
         runs_schema: "pixir.monitor.runs",
         runs_schema_version: 1
       }}
    end
  rescue
    # Operator-local surface, but the same boundary doctrine keeps environment
    # detail out of diagnostics. Report a fixed atom instead of Exception.message/1.
    _error -> failure("self_check_exception", "Self-check raised unexpectedly", %{exception: :self_check_raised})
  catch
    kind, reason -> failure("self_check_exit", "Self-check terminated unexpectedly", %{kind: inspect(kind), reason: bounded(reason)})
  end

  defp bootstrap(port, launch) do
    headers = [
      {~c"origin", String.to_charlist(origin(port))},
      {~c"sec-fetch-site", ~c"same-origin"}
    ]

    request = {url(port, "/bootstrap"), headers, ~c"application/json", Jason.encode!(%{launch: launch})}

    case :httpc.request(:post, request, [timeout: @timeout], body_format: :binary) do
      {:ok, {{_, 200, _}, response_headers, _body}} -> cookie(response_headers)
      {:ok, {{_, status, _}, _headers, _body}} -> failure("bootstrap_failed", "Loopback bootstrap returned an unexpected status", %{status: status})
      {:error, reason} -> failure("bootstrap_request_failed", "Loopback bootstrap request failed", %{reason: bounded(reason)})
    end
  end

  defp verify_consumed(port, launch) do
    headers = [
      {~c"origin", String.to_charlist(origin(port))},
      {~c"sec-fetch-site", ~c"same-origin"}
    ]

    request = {url(port, "/bootstrap"), headers, ~c"application/json", Jason.encode!(%{launch: launch})}

    case :httpc.request(:post, request, [timeout: @timeout], body_format: :binary) do
      {:ok, {{_, 401, _}, _headers, _body}} -> :ok
      {:ok, {{_, status, _}, _headers, _body}} -> failure("bootstrap_reuse_accepted", "One-use bootstrap was not rejected as expected", %{status: status})
      {:error, reason} -> failure("bootstrap_reuse_request_failed", "Bootstrap reuse check failed", %{reason: bounded(reason)})
    end
  end

  defp cookie(headers) do
    case Enum.find_value(headers, fn
           {name, value} -> if String.downcase(to_string(name)) == "set-cookie", do: value
           _ -> nil
         end) do
      nil -> failure("bootstrap_cookie_missing", "Bootstrap did not issue a browser session", %{})
      value -> {:ok, value |> to_string() |> String.split(";", parts: 2) |> hd()}
    end
  end

  defp verify_asset(port, cookie, name) do
    with {:ok, _content_type, expected} <- PixirMonitor.Assets.fetch(name),
         {:ok, actual} <- get(port, cookie, "/assets/#{name}", "asset_#{name}"),
         true <- actual == expected do
      :ok
    else
      false -> failure("asset_mismatch", "Served asset bytes differ from embedded bytes", %{asset: name})
      {:error, _} = error -> error
    end
  end

  defp verify_runs(port, cookie) do
    with {:ok, bytes} <- get(port, cookie, "/api/runs", "runs"),
         {:ok, value} <- Jason.decode(bytes),
         true <- value["schema"] == "pixir.monitor.runs",
         true <- value["schema_version"] == 1,
         true <- is_list(value["runs"]),
         true <- is_map(value["inventory"]) do
      :ok
    else
      false -> failure("runs_contract_mismatch", "Runs response does not match the versioned envelope", %{})
      {:error, %Jason.DecodeError{}} -> failure("runs_json_invalid", "Runs response is not valid JSON", %{})
      {:error, _} = error -> error
    end
  end

  defp get(port, cookie, path, stage) do
    headers = [{~c"sec-fetch-site", ~c"same-origin"}, {~c"cookie", String.to_charlist(cookie)}]

    case :httpc.request(:get, {url(port, path), headers}, [timeout: @timeout], body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, body}} -> {:ok, body}
      {:ok, {{_, status, _}, _headers, _body}} -> failure("#{stage}_failed", "Loopback GET returned an unexpected status", %{status: status})
      {:error, reason} -> failure("#{stage}_request_failed", "Loopback GET failed", %{reason: bounded(reason)})
    end
  end

  defp origin(port), do: "http://127.0.0.1:#{port}"
  defp url(port, path), do: String.to_charlist(origin(port) <> path)
  defp bounded(reason), do: inspect(reason, limit: 10, printable_limit: 200)
  defp failure(kind, message, details), do: {:error, %{kind: kind, message: message, details: details, next_actions: ["Inspect local monitor diagnostics and retry"]}}
end
