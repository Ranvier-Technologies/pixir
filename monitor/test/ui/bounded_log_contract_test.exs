defmodule PixirMonitor.UI.BoundedLogContractTest do
  use ExUnit.Case, async: true

  test "served app renders bounded parent and partial child evidence notes through existing limitation surfaces" do
    {output, status} = System.cmd("node", ["test/support/bounded_log_harness.mjs", "priv/static/app.js"], stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "bounded log UI contract passed"
  end
end
