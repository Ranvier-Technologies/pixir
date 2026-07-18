defmodule PixirMonitor.ProjectionFailureContractTest do
  @moduledoc """
  Pins honest client failure phases alongside the real-browser escript regression.
  """

  use ExUnit.Case, async: true

  @app_js File.read!(Path.expand("../../priv/static/app.js", __DIR__))

  test "fetch, decode, and render failures remain distinguishable and bounded" do
    assert @app_js =~ "function projectionFailure(phase, kind, status)"
    assert @app_js =~ ~s|projectionFailure("fetch", "projection_request_failed")|
    assert @app_js =~ ~s|projectionFailure("fetch", serverKind, response.status)|
    assert @app_js =~ ~s|projectionFailure("decode", "projection_response_invalid", response.status)|
    assert @app_js =~ ~s|projectionFailure("render", "projection_render_failed")|
    assert @app_js =~ "function projectionFailureMessage(failure)"
    assert @app_js =~ "function projectionFailureStatus(failure)"
    assert @app_js =~ "function applyFailureDiagnostic(root, failure)"
  end

  test "user copy names the failed phase instead of blaming every failure on refetch" do
    assert @app_js =~ "The authoritative projection could not be fetched."
    assert @app_js =~ "The projection response could not be decoded."
    assert @app_js =~ "The fetched projection could not be displayed."
    assert @app_js =~ "Snapshot loaded but could not be displayed."
    refute @app_js =~ "The authoritative projection could not be refetched."
  end

  test "diagnostic attributes accept only bounded server-owned tokens" do
    assert @app_js =~ "function diagnosticToken(value, fallback)"
    assert @app_js =~ "/^[a-z0-9_]{1,64}$/"
    assert @app_js =~ "root.dataset.errorPhase = failure.phase"
    assert @app_js =~ "root.dataset.errorKind = failure.kind"
  end

  test "refresh and direct route renders share the same classified failure path" do
    assert @app_js =~ "function renderProjectionFailure(error)"
    assert @app_js =~ "function renderCurrentGuarded()"
    assert @app_js =~ "function renderProjectionFailureSafely(error)"
    assert @app_js =~ "catch (error) { renderProjectionFailureSafely(error); }"
    assert @app_js =~ "refresh(currentReason).catch(renderProjectionFailureSafely)"
    assert @app_js =~ ~s|app.dataset.errorKind = "projection_failure_renderer_failed";|
    assert @app_js =~ ~s|app.dataset.errorPhase = primaryFailure.phase;|
    assert @app_js =~ ~s|app.textContent = "Projection unavailable. " + projectionFailureMessage(primaryFailure);|
    assert @app_js =~ "status.textContent = projectionFailureStatus(primaryFailure);"
    assert @app_js =~ "Requested projection unavailable; return to Runs or relaunch."
    assert @app_js =~ ~s|else if (route.view === "runs") {|
    assert @app_js =~ "state.detail = null; state.detailId = null; state.detailConflict = false;"
    assert @app_js =~ "const nextRouteRunId = route.runId || null;"
    assert @app_js =~ "const runChanged = state.routeRunId !== nextRouteRunId || state.routeWorkspace !== nextRouteWorkspace;"
    assert @app_js =~ "if (runChanged) {"

    assert @app_js =~
             "const matchingDetail = route.runId && state.detail && state.detailId === route.runId && (!workspaceSetMode() || state.detailWorkspace === route.workspace) && state.detail.run && state.detail.run.id === route.runId;"

    assert @app_js =~
             "const staleRoute = route.runId && (state.detailId && route.runId !== state.detailId || workspaceSetMode() && state.detailWorkspace && route.workspace !== state.detailWorkspace);"

    assert @app_js =~ "const staleDetail = staleRoute || (route.runId && state.detail && !matchingDetail);"
    assert @app_js =~ "const staleFollowView = route.runId && app.querySelector(\".error-view[data-follow-state]\") && (!matchingDetail || runChanged);"
    assert @app_js =~ "const preserveSameRunFollowIdentity = route.follow === true && !runChanged && !state.detail && state.detailId === route.runId;"
    assert @app_js =~ "else if (failure.phase === \"render\") {"
    assert @app_js =~ "else if (matchingDetail) renderCurrentGuarded();"
  end
end
