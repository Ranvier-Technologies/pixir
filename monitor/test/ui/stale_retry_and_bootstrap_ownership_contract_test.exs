defmodule PixirMonitor.UI.StaleRetryAndBootstrapOwnershipContractTest do
  use ExUnit.Case, async: true

  @app_path Path.expand("../../priv/static/app.js", __DIR__)

  setup_all do
    {:ok, app: File.read!(@app_path)}
  end

  test "SPA bootstrap net owns only continuation throws, never launch attribution", %{app: app} do
    assert app =~ "Pre-load failure UX belongs solely to the shell bootstrap (PixirMonitor.Bootstrap)"
    assert app =~ "this script loads only after the bootstrap promise fulfills"
    refute app =~ "Launch expired or already used. Relaunch required."

    [_, attachment] = String.split(app, "window.__pixirBootstrap.then(function () {", parts: 2)
    assert attachment =~ "refreshSingleFlight(\"initial load\");"
    assert attachment =~ "connect();"

    # The net after the continuation is scoped and honest: it names initialization,
    # not launch expiry, and documents that bootstrap rejection cannot reach it.
    assert attachment =~ "Only a synchronous throw in the continuation above can land here"

    assert attachment =~
             "Monitor initialization failed. Reload the page, or run pixir-monitor serve again for a fresh session."
  end

  test "runs stale disclosure exposes one keyed workspace-list retry; deep views stay copy-only", %{
    app: app
  } do
    [_, stale_tail] =
      String.split(
        app,
        "Held data is not current. Retry refetches only this authoritative source.",
        parts: 2
      )

    [stale_disclosure, _] = String.split(stale_tail, "node.prepend(disclosure);", parts: 2)

    assert stale_disclosure =~ "if (route.view === \"runs\")"
    assert stale_disclosure =~ "key(button(\"Retry this source\""

    assert stale_disclosure =~
             "refetchWorkspaceList(route.workspace, \"source retry\");"

    refute stale_disclosure =~ "refreshSingleFlight(\"source retry\")"
    assert stale_disclosure =~ "\"runs-source-retry:\" + route.workspace"

    # Exactly one retry append lives in the disclosure region, and it is the gated
    # one — a second, ungated append anywhere in the region would regress the
    # detail/unit copy-only guarantee.
    assert length(String.split(stale_disclosure, "key(button(\"Retry this source\"")) == 2

    # Deep views no longer promise a control they do not render: the provenance
    # copy splits by view, and the runs-only promise is the branch the button gates on.
    assert app =~ "Held data is not current. Return to the runs list to retry this source."
    assert app =~ "route.view === \"runs\" ? \"Held data is not current. Retry refetches only this authoritative source.\""
  end
end
