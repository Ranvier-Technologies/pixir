defmodule Pixir.SessionResourcesTest do
  use ExUnit.Case, async: true

  alias Pixir.{Event, Log, Paths, SessionResources, Tool}

  setup do
    ws =
      Path.join(
        System.tmp_dir!(),
        "pixir-resources-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf!(ws) end)
    %{ws: ws, sid: "session-a"}
  end

  test "ingests an image attachment as a local descriptor without returning base64", %{
    ws: ws,
    sid: sid
  } do
    bytes = "not really a png, but exact bytes"
    encoded = Base.encode64(bytes)

    assert {:ok, [descriptor]} =
             SessionResources.ingest_attachments(
               sid,
               [
                 %{
                   "type" => "image",
                   "name" => "screen.png",
                   "mimeType" => "image/png",
                   "sizeBytes" => byte_size(bytes),
                   "dataUrl" => "data:image/png;base64,#{encoded}"
                 }
               ],
               workspace: ws
             )

    assert descriptor["kind"] == "image"
    assert descriptor["name"] == "screen.png"
    assert descriptor["mime_type"] == "image/png"
    assert descriptor["size_bytes"] == byte_size(bytes)

    assert descriptor["content_sha256"] ==
             Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    refute inspect(descriptor) =~ encoded

    assert {:ok, data_url} = SessionResources.data_url(sid, descriptor, workspace: ws)
    assert data_url == "data:image/png;base64,#{encoded}"
  end

  test "Log stores descriptors, not raw image payloads", %{ws: ws, sid: sid} do
    bytes = "payload bytes"
    encoded = Base.encode64(bytes)

    {:ok, [descriptor]} =
      SessionResources.ingest_attachments(
        sid,
        [
          %{
            "type" => "image",
            "name" => "screen.png",
            "mimeType" => "image/png",
            "dataUrl" => "data:image/png;base64,#{encoded}"
          }
        ],
        workspace: ws
      )

    event = Event.user_message(sid, "inspect this", resources: [descriptor]) |> Event.with_seq(0)
    assert {:ok, _} = Log.append(event, workspace: ws)

    log = File.read!(Paths.session_log(sid, ws))
    assert log =~ descriptor["resource_id"]
    assert log =~ descriptor["content_sha256"]
    refute log =~ encoded
  end

  test "missing resource payload is a structured resource_missing error", %{ws: ws, sid: sid} do
    {:ok, [descriptor]} =
      SessionResources.ingest_attachments(
        sid,
        [
          %{
            "type" => "image",
            "name" => "screen.png",
            "mimeType" => "image/png",
            "dataUrl" => "data:image/png;base64,#{Base.encode64("bytes")}"
          }
        ],
        workspace: ws
      )

    {:ok, path} = SessionResources.resource_path(sid, descriptor, ws)
    File.rm!(path)

    assert {:error, %{error: %{kind: :resource_missing, details: %{resource_id: id}}}} =
             SessionResources.data_url(sid, descriptor, workspace: ws)

    assert id == descriptor["resource_id"]
  end

  test "ingests a local ACP resource_link image from outside the workspace", %{
    ws: ws,
    sid: sid
  } do
    source_dir = tmp_source_dir("image")
    source_path = Path.join(source_dir, "outside.png")
    bytes = "outside image bytes"
    File.write!(source_path, bytes)

    assert {:ok, [descriptor]} =
             SessionResources.ingest_attachments(
               sid,
               [
                 %{
                   "type" => "resource_link",
                   "uri" => "file://#{source_path}",
                   "name" => "outside.png",
                   "mimeType" => " IMAGE/PNG ",
                   "size" => byte_size(bytes)
                 }
               ],
               workspace: ws
             )

    assert descriptor["kind"] == "image"
    assert descriptor["name"] == "outside.png"
    assert descriptor["mime_type"] == "image/png"
    assert descriptor["source"] == "resource_link"
    assert descriptor["source_uri_scheme"] == "file"
    refute inspect(descriptor) =~ source_path

    assert {:ok, data_url} = SessionResources.data_url(sid, descriptor, workspace: ws)
    assert data_url == "data:image/png;base64,#{Base.encode64(bytes)}"
  end

  test "rejects payload-bearing resource_link URIs without logging descriptor payloads", %{
    ws: ws,
    sid: sid
  } do
    payload = Base.encode64("inline payload bytes")
    uri = "DATA:image/png;base64,#{payload}"

    assert {:error, %{error: %{kind: :invalid_args, message: message, details: details}}} =
             SessionResources.ingest_attachments(
               sid,
               [
                 %{
                   "type" => "resource_link",
                   "uri" => uri,
                   "name" => "inline.png",
                   "mimeType" => "image/png"
                 }
               ],
               workspace: ws
             )

    assert details.uri_scheme == "data"
    assert is_binary(message)
    refute inspect(details) =~ payload
  end

  test "ingests a local ACP resource_link file as a descriptor without provider image projection",
       %{
         ws: ws,
         sid: sid
       } do
    source_dir = tmp_source_dir("file")
    source_path = Path.join(source_dir, "notes.txt")
    File.write!(source_path, "hello from a file")

    assert {:ok, [descriptor]} =
             SessionResources.ingest_attachments(
               sid,
               [
                 %{
                   "type" => "resource_link",
                   "uri" => "file://#{source_path}",
                   "name" => "notes.txt",
                   "mimeType" => "text/plain"
                 }
               ],
               workspace: ws
             )

    assert descriptor["kind"] == "file"
    assert descriptor["content_sha256"]
    assert SessionResources.render_descriptor(descriptor) =~ "File resource"

    assert {:error, %{error: %{kind: :invalid_args, details: %{kind: "file"}}}} =
             SessionResources.data_url(sid, descriptor, workspace: ws)
  end

  test "records remote ACP resource_link as a non-rehydratable descriptor", %{
    ws: ws,
    sid: sid
  } do
    uri = "https://fixture-userinfo@example.com/context/report.pdf?download=true#fragment"

    assert {:ok, [descriptor]} =
             SessionResources.ingest_attachments(
               sid,
               [
                 %{
                   "type" => "resource_link",
                   "uri" => uri,
                   "name" => "report.pdf",
                   "mimeType" => "application/pdf"
                 }
               ],
               workspace: ws
             )

    assert descriptor["kind"] == "resource_link"
    assert descriptor["uri"] == "https://example.com/context/report.pdf"
    assert descriptor["rehydratable"] == false
    refute Map.has_key?(descriptor, "content_sha256")
    rendered = SessionResources.render_descriptor(descriptor)
    assert rendered =~ "did not copy local bytes"
    refute rendered =~ "secret"
    refute rendered =~ "fragment"
  end

  test "local_attachment_link resolves paths, encodes reserved characters, and keeps names" do
    assert {:ok, link} = SessionResources.local_attachment_link("report#final.pdf", "/ws")
    assert link["uri"] == "file:///ws/report%23final.pdf"
    assert link["name"] == "report#final.pdf"

    assert {:ok, abs} = SessionResources.local_attachment_link("/abs/n o t e.txt", "/ws")
    assert abs["uri"] == "file:///abs/n%20o%20t%20e.txt"
  end

  test "local_attachment_link rejects the URI edge cases honestly" do
    assert {:error, :empty_path} = SessionResources.local_attachment_link("  ", "/ws")

    assert {:error, :remote_uri} =
             SessionResources.local_attachment_link("file://evil.host/x", "/ws")

    # A raw # or ? in an unencoded file URI silently truncates the path at
    # parse time, so it rejects instead of ingesting the wrong file.
    assert {:error, :uri_query_or_fragment} =
             SessionResources.local_attachment_link("file:///ws/report#final.pdf", "/ws")

    assert {:error, :uri_query_or_fragment} =
             SessionResources.local_attachment_link("file:///ws/report?v=2", "/ws")

    # file: without // must not expand as a relative path.
    assert {:error, :invalid_path} =
             SessionResources.local_attachment_link("file:/tmp/notes.txt", "/ws")
  end

  test "local_attachment_link treats an uppercase scheme as a URI, normalized" do
    assert {:ok, link} = SessionResources.local_attachment_link("FILE:///tmp/notes.txt", "/ws")
    assert link["uri"] == "file:///tmp/notes.txt"
    assert link["name"] == "notes.txt"
  end

  test "with_copied_resources stages cross-workspace bytes without rewriting descriptors", %{
    ws: ws,
    sid: sid
  } do
    child_workspace = Path.join(ws, "isolated-child")
    File.mkdir_p!(child_workspace)
    child = "child-cross-workspace"
    bytes = "cross-workspace payload bytes"

    assert {:ok, [descriptor]} =
             SessionResources.ingest_attachments(
               sid,
               [
                 %{
                   "type" => "image",
                   "name" => "cross.png",
                   "mimeType" => "image/png",
                   "dataUrl" => "data:image/png;base64,#{Base.encode64(bytes)}"
                 }
               ],
               workspace: ws
             )

    event = Event.user_message(child, "replayed", resources: [descriptor])

    assert {:ok, :committed} =
             SessionResources.with_copied_resources(
               sid,
               child,
               [event],
               [parent_workspace: ws, child_workspace: child_workspace],
               fn ->
                 assert File.dir?(Paths.session_resources_dir(child, child_workspace))

                 assert Path.wildcard(
                          Paths.session_resources_dir(child, child_workspace) <> ".staging*"
                        ) == []

                 case Log.create_session(child, [event], workspace: child_workspace) do
                   {:ok, _written} -> {:ok, :committed}
                   {:error, _error} = error -> error
                 end
               end
             )

    assert {:ok, child_history} = Log.fold(child, workspace: child_workspace)
    persisted_event = Enum.find(child_history, &(&1.data["text"] == "replayed"))
    [persisted_descriptor] = persisted_event.data["resources"]

    assert persisted_descriptor["resource_id"] == descriptor["resource_id"]
    assert persisted_descriptor["content_sha256"] == descriptor["content_sha256"]
    assert persisted_descriptor["store_ref"] =~ "session://#{sid}/resources/"

    assert {:ok, data_url} =
             SessionResources.data_url(child, persisted_descriptor, workspace: child_workspace)

    assert data_url == "data:image/png;base64,#{Base.encode64(bytes)}"
  end

  test "with_copied_resources preserves existing final resources and normalizes empty success", %{
    ws: ws,
    sid: sid
  } do
    child = "child-existing-resources"
    final = Paths.session_resources_dir(child, ws)
    kept = Path.join(final, "kept/payload.bin")
    File.mkdir_p!(Path.dirname(kept))
    File.write!(kept, "durable child payload")

    assert {:ok, :ok} =
             SessionResources.with_copied_resources(
               sid,
               child,
               [],
               [parent_workspace: ws, child_workspace: ws],
               fn -> :ok end
             )

    assert File.read!(kept) == "durable child payload"

    assert {:ok, [descriptor]} =
             SessionResources.ingest_attachments(
               sid,
               [
                 %{
                   "type" => "image",
                   "name" => "collision.png",
                   "mimeType" => "image/png",
                   "dataUrl" => "data:image/png;base64,#{Base.encode64("new payload")}"
                 }
               ],
               workspace: ws
             )

    event = Event.user_message(child, "collision", resources: [descriptor])

    assert {:error, %{error: %{kind: :already_exists, details: collision_details}}} =
             SessionResources.with_copied_resources(
               sid,
               child,
               [event],
               [parent_workspace: ws, child_workspace: ws],
               fn ->
                 flunk("operation must not run across an existing final resource directory")
               end
             )

    assert collision_details.next_actions == [
             "inspect_or_remove_the_existing_child_resource_directory",
             "retry_with_a_new_child_session_id"
           ]

    assert File.read!(kept) == "durable child payload"
    assert Path.wildcard(final <> ".staging*") == []
  end

  test "stored descriptors win deduplication over earlier link-only evidence", %{ws: ws, sid: sid} do
    child = "child-stored-descriptor-order"
    bytes = "stored descriptor wins"

    assert {:ok, [stored]} =
             SessionResources.ingest_attachments(
               sid,
               [
                 %{
                   "type" => "image",
                   "name" => "ordered.png",
                   "mimeType" => "image/png",
                   "dataUrl" => "data:image/png;base64,#{Base.encode64(bytes)}"
                 }
               ],
               workspace: ws
             )

    link_only =
      stored
      |> Map.drop(["content_sha256", "extension", "store_ref"])
      |> Map.put("kind", "resource_link")
      |> Map.put("rehydratable", false)

    events = [
      Event.user_message(child, "link first", resources: [link_only]),
      Event.user_message(child, "stored second", resources: [stored])
    ]

    assert {:ok, :copied} =
             SessionResources.with_copied_resources(
               sid,
               child,
               events,
               [parent_workspace: ws, child_workspace: ws],
               fn -> {:ok, :copied} end
             )

    assert {:ok, data_url} = SessionResources.data_url(child, stored, workspace: ws)
    assert data_url == "data:image/png;base64,#{Base.encode64(bytes)}"
  end

  test "with_copied_resources bounds invalid arguments and callback results", %{ws: ws, sid: sid} do
    assert {:error, %{error: %{kind: :invalid_args}}} =
             SessionResources.with_copied_resources(
               sid,
               "invalid-args-child",
               [],
               :not_options,
               fn ->
                 :ok
               end
             )

    assert {:error, %{error: %{kind: :invalid_args}}} =
             SessionResources.with_copied_resources(
               sid,
               "non-keyword-options-child",
               [],
               [1, 2],
               fn -> :ok end
             )

    for invalid_workspace_opts <- [[parent_workspace: :invalid], [child_workspace: nil]] do
      assert {:error, %{error: %{kind: :invalid_args}}} =
               SessionResources.with_copied_resources(
                 sid,
                 "invalid-workspace-child",
                 [],
                 invalid_workspace_opts,
                 fn -> :ok end
               )
    end

    child = "child-invalid-operation-result"
    sentinel = "INVALID_OPERATION_RESULT_SECRET"

    assert {:ok, [descriptor]} =
             SessionResources.ingest_attachments(
               sid,
               [
                 %{
                   "type" => "image",
                   "name" => "invalid-result.png",
                   "mimeType" => "image/png",
                   "dataUrl" => "data:image/png;base64,#{Base.encode64("payload")}"
                 }
               ],
               workspace: ws
             )

    event = Event.user_message(child, "invalid result", resources: [descriptor])

    assert {:error, %{error: %{kind: :write_failed, details: details}} = error} =
             SessionResources.with_copied_resources(
               sid,
               child,
               [event],
               [parent_workspace: ws, child_workspace: ws],
               fn -> {:error, String.duplicate(sentinel, 100)} end
             )

    assert details.observed_type == "tuple"
    refute inspect(error) =~ sentinel

    final = Paths.session_resources_dir(child, ws)
    refute File.exists?(final)
    assert Path.wildcard(final <> ".staging*") == []
  end

  test "with_copied_resources compensates deterministic partial copies in both workspace modes",
       %{ws: ws, sid: sid} do
    assert {:ok, descriptors} =
             SessionResources.ingest_attachments(
               sid,
               Enum.map(["first", "second"], fn bytes ->
                 %{
                   "type" => "image",
                   "name" => "#{bytes}.png",
                   "mimeType" => "image/png",
                   "dataUrl" => "data:image/png;base64,#{Base.encode64(bytes)}"
                 }
               end),
               workspace: ws
             )

    sentinel = "COPY_FAILPOINT_SECRET"

    fail_second_copy = fn
      %{index: 0} ->
        :ok

      %{index: 1} ->
        {:error,
         Tool.error(:write_failed, String.duplicate(sentinel, 100), %{
           hostile: String.duplicate(sentinel, 100)
         })}
    end

    for {child, child_workspace} <- [
          {"child-shared-copy-failure", ws},
          {"child-cross-copy-failure", Path.join(ws, "isolated-copy-failure")}
        ] do
      File.mkdir_p!(child_workspace)
      events = [Event.user_message(child, "replayed", resources: descriptors)]

      assert {:error, %{error: %{kind: :write_failed}} = error} =
               SessionResources.with_copied_resources(
                 sid,
                 child,
                 events,
                 [
                   parent_workspace: ws,
                   child_workspace: child_workspace,
                   resource_copy_failpoint: fail_second_copy
                 ],
                 fn -> flunk("operation must not run after a copy failure") end
               )

      refute inspect(error) =~ sentinel

      final = Paths.session_resources_dir(child, child_workspace)
      refute File.exists?(final)
      assert Path.wildcard(final <> ".staging*") == []
    end
  end

  defp tmp_source_dir(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "pixir-resource-source-#{label}-" <>
          Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(path)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
