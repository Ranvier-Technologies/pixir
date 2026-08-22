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
  `resource_id` and checksum paths under the child Session store. The copy is staged and
  finalized as one resource-directory unit. Copy/finalization errors remove only the
  operation's unique staging directory. After a non-empty transfer is finalized, the
  final child directory is operation-owned and is also removed if the following
  operation returns an error.
  """
  @spec copy_referenced_resources(String.t(), String.t(), [map()], keyword()) ::
          :ok | {:error, map()}
  def copy_referenced_resources(parent_session_id, child_session_id, events, opts \\ [])
      when is_binary(parent_session_id) and is_binary(child_session_id) and is_list(events) do
    case with_copied_resources(parent_session_id, child_session_id, events, opts, fn -> :ok end) do
      {:ok, _value} -> :ok
      {:error, _error} = error -> error
    end
  end

  @doc """
  Stage referenced payloads in the child workspace, finalize the complete resource
  directory, and run `operation`.

  This is the compensation boundary used by Fork and WarmStart for both shared and
  isolated workspaces. Copy and finalization errors remove the unique staging
  directory. After a non-empty transfer is finalized, `{:error, map()}` returned by
  `operation` removes both staging and the operation-owned final child resource
  directory. Successful descriptors are not rewritten: replay keeps the original
  `resource_id`, `content_sha256`, and `store_ref` evidence while the payload bytes live
  at the equivalent child-local path.

  Existing final child resources are never deleted as preparation: a non-empty
  transfer rejects that collision, while an empty transfer leaves them untouched.
  Compensation covers returned errors only. It is not VM-crash atomicity and does
  not roll back work performed after `operation` has returned success.
  """
  @spec with_copied_resources(
          String.t(),
          String.t(),
          [map()],
          keyword(),
          (-> :ok | {:ok, term()} | {:error, map()})
        ) :: {:ok, term()} | {:error, map()}
  def with_copied_resources(
        parent_session_id,
        child_session_id,
        events,
        opts,
        operation
      )
      when is_binary(parent_session_id) and is_binary(child_session_id) and is_list(events) and
             is_list(opts) and is_function(operation, 0) do
    if Keyword.keyword?(opts) do
      with_keyword_copy_options(
        parent_session_id,
        child_session_id,
        events,
        opts,
        operation
      )
    else
      invalid_copy_arguments()
    end
  end

  def with_copied_resources(
        _parent_session_id,
        _child_session_id,
        _events,
        _opts,
        _operation
      ),
      do: invalid_copy_arguments()

  defp with_keyword_copy_options(parent_session_id, child_session_id, events, opts, operation) do
    workspace = Keyword.get(opts, :workspace, File.cwd!())
    parent_workspace = Keyword.get(opts, :parent_workspace, workspace)
    child_workspace = Keyword.get(opts, :child_workspace, workspace)

    if is_binary(parent_workspace) and is_binary(child_workspace) do
      with_expanded_copy_options(
        parent_session_id,
        child_session_id,
        events,
        Path.expand(parent_workspace),
        Path.expand(child_workspace),
        opts,
        operation
      )
    else
      invalid_copy_arguments()
    end
  end

  defp with_expanded_copy_options(
         parent_session_id,
         child_session_id,
         events,
         parent_workspace,
         child_workspace,
         opts,
         operation
       ) do
    with :ok <- SessionId.validate(parent_session_id),
         :ok <- SessionId.validate(child_session_id) do
      descriptors =
        events
        |> Enum.flat_map(&event_resources/1)
        |> Enum.filter(&stored_descriptor?/1)
        |> Enum.uniq_by(& &1["resource_id"])

      do_with_copied_resources(
        parent_session_id,
        child_session_id,
        descriptors,
        parent_workspace,
        child_workspace,
        opts,
        operation
      )
    end
  end

  defp invalid_copy_arguments do
    {:error,
     Tool.error(:invalid_args, "session resource copy arguments are invalid", %{
       expected: "parent id, child id, event list, keyword options, and a zero-arity operation"
     })}
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

  defp do_with_copied_resources(
         parent_session_id,
         child_session_id,
         descriptors,
         parent_workspace,
         child_workspace,
         opts,
         operation
       ) do
    final = Paths.session_resources_dir(child_session_id, child_workspace)
    staged = staging_path(final)

    with :ok <- remove_resource_dirs([staged], child_session_id, :prepare),
         :ok <- ensure_final_available(final, descriptors, child_session_id) do
      case copy_descriptors_to_staging(
             parent_session_id,
             descriptors,
             parent_workspace,
             child_workspace,
             staged,
             opts
           ) do
        :ok ->
          case finalize_staged_resources(staged, final, descriptors, child_session_id) do
            :ok ->
              owned_paths = if descriptors == [], do: [staged], else: [staged, final]
              normalize_operation_result(operation.(), owned_paths, child_session_id)

            {:error, _error} = error ->
              compensate_resource_dirs(error, [staged], child_session_id)
          end

        {:error, _error} = error ->
          compensate_resource_dirs(error, [staged], child_session_id)
      end
    end
  end

  defp staging_path(final) do
    final <> ".staging-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp ensure_final_available(_final, [], _child_session_id), do: :ok

  defp ensure_final_available(final, _descriptors, child_session_id) do
    if File.exists?(final) do
      {:error,
       Tool.error(:already_exists, "child session resources already exist", %{
         child_session_id: child_session_id,
         path: final,
         next_actions: [
           "inspect_or_remove_the_existing_child_resource_directory",
           "retry_with_a_new_child_session_id"
         ]
       })}
    else
      :ok
    end
  end

  defp normalize_operation_result(:ok, _owned_paths, _child_session_id), do: {:ok, :ok}

  defp normalize_operation_result({:ok, _value} = success, _owned_paths, _child_session_id),
    do: success

  defp normalize_operation_result(
         {:error, %{error: %{kind: _kind}}} = error,
         owned_paths,
         child_session_id
       ),
       do: compensate_resource_dirs(error, owned_paths, child_session_id)

  defp normalize_operation_result(other, owned_paths, child_session_id) do
    error =
      Tool.error(:write_failed, "session resource operation returned an invalid result", %{
        child_session_id: child_session_id,
        observed_type: operation_result_type(other)
      })

    compensate_resource_dirs({:error, error}, owned_paths, child_session_id)
  end

  defp operation_result_type(value) when is_atom(value), do: "atom"
  defp operation_result_type(value) when is_binary(value), do: "binary"
  defp operation_result_type(value) when is_number(value), do: "number"
  defp operation_result_type(value) when is_list(value), do: "list"
  defp operation_result_type(value) when is_map(value), do: "map"
  defp operation_result_type(value) when is_tuple(value), do: "tuple"
  defp operation_result_type(value) when is_function(value), do: "function"
  defp operation_result_type(_value), do: "other"

  defp copy_descriptors_to_staging(
         parent_session_id,
         descriptors,
         parent_workspace,
         child_workspace,
         staged,
         opts
       ) do
    descriptors
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {descriptor, index}, :ok ->
      result =
        with {:ok, src} <- resource_path(parent_session_id, descriptor, parent_workspace),
             {:ok, bytes} <- read_resource(src, descriptor),
             {:ok, dst} <- staged_resource_path(staged, descriptor),
             :ok <- ensure_staged_dir(child_workspace, dst, descriptor),
             :ok <- run_copy_failpoint(opts, descriptor, dst, index),
             :ok <- write_copied_payload(dst, bytes, descriptor) do
          :ok
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  defp staged_resource_path(staged, descriptor) do
    with {:ok, resource_id} <- descriptor_field(descriptor, "resource_id"),
         {:ok, sha} <- descriptor_field(descriptor, "content_sha256"),
         {:ok, extension} <- descriptor_field(descriptor, "extension") do
      {:ok, Path.join([staged, resource_id, sha <> "." <> extension])}
    end
  end

  defp ensure_staged_dir(child_workspace, destination, descriptor) do
    expected = Path.dirname(destination)

    case Paths.ensure_state_dir(child_workspace, expected) do
      {:ok, ^expected} ->
        :ok

      {:error, %{error: _payload}} = error ->
        error

      {:error, reason} ->
        {:error, copy_failed(descriptor, destination, filesystem_failure(reason))}

      _other ->
        {:error, copy_failed(descriptor, destination, "invalid_state_dir_result")}
    end
  end

  # A deliberately narrow deterministic seam for compensation tests. It receives only
  # copy-local identity/path metadata and is never reflected into a descriptor or Event.
  defp run_copy_failpoint(opts, descriptor, destination, index) do
    case Keyword.get(opts, :resource_copy_failpoint) do
      nil ->
        :ok

      failpoint when is_function(failpoint, 1) ->
        case failpoint.(%{
               index: index,
               resource_id: descriptor["resource_id"],
               destination: destination
             }) do
          :ok ->
            :ok

          {:error, _reason} ->
            {:error, copy_failed(descriptor, destination, "injected_failure")}

          _other ->
            {:error, copy_failed(descriptor, destination, "invalid_failpoint_result")}
        end

      _other ->
        {:error, copy_failed(descriptor, destination, "invalid_failpoint")}
    end
  end

  defp write_copied_payload(path, bytes, descriptor) do
    case atomic_write(path, bytes) do
      :ok -> :ok
      {:error, reason} -> {:error, copy_failed(descriptor, path, filesystem_failure(reason))}
    end
  end

  defp copy_failed(descriptor, path, failure_class) do
    Tool.error(:write_failed, "could not copy session resource payload", %{
      resource_id: descriptor["resource_id"],
      path: path,
      failure_class: failure_class
    })
  end

  defp filesystem_failure(reason)
       when reason in [
              :eacces,
              :eagain,
              :ebadf,
              :ebusy,
              :edquot,
              :eexist,
              :efbig,
              :eintr,
              :einval,
              :eio,
              :eloop,
              :emfile,
              :enfile,
              :enodev,
              :enoent,
              :enomem,
              :enospc,
              :enotdir,
              :enotempty,
              :enotsup,
              :eperm,
              :erofs,
              :estale,
              :exdev
            ],
       do: Atom.to_string(reason)

  defp filesystem_failure(_reason), do: "filesystem_error"

  defp finalize_staged_resources(_staged, _final, [], _child_session_id), do: :ok

  defp finalize_staged_resources(staged, final, _descriptors, child_session_id) do
    # ADR 0021 payloads make a completed competing final directory non-empty. POSIX
    # rename may replace an empty directory but fails on a non-empty destination; on
    # that failure compensation removes only this operation's unique staging path.
    case File.rename(staged, final) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         Tool.error(:write_failed, "could not finalize child session resources", %{
           child_session_id: child_session_id,
           path: final,
           filesystem_reason: filesystem_failure(reason)
         })}
    end
  end

  defp compensate_resource_dirs({:error, original_error} = error, paths, child_session_id) do
    case remove_resource_dirs(paths, child_session_id, :compensate) do
      :ok ->
        error

      {:error, cleanup_error} ->
        {:error, put_cleanup_cause(cleanup_error, original_error)}
    end
  end

  defp put_cleanup_cause(%{error: %{details: details} = payload} = cleanup_error, original_error)
       when is_map(details) do
    %{
      cleanup_error
      | error: %{payload | details: Map.put(details, :original_error, original_error)}
    }
  end

  defp put_cleanup_cause(cleanup_error, _original_error), do: cleanup_error

  defp remove_resource_dirs(paths, child_session_id, phase) do
    Enum.reduce(paths, :ok, fn path, first_error ->
      cleanup_result = remove_resource_dir(path, child_session_id, phase)

      case {first_error, cleanup_result} do
        {:ok, :ok} -> :ok
        {:ok, {:error, _cleanup_error} = error} -> error
        {{:error, _first_error} = error, _later_result} -> error
      end
    end)
  end

  defp remove_resource_dir(path, child_session_id, phase) do
    case File.rm_rf(path) do
      {:ok, _removed} ->
        :ok

      {:error, reason, failed_path} ->
        {:error,
         Tool.error(:write_failed, "could not clean child session resources", %{
           child_session_id: child_session_id,
           path: failed_path,
           resource_path: path,
           phase: phase,
           filesystem_reason: filesystem_failure(reason)
         })}
    end
  end

  defp stored_descriptor?(%{"content_sha256" => sha}) when is_binary(sha) and sha != "",
    do: true

  defp stored_descriptor?(_descriptor), do: false

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
