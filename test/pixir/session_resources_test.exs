defmodule Pixir.SessionResourcesTest do
  use ExUnit.Case, async: true

  alias Pixir.{Event, Log, Paths, SessionResources}

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
