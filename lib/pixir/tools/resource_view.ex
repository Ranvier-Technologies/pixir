defmodule Pixir.Tools.ResourceView do
  @moduledoc """
  Explicitly rehydrate a local Session Resource for Provider inspection.

  `resource_view` is the model-facing side of ADR 0021's Resource View concept:
  resources replay as lightweight descriptors, but a model may call this tool
  when it needs exact visual evidence. The first supported projection is image
  rehydration: the tool verifies that the resource descriptor exists in the
  Session Log and that the local image payload still exists; the Provider then
  projects the image on the next model call.
  """

  use Pixir.Tool

  alias Pixir.{Log, SessionResources, Tool}

  @impl Pixir.Tool
  def __tool__ do
    %{
      name: "resource_view",
      description:
        "Request exact inspection of a local Session Resource. Use this when a " <>
          "replayed resource descriptor is insufficient and a stored image resource " <>
          "must be rehydrated for visual analysis.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "resource_id" => %{
            "type" => "string",
            "description" => "The resource_id from the replayed Session Resource descriptor."
          },
          "reason" => %{
            "type" => "string",
            "description" => "Short reason why exact visual inspection is needed."
          }
        },
        "required" => ["resource_id"]
      }
    }
  end

  @impl Pixir.Tool
  def execute(%{"resource_id" => resource_id} = args, context) when is_binary(resource_id) do
    reason = args["reason"] || "exact visual inspection requested"

    with {:ok, history} <- Log.fold(context.session_id, workspace: context.workspace),
         {:ok, descriptor} <- SessionResources.find_descriptor(history, resource_id),
         {:ok, _data_url} <-
           SessionResources.data_url(context.session_id, descriptor, workspace: context.workspace) do
      {:ok,
       %{
         "output" =>
           "Resource #{resource_id} is available and will be rehydrated for provider inspection.",
         "resource_view" => %{
           "resource_id" => resource_id,
           "reason" => reason,
           "descriptor" => descriptor
         }
       }}
    end
  end

  def execute(_args, _context),
    do: {:error, Tool.error(:invalid_args, "resource_id must be a string", %{})}

  @impl Pixir.Tool
  def dry_run(%{"resource_id" => resource_id} = args, _context) when is_binary(resource_id) do
    {:ok,
     %{
       "dry_run" => true,
       "would" => "rehydrate_session_resource",
       "resource_id" => resource_id,
       "reason" => args["reason"]
     }}
  end

  def dry_run(_args, _context),
    do: {:error, Tool.error(:invalid_args, "resource_id must be a string", %{})}
end
