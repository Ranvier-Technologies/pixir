Code.require_file("support/test_run.ex", __DIR__)

# Unique per ExUnit invocation. Node browser harnesses inherit this env so
# profile prefixes and Elixir wildcard snapshots cannot see a concurrent suite.
PixirMonitor.TestRun.install!()

ExUnit.start()
