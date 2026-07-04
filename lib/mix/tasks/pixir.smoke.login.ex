defmodule Mix.Tasks.Pixir.Smoke.Login do
  @shortdoc "Smoke-test the Codex device-code OAuth flow against auth.openai.com"

  @moduledoc """
  Exercises the *real* first leg of `pixir login` (ADR 0002): it POSTs to
  `auth.openai.com` and prints the device code the server returns. This verifies the
  part that unit tests can't — that our `client_id`, endpoint, and request shape are
  accepted by the live server.

      mix pixir.smoke.login          # start device auth, print the code, stop
      mix pixir.smoke.login --wait   # also poll + complete (needs a human to approve)

  Without `--wait` it stops after obtaining the code (no human step needed), which is
  the CI-friendly smoke check. With `--wait` it runs the whole flow and installs the
  credential, just like `pixir login`.

  For a full guided walkthrough that also runs one real Turn against the model (login
  → streamed tool-using Turn → summary), see `mix pixir.smoke.e2e`.

  Exit code is non-zero on failure (e.g. network error or a rejected request shape),
  so it can gate a release check.
  """

  use Mix.Task

  alias Pixir.Auth
  alias Pixir.Auth.CodexOAuth

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, switches: [wait: :boolean])
    Mix.Task.run("app.start")

    Mix.shell().info("→ requesting a device code from auth.openai.com …")

    case CodexOAuth.start_device_auth() do
      {:ok, device} ->
        report_device(device)
        if opts[:wait], do: complete(device), else: smoke_ok()

      {:error, error} ->
        fail("device authorization request failed", error)
    end
  end

  defp report_device(device) do
    Mix.shell().info("""

    ✓ Got a device code from the live server:
        user code:        #{device.user_code}
        verification URI: #{device.verification_uri}
        poll interval:    #{device.interval}s
        expires in:       #{div(device.expires_in, 60)} min
    """)
  end

  defp smoke_ok do
    Mix.shell().info("""
    Smoke check passed: the endpoint, client_id, and request shape are accepted.
    (Stopped before polling — pass --wait to complete the human approval step.)
    """)
  end

  defp complete(device) do
    Mix.shell().info("Open the URI above, enter the code, then waiting for approval …\n")

    with {:ok, %{authorization_code: code, code_verifier: verifier}} <-
           CodexOAuth.poll_for_authorization(device),
         {:ok, credential} <- CodexOAuth.exchange_for_credential(code, verifier),
         :ok <- Auth.set_credential(credential) do
      Mix.shell().info(
        "✓ Signed in (subscription). Credential saved to #{Pixir.Paths.auth_file()}."
      )
    else
      {:error, error} -> fail("login did not complete", error)
    end
  end

  defp fail(context, %{error: %{kind: kind, message: message, details: details}}) do
    Mix.shell().error("✗ #{context}: #{kind} — #{message}")
    unless details == %{}, do: Mix.shell().error("  details: #{inspect(details)}")
    exit({:shutdown, 1})
  end

  defp fail(context, other) do
    Mix.shell().error("✗ #{context}: #{inspect(other)}")
    exit({:shutdown, 1})
  end
end
