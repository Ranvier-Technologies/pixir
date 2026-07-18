defmodule Pixir.SessionResources do
  @moduledoc """
  Durable local Session Resources (ADR 0021).

  Pixir treats attachments and ACP resource links as local resources owned by
  the Session, not as Presenter blobs and not as ambient model context. When the
  original bytes are available, they stay on disk under
  `.pixir/sessions/<session_id>/resources/`; the Log records only a descriptor
  with a Session-local `resource_id` and, for stored payloads, a byte identity
  `content_sha256`.

  Provider-specific shapes such as Responses `input_image` are projections across
  the Leakage Boundary. They are assembled from descriptors only when Pixir
  intentionally sends a resource to OpenAI.

  Resource path boundaries validate the Session id. Static symlink and same-UID race
  hardening for payload paths under `.pixir/sessions/<session_id>/resources/` is
  deliberately deferred; the Resource store is not an adversarial filesystem sandbox.
  """

  alias Pixir.{Paths, SessionId, Tool}

  @image_mime_prefix "image/"
  @default_mime_type "application/octet-stream"
  @default_detail "auto"
  @max_descriptor_text 1_200

  @type descriptor :: map()

  @doc """
  The single source of the local `file://` acceptance rule: empty/localhost
  host and a real path, nothing remote. Delegate and Workflow attachment
  surfaces share it so their mirrors cannot drift.
  """
  @spec local_file_uri?(String.t()) :: boolean()
  def local_file_uri?(uri) when is_binary(uri) do
    match?(
      %URI{host: host, path: path} when host in [nil, "", "localhost"] and is_binary(path),
      URI.parse(uri)
    )
  end

  @doc """
  Normalize an operator-supplied local attachment (filesystem path or
  `file://` URI) into the `resource_link` map `ingest_attachments/3` accepts.
  Relative paths resolve against `workspace`; remote URIs are rejected.
  Existence is checked at ingestion, not here.
  """
  @spec local_attachment_link(String.t(), Path.t()) ::
          {:ok, map()}
          | {:error, :empty_path | :remote_uri | :uri_query_or_fragment | :invalid_path}
  def local_attachment_link(path_or_uri, workspace) when is_binary(path_or_uri) do
    trimmed = String.trim(path_or_uri)

    cond do
      trimmed == "" ->
        {:error, :empty_path}

      file_uri?(trimmed) ->
        # Scheme case normalizes to the literal prefix ingestion matches on;
        # "FILE:///x" is a URI to validate, never a relative path to re-encode.
        local_file_uri_link("file://" <> String.slice(trimmed, 7..-1//1))

      String.starts_with?(String.downcase(trimmed), "file:") ->
        # file: without // (e.g. "file:/tmp/x") would otherwise expand as a
        # relative path into garbage the dry-run accepts and the run cannot read.
        {:error, :invalid_path}

      true ->
        # Percent-encoded so ingestion's URI.decode round-trips reserved characters.
        encoded =
          trimmed
          |> Path.expand(workspace)
          |> URI.encode(&(&1 == ?/ or URI.char_unreserved?(&1)))

        {:ok, resource_link("file://" <> encoded, Path.basename(trimmed))}
    end
  end

  def local_attachment_link(_path_or_uri, _workspace), do: {:error, :invalid_path}

  defp file_uri?(value), do: value |> String.downcase() |> String.starts_with?("file://")

  defp local_file_uri_link(uri) do
    parsed = URI.parse(uri)

    cond do
      not local_file_uri?(uri) ->
        {:error, :remote_uri}

      parsed.query != nil or parsed.fragment != nil ->
        # A raw `#`/`?` in an unencoded file URI silently truncates the path at
        # parse time; rejecting is honest, percent-encode them in the source.
        {:error, :uri_query_or_fragment}

      true ->
        {:ok, resource_link(uri, decode_link_basename(Path.basename(parsed.path)))}
    end
  end

  defp resource_link(uri, name) do
    link = %{"type" => "resource_link", "uri" => uri}
    if is_binary(name) and name != "", do: Map.put(link, "name", name), else: link
  end

  defp decode_link_basename(name) do
    URI.decode(name)
  rescue
    ArgumentError -> name
  end

  @doc """
  Ingest supported attachment maps into the Session Resource store.

  Callers may pass T3-style image attachment maps (`type`, `name`, `mimeType`,
  `sizeBytes`, `dataUrl`), Pixir-native snake-case variants, or ACP
  `resource_link` blocks (`uri`, `name`, `mimeType`, `size`). Local `file://`
  links are copied into Pixir's Session Resource store when readable. Remote or
  unsupported links are recorded as link-only descriptors and are not
  rehydratable until a later explicit import/fetch records bytes.

  Raw base64 and local source paths never appear in the returned descriptors.
  """
  @spec ingest_attachments(String.t(), [map()] | nil, keyword()) ::
          {:ok, [descriptor()]} | {:error, map()}
  def ingest_attachments(session_id, nil, _opts) do
    with :ok <- SessionId.validate(session_id), do: {:ok, []}
  end

  def ingest_attachments(session_id, [], _opts) do
    with :ok <- SessionId.validate(session_id), do: {:ok, []}
  end

  def ingest_attachments(session_id, attachments, opts)
      when is_binary(session_id) and is_list(attachments) do
    workspace = Keyword.get(opts, :workspace, File.cwd!())

    with :ok <- SessionId.validate(session_id) do
      attachments
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {attachment, index}, {:ok, acc} ->
        case ingest_attachment(session_id, attachment, workspace, index) do
          {:ok, descriptor} -> {:cont, {:ok, [descriptor | acc]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> case do
        {:ok, descriptors} -> {:ok, Enum.reverse(descriptors)}
        {:error, _} = error -> error
      end
    end
  end

  def ingest_attachments(_session_id, _attachments, _opts),
    do:
      {:error,
       Tool.error(:invalid_args, "attachments must be a list", %{
         expected: "list of image attachment or resource_link maps"
       })}

  @doc "Return the Provider-ready data URL for a resource descriptor."
  @spec data_url(String.t(), descriptor(), keyword()) :: {:ok, String.t()} | {:error, map()}
  def data_url(session_id, descriptor, opts \\ [])
      when is_binary(session_id) and is_map(descriptor) do
    workspace = Keyword.get(opts, :workspace, File.cwd!())

    with :ok <- SessionId.validate(session_id) do
      if descriptor["kind"] == "image" do
        with {:ok, path} <- resource_path(session_id, descriptor, workspace),
             {:ok, bytes} <- read_resource(path, descriptor) do
          {:ok, "data:#{descriptor["mime_type"]};base64," <> Base.encode64(bytes)}
        end
      else
        {:error,
         Tool.error(:invalid_args, "session resource is not an image provider input", %{
           resource_id: descriptor["resource_id"],
           kind: descriptor["kind"]
         })}
      end
    end
  end

  @doc "Resolve a descriptor to an on-disk path without reading the payload."
  @spec resource_path(String.t(), descriptor(), String.t()) :: {:ok, String.t()} | {:error, map()}
  def resource_path(session_id, descriptor, workspace \\ File.cwd!())
      when is_binary(session_id) and is_map(descriptor) do
    with :ok <- SessionId.validate(session_id),
         {:ok, resource_id} <- descriptor_field(descriptor, "resource_id"),
         {:ok, sha} <- descriptor_field(descriptor, "content_sha256"),
         {:ok, extension} <- descriptor_field(descriptor, "extension") do
      {:ok,
       session_id
       |> Paths.session_resources_dir(workspace)
       |> Path.join(resource_id)
       |> Path.join(sha <> "." <> extension)}
    end
  end

  @doc """
  Copy stored resource payloads referenced in replayed Events from parent to child Session.

  Link-only descriptors without `content_sha256` are skipped. Payload copy uses the same
  `resource_id` and checksum paths under the child Session store.
  """
  @spec copy_referenced_resources(String.t(), String.t(), [map()], keyword()) ::
          :ok | {:error, map()}
  def copy_referenced_resources(parent_session_id, child_session_id, events, opts \\ [])
      when is_binary(parent_session_id) and is_binary(child_session_id) and is_list(events) do
    workspace = Keyword.get(opts, :workspace, File.cwd!())

    with :ok <- SessionId.validate(parent_session_id),
         :ok <- SessionId.validate(child_session_id) do
      events
      |> Enum.flat_map(&event_resources/1)
      |> Enum.uniq_by(& &1["resource_id"])
      |> Enum.reduce_while(:ok, fn descriptor, :ok ->
        case copy_descriptor_payload(parent_session_id, child_session_id, descriptor, workspace) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  @doc "Find one resource descriptor in folded History by Session resource id."
  @spec find_descriptor([map()], String.t()) :: {:ok, descriptor()} | {:error, map()}
  def find_descriptor(history, resource_id) when is_list(history) and is_binary(resource_id) do
    history
    |> Enum.flat_map(&event_resources/1)
    |> Enum.find(&(&1["resource_id"] == resource_id))
    |> case do
      nil ->
        {:error,
         Tool.error(:not_found, "session resource not found", %{
           resource_id: resource_id
         })}

      descriptor ->
        {:ok, descriptor}
    end
  end

  @doc "Render a compact, text-only descriptor for default replay."
  @spec render_descriptor(descriptor()) :: String.t()
  def render_descriptor(descriptor) when is_map(descriptor) do
    case descriptor["kind"] do
      "image" ->
        [
          "Image resource #{descriptor["resource_id"]}:",
          "name=#{descriptor["name"] || "unnamed"}",
          "mime=#{descriptor["mime_type"] || "unknown"}",
          "size_bytes=#{descriptor["size_bytes"] || "unknown"}",
          "sha256=#{descriptor["content_sha256"] || "unknown"}.",
          "The original image is stored locally; call resource_view with this resource_id only if exact visual inspection is needed."
        ]

      "file" ->
        [
          "File resource #{descriptor["resource_id"]}:",
          "name=#{descriptor["name"] || "unnamed"}",
          "mime=#{descriptor["mime_type"] || "unknown"}",
          "size_bytes=#{descriptor["size_bytes"] || "unknown"}",
          "sha256=#{descriptor["content_sha256"] || "unknown"}.",
          "Pixir stored the original bytes locally, but this resource kind is not yet projected to the Provider by default."
        ]

      "resource_link" ->
        [
          "Resource link #{descriptor["resource_id"]}:",
          "name=#{descriptor["name"] || "unnamed"}",
          "uri=#{descriptor["uri"] || "unknown"}",
          "mime=#{descriptor["mime_type"] || "unknown"}.",
          "Pixir recorded the link but did not copy local bytes, so resource_view cannot rehydrate it yet."
        ]

      _ ->
        [
          "Session resource #{descriptor["resource_id"] || "unknown"}:",
          "kind=#{descriptor["kind"] || "unknown"}",
          "name=#{descriptor["name"] || "unnamed"}."
        ]
    end
    |> Enum.join(" ")
    |> Tool.truncate(@max_descriptor_text)
  end

  @doc "Build a text block for one or more descriptors."
  @spec render_descriptors([descriptor()]) :: String.t()
  def render_descriptors(resources) when is_list(resources) do
    resources
    |> Enum.map(&render_descriptor/1)
    |> Enum.join("\n")
    |> Tool.truncate(@max_descriptor_text)
  end

  defp ingest_attachment(session_id, attachment, workspace, index) when is_map(attachment) do
    type = field(attachment, "type")

    mime_type =
      normalize_mime_type(field(attachment, "mimeType") || field(attachment, "mime_type"))

    data_url = field(attachment, "dataUrl") || field(attachment, "data_url")

    cond do
      type == "resource_link" ->
        ingest_resource_link(session_id, attachment, workspace, index)

      type not in [nil, "image"] ->
        {:error,
         Tool.error(:invalid_args, "unsupported attachment type", %{
           index: index,
           type: type,
           supported: ["image", "resource_link"]
         })}

      not is_binary(mime_type) or not String.starts_with?(mime_type, @image_mime_prefix) ->
        {:error,
         Tool.error(:invalid_args, "unsupported image mime type", %{
           index: index,
           mime_type: mime_type
         })}

      not is_binary(data_url) ->
        {:error,
         Tool.error(:invalid_args, "image attachment is missing dataUrl", %{
           index: index
         })}

      true ->
        with {:ok, bytes, parsed_mime} <- decode_data_url(data_url),
             :ok <- validate_mime(index, mime_type, parsed_mime),
             {:ok, descriptor} <-
               persist_payload(
                 session_id,
                 attachment,
                 workspace,
                 index,
                 "image",
                 mime_type,
                 bytes
               ) do
          {:ok, descriptor}
        end
    end
  end

  defp ingest_attachment(_session_id, _attachment, _workspace, index),
    do:
      {:error,
       Tool.error(:invalid_args, "attachment must be an object", %{
         index: index
       })}

  defp decode_data_url("data:" <> rest) do
    case String.split(rest, ",", parts: 2) do
      [header, encoded] ->
        mime =
          header
          |> String.split(";")
          |> List.first()
          |> normalize_mime_type()

        if String.contains?(String.downcase(header), ";base64") do
          case Base.decode64(encoded) do
            {:ok, bytes} ->
              {:ok, bytes, mime}

            :error ->
              {:error, Tool.error(:invalid_args, "image dataUrl is not valid base64", %{})}
          end
        else
          {:error, Tool.error(:invalid_args, "image dataUrl must be base64 encoded", %{})}
        end

      _ ->
        {:error, Tool.error(:invalid_args, "image dataUrl is malformed", %{})}
    end
  end

  defp decode_data_url(_),
    do: {:error, Tool.error(:invalid_args, "image dataUrl is malformed", %{})}

  defp validate_mime(_index, mime_type, mime_type), do: :ok

  defp validate_mime(index, declared, parsed) do
    {:error,
     Tool.error(:invalid_args, "image dataUrl mime type does not match attachment mimeType", %{
       index: index,
       mime_type: declared,
       data_url_mime_type: parsed
     })}
  end

  defp ingest_resource_link(session_id, attachment, workspace, index) do
    uri = field(attachment, "uri")

    cond do
      not is_binary(uri) or String.trim(uri) == "" ->
        {:error, Tool.error(:invalid_args, "resource_link is missing uri", %{index: index})}

      true ->
        case file_uri_path(uri) do
          {:ok, path} ->
            ingest_file_uri(session_id, attachment, workspace, index, path)

          {:error, :payload_bearing_uri} ->
            {:error,
             Tool.error(:invalid_args, "resource_link uri embeds payload bytes", %{
               index: index,
               uri_scheme: source_uri_scheme(uri),
               next_action: "Use an image content block for data URLs instead of resource_link."
             })}

          {:error, :remote_or_unsupported} ->
            {:ok, link_only_descriptor(attachment, index, uri)}

          {:error, reason} ->
            {:error,
             Tool.error(:invalid_args, "resource_link uri is malformed", %{
               index: index,
               uri: redact_uri(uri),
               reason: reason
             })}
        end
    end
  end

  defp ingest_file_uri(session_id, attachment, workspace, index, path) do
    case File.read(path) do
      {:ok, bytes} ->
        mime_type =
          attachment
          |> field("mimeType")
          |> normalize_mime_type()
          |> Kernel.||(mime_type_for_path(path))

        kind = if String.starts_with?(mime_type, @image_mime_prefix), do: "image", else: "file"

        persist_payload(session_id, attachment, workspace, index, kind, mime_type, bytes)

      {:error, :enoent} ->
        {:error,
         Tool.error(:resource_missing, "resource_link file does not exist", %{
           index: index,
           uri_scheme: "file"
         })}

      {:error, reason} ->
        {:error,
         Tool.error(:read_failed, "could not read resource_link file", %{
           index: index,
           uri_scheme: "file",
           reason: reason
         })}
    end
  end

  defp persist_payload(session_id, attachment, workspace, index, kind, mime_type, bytes) do
    resource_id = "res_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    sha = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    extension = extension_for_mime(mime_type, attachment)

    resources_dir = Paths.session_resources_dir(session_id, workspace)
    dir = Path.join(resources_dir, resource_id)

    path = Path.join(dir, sha <> "." <> extension)

    with {:ok, ^resources_dir} <- Paths.ensure_state_dir(workspace, resources_dir),
         :ok <- File.mkdir_p(dir),
         :ok <- atomic_write(path, bytes) do
      descriptor =
        %{
          "resource_id" => resource_id,
          "kind" => kind,
          "name" => field(attachment, "name") || "#{kind}-#{index}.#{extension}",
          "mime_type" => mime_type,
          "size_bytes" => byte_size(bytes),
          "declared_size_bytes" =>
            field(attachment, "sizeBytes") || field(attachment, "size_bytes") ||
              field(attachment, "size"),
          "content_sha256" => sha,
          "extension" => extension,
          "store_ref" => "session://#{session_id}/resources/#{resource_id}/#{sha}.#{extension}",
          "detail" => field(attachment, "detail") || @default_detail,
          "source" => field(attachment, "type") || "attachment",
          "source_uri_scheme" => source_uri_scheme(field(attachment, "uri")),
          "title" => field(attachment, "title"),
          "description" => field(attachment, "description")
        }
        |> compact_descriptor()

      {:ok, descriptor}
    else
      {:error, reason} ->
        {:error,
         Tool.error(:write_failed, "could not persist session resource", %{
           index: index,
           reason: reason
         })}
    end
  end

  defp link_only_descriptor(attachment, index, uri) do
    resource_id = "res_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    %{
      "resource_id" => resource_id,
      "kind" => "resource_link",
      "name" => field(attachment, "name") || "resource-link-#{index}",
      "mime_type" =>
        normalize_mime_type(field(attachment, "mimeType") || field(attachment, "mime_type")),
      "declared_size_bytes" => field(attachment, "size"),
      "uri" => redact_uri(uri),
      "uri_scheme" => source_uri_scheme(uri) || "unknown",
      "rehydratable" => false,
      "title" => field(attachment, "title"),
      "description" => field(attachment, "description")
    }
    |> compact_descriptor()
  end

  defp copy_descriptor_payload(parent_session_id, child_session_id, descriptor, workspace) do
    case descriptor_field(descriptor, "content_sha256") do
      {:error, _} ->
        :ok

      {:ok, _} ->
        with {:ok, src} <- resource_path(parent_session_id, descriptor, workspace),
             {:ok, bytes} <- read_resource(src, descriptor),
             {:ok, dst} <- resource_path(child_session_id, descriptor, workspace) do
          File.mkdir_p!(Path.dirname(dst))
          atomic_write(dst, bytes)
        end
    end
  end

  defp atomic_write(path, bytes) do
    tmp = path <> ".tmp-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

    with :ok <- File.write(tmp, bytes),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  defp read_resource(path, descriptor) do
    case File.read(path) do
      {:ok, bytes} ->
        expected = descriptor["content_sha256"]
        actual = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

        if expected == actual do
          {:ok, bytes}
        else
          {:error,
           Tool.error(:resource_missing, "session resource checksum mismatch", %{
             resource_id: descriptor["resource_id"],
             expected_sha256: expected,
             actual_sha256: actual
           })}
        end

      {:error, :enoent} ->
        {:error,
         Tool.error(:resource_missing, "session resource payload is missing", %{
           resource_id: descriptor["resource_id"],
           path: path
         })}

      {:error, reason} ->
        {:error,
         Tool.error(:read_failed, "could not read session resource payload", %{
           resource_id: descriptor["resource_id"],
           reason: reason
         })}
    end
  end

  defp descriptor_field(descriptor, key) do
    case descriptor[key] do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        {:error,
         Tool.error(:invalid_args, "resource descriptor is missing #{key}", %{
           key: key
         })}
    end
  end

  defp event_resources(%{type: :user_message, data: %{"resources" => resources}})
       when is_list(resources),
       do: Enum.filter(resources, &resource_descriptor?/1)

  defp event_resources(_event), do: []

  defp field(map, key) when is_binary(key) do
    Map.get(map, key) || Map.get(map, underscore(key))
  end

  defp compact_descriptor(descriptor) do
    Map.reject(descriptor, fn {_key, value} -> is_nil(value) or value == "" end)
  end

  defp resource_descriptor?(%{"resource_id" => resource_id}) when is_binary(resource_id),
    do: true

  defp resource_descriptor?(_), do: false

  defp file_uri_path(uri) do
    parsed = URI.parse(uri)
    scheme = parsed.scheme && String.downcase(parsed.scheme)

    case %{parsed | scheme: scheme} do
      %URI{scheme: "data"} ->
        {:error, :payload_bearing_uri}

      %URI{scheme: "file", host: host, path: path}
      when host in [nil, "", "localhost"] and is_binary(path) and path != "" ->
        {:ok, URI.decode(path)}

      %URI{scheme: "file"} ->
        {:error, :unsupported_file_uri_host}

      %URI{scheme: scheme} when is_binary(scheme) ->
        {:error, :remote_or_unsupported}

      _ ->
        {:error, :missing_scheme}
    end
  rescue
    ArgumentError -> {:error, :invalid_uri}
  end

  defp normalize_mime_type(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_mime_type(_), do: nil

  defp source_uri_scheme(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: scheme} when is_binary(scheme) and scheme != "" ->
        String.downcase(scheme)

      _ ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  defp source_uri_scheme(_), do: nil

  defp redact_uri(uri) when is_binary(uri) do
    uri
    |> URI.parse()
    |> Map.merge(%{userinfo: nil, query: nil, fragment: nil})
    |> URI.to_string()
    |> Tool.truncate(1_000)
  rescue
    ArgumentError -> "<invalid-uri>"
  end

  defp redact_uri(_), do: nil

  defp mime_type_for_path(path) do
    case String.downcase(Path.extname(path)) do
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".webp" -> "image/webp"
      ".gif" -> "image/gif"
      ".txt" -> "text/plain"
      ".md" -> "text/markdown"
      ".json" -> "application/json"
      ".pdf" -> "application/pdf"
      _ -> @default_mime_type
    end
  end

  defp underscore("mimeType"), do: "mime_type"
  defp underscore("sizeBytes"), do: "size_bytes"
  defp underscore("dataUrl"), do: "data_url"
  defp underscore(key), do: key

  defp extension_for_mime("image/png", _attachment), do: "png"
  defp extension_for_mime("image/jpeg", _attachment), do: "jpg"
  defp extension_for_mime("image/jpg", _attachment), do: "jpg"
  defp extension_for_mime("image/webp", _attachment), do: "webp"
  defp extension_for_mime("image/gif", _attachment), do: "gif"
  defp extension_for_mime("text/plain", attachment), do: extension_from_name(attachment) || "txt"

  defp extension_for_mime("text/markdown", attachment),
    do: extension_from_name(attachment) || "md"

  defp extension_for_mime("application/json", attachment),
    do: extension_from_name(attachment) || "json"

  defp extension_for_mime("application/pdf", _attachment), do: "pdf"
  defp extension_for_mime(_mime, attachment), do: extension_from_name(attachment) || "bin"

  defp extension_from_name(attachment) do
    attachment
    |> field("name")
    |> case do
      name when is_binary(name) ->
        name
        |> Path.extname()
        |> String.trim_leading(".")
        |> case do
          "" -> nil
          extension -> extension
        end

      _ ->
        nil
    end
  end
end
