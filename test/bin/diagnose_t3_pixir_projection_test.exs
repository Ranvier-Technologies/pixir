defmodule Pixir.BinDiagnoseT3PixirProjectionTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../bin/diagnose-t3-pixir-projection", __DIR__)

  test "classifies missing provider chunks as an ACP emission gap" do
    root = tmp_dir()
    thread_id = "464d3b3f-0e89-48dc-a002-ff9e400f9c13"
    session_id = "20260620T232856-3bd973"
    workspace = Path.join(root, "workspace")
    t3_userdata = Path.join(root, "t3")

    write_pixir_log(workspace, session_id, assistant?: true)
    write_provider_log(t3_userdata, thread_id, session_id, workspace, chunks: 0)
    write_projection_db(t3_userdata, thread_id, assistant_rows: 0)

    result = run_diag!(thread_id, t3_userdata)

    refute result["ok"]
    assert result["classification"] == "acp_emission_gap"
    assert result["layers"]["pixir_log"]["assistant_message_count"] == 1
    assert result["layers"]["t3_provider_log"]["agent_message_chunks"] == 0
    assert result["layers"]["t3_projection"]["assistant_row_count"] == 0
  end

  test "classifies matching Pixir, provider, and projection evidence as healthy" do
    root = tmp_dir()
    thread_id = "65908500-ba81-4e98-a619-ac6bc5fba171"
    session_id = "20260620T233109-3daa77"
    workspace = Path.join(root, "workspace")
    t3_userdata = Path.join(root, "t3")

    write_pixir_log(workspace, session_id, assistant?: true)
    write_provider_log(t3_userdata, thread_id, session_id, workspace, chunks: 1)
    write_projection_db(t3_userdata, thread_id, assistant_rows: 1)

    result = run_diag!(thread_id, t3_userdata)

    assert result["ok"]
    assert result["classification"] == "healthy_projection"
    assert result["layers"]["pixir_log"]["assistant_message_count"] == 1
    assert result["layers"]["t3_provider_log"]["agent_message_chunks"] > 0
    assert result["layers"]["t3_projection"]["assistant_row_count"] == 1
  end

  test "keeps malformed Pixir event types JSON serializable" do
    root = tmp_dir()
    thread_id = "55908500-ba81-4e98-a619-ac6bc5fba170"
    session_id = "20260620T233109-3daa70"
    workspace = Path.join(root, "workspace")
    t3_userdata = Path.join(root, "t3")
    session_dir = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(session_dir)

    File.write!(
      Path.join(session_dir, "#{session_id}.ndjson"),
      [
        Jason.encode!(%{"seq" => 0, "data" => %{"text" => "missing type"}}),
        Jason.encode!(%{"seq" => 1, "type" => "assistant_message", "data" => %{"text" => "ok"}})
      ]
      |> Enum.join("\n")
      |> Kernel.<>("\n")
    )

    write_provider_log(t3_userdata, thread_id, session_id, workspace, chunks: 1)
    write_projection_db(t3_userdata, thread_id, assistant_rows: 1, assistant_text: "ok")

    result = run_diag!(thread_id, t3_userdata)

    assert result["layers"]["pixir_log"]["counts_by_type"]["__missing_type__"] == 1
    assert result["layers"]["pixir_log"]["assistant_message_count"] == 1
  end

  test "can classify a visible-storage but invisible-UI report" do
    root = tmp_dir()
    thread_id = "75908500-ba81-4e98-a619-ac6bc5fba172"
    session_id = "20260620T233109-3daa78"
    workspace = Path.join(root, "workspace")
    t3_userdata = Path.join(root, "t3")

    write_pixir_log(workspace, session_id, assistant?: true)
    write_provider_log(t3_userdata, thread_id, session_id, workspace, chunks: 1)
    write_projection_db(t3_userdata, thread_id, assistant_rows: 1)

    result = run_diag!(thread_id, t3_userdata, ["--ui-visible", "no"])

    refute result["ok"]
    assert result["classification"] == "t3_ui_visibility_gap"
  end

  test "classifies a projected provider stream exit without canonical Pixir assistant" do
    root = tmp_dir()
    thread_id = "0a72d761-5383-4ae9-ac9d-c5dbb4937403"
    session_id = "20260621T021536-d30271"
    workspace = Path.join(root, "workspace")
    t3_userdata = Path.join(root, "t3")

    write_pixir_log(workspace, session_id, assistant?: false)
    write_provider_log(t3_userdata, thread_id, session_id, workspace, chunks: 1)

    write_projection_db(t3_userdata, thread_id,
      assistant_rows: 1,
      assistant_text: "Provider stream process exited."
    )

    result = run_diag!(thread_id, t3_userdata)

    refute result["ok"]

    assert result["classification"] ==
             "provider_stream_exit_projected_without_canonical_assistant"

    assert result["layers"]["pixir_log"]["assistant_message_count"] == 0

    assert [
             %{
               "text_prefix" => "Provider stream process exited.",
               "text_length" => 31
             }
           ] = result["layers"]["t3_projection"]["assistant_rows"]
  end

  test "prints help" do
    assert {out, 0} = run_script(["--help"])
    assert out =~ "Compare Pixir Session Log truth"
    assert out =~ "--thread-id"
    assert out =~ "--json"
  end

  defp run_diag!(thread_id, t3_userdata, extra_args \\ []) do
    args =
      [
        "--thread-id",
        thread_id,
        "--t3-userdata",
        t3_userdata,
        "--json"
      ] ++ extra_args

    assert {out, 0} = run_script(args)
    Jason.decode!(out)
  end

  defp run_script(args) do
    cond do
      uv = System.find_executable("uv") ->
        System.cmd(uv, ["run", "python", @script | args])

      python = System.find_executable("python3") ->
        System.cmd(python, [@script | args])

      python = System.find_executable("python") ->
        System.cmd(python, [@script | args])

      true ->
        flunk("no Python runner found; install uv or python3")
    end
  end

  defp write_pixir_log(workspace, session_id, assistant?: assistant?) do
    session_dir = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(session_dir)

    events =
      [
        %{"seq" => 0, "type" => "user_message", "data" => %{"text" => "hello"}},
        %{
          "seq" => 1,
          "type" => "tool_call",
          "data" => %{"call_id" => "call_1", "name" => "read", "args" => %{}}
        },
        %{
          "seq" => 2,
          "type" => "tool_result",
          "data" => %{"call_id" => "call_1", "ok" => true, "output" => "ok"}
        }
      ] ++
        if assistant? do
          [
            %{
              "seq" => 3,
              "type" => "assistant_message",
              "data" => %{"text" => "This is the final assistant response."}
            }
          ]
        else
          []
        end

    body = Enum.map_join(events, "\n", &Jason.encode!/1) <> "\n"
    File.write!(Path.join(session_dir, "#{session_id}.ndjson"), body)
  end

  defp write_provider_log(t3_userdata, thread_id, session_id, workspace, opts) do
    provider_dir = Path.join([t3_userdata, "logs", "provider"])
    File.mkdir_p!(provider_dir)

    chunk_count = Keyword.fetch!(opts, :chunks)

    chunk_lines =
      for _ <- List.duplicate(:chunk, chunk_count), into: "" do
        ~s([2026-06-20T00:00:01.000Z] NTIVE: {"payload":{"sessionUpdate":"agent_message_chunk","content":{"text":"hello"}}}\n)
      end

    body = """
    [2026-06-20T00:00:00.000Z] NTIVE: {"payload":{"sessionId":"#{session_id}","cwd":"#{workspace}"}}
    #{chunk_lines}[2026-06-20T00:00:02.000Z] CANON: {"type":"turn.completed","payload":{"stopReason":"end_turn"}}
    """

    File.write!(Path.join(provider_dir, "#{thread_id}.log"), body)
  end

  defp write_projection_db(t3_userdata, thread_id, opts) do
    File.mkdir_p!(t3_userdata)
    db = Path.join(t3_userdata, "state.sqlite")

    sql = """
    create table projection_thread_messages (
      message_id text,
      thread_id text,
      turn_id text,
      role text,
      text text,
      is_streaming integer,
      created_at text,
      updated_at text,
      attachments_json text
    );

    create table projection_turns (
      row_id integer,
      thread_id text,
      turn_id text,
      pending_message_id text,
      assistant_message_id text,
      state text,
      requested_at text,
      started_at text,
      completed_at text
    );

    insert into projection_thread_messages
      (message_id, thread_id, turn_id, role, text, is_streaming, created_at, updated_at, attachments_json)
    values
      ('user-1', '#{thread_id}', 'turn-1', 'user', 'hello', 0, '2026-06-20T00:00:00Z', '2026-06-20T00:00:00Z', '[]');

    insert into projection_turns
      (row_id, thread_id, turn_id, pending_message_id, assistant_message_id, state, requested_at, started_at, completed_at)
    values
      (1, '#{thread_id}', 'turn-1', 'user-1', 'assistant-1', 'completed', '2026-06-20T00:00:00Z', '2026-06-20T00:00:00Z', '2026-06-20T00:00:02Z');
    """

    assistant_count = Keyword.fetch!(opts, :assistant_rows)
    assistant_indexes = if assistant_count == 0, do: [], else: 1..assistant_count
    assistant_text = Keyword.get(opts, :assistant_text, "This is the final assistant response.")

    assistant_sql =
      for index <- assistant_indexes, into: "" do
        """
        insert into projection_thread_messages
          (message_id, thread_id, turn_id, role, text, is_streaming, created_at, updated_at, attachments_json)
        values
          ('assistant-#{index}', '#{thread_id}', 'turn-1', 'assistant', '#{assistant_text}', 0, '2026-06-20T00:00:01Z', '2026-06-20T00:00:01Z', '[]');
        """
      end

    sql_path = Path.join(t3_userdata, "schema.sql")
    File.write!(sql_path, sql <> assistant_sql)

    assert {"", 0} = System.cmd("sqlite3", [db, ".read #{sql_path}"])
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "pixir-t3-projection-test-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
