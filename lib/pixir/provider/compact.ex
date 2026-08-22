defmodule Pixir.Provider.Compact do
  @moduledoc """
  Distinct standalone compact client for `POST /responses/compact` (ADR 0040 / #522-C).

  This is not `stream/2`. Tests inject `transport:`. `store: false` stays.

  Overlay / `compact_threshold` (D) is a separate gate. `chatgpt_codex` Turns
  still send `compact_threshold`; standalone C does not POST to the Codex
  `/compact` 404 host. Official `POST /responses/compact` is only
  `https://api.openai.com/v1/responses/compact`.
  """

  alias Pixir.Provider.TransportError
  alias Pixir.Providers.{ErrBody, ResolvedProviderRequest, ResponsesBackend}
  alias Pixir.Tool

  @official_responses_http_url "https://api.openai.com/v1/responses"

  @doc """
  Standalone C host classification. Independent of overlay / D.

  `:chatgpt_codex` is the Codex 404 host. `:official_responses` is the
  documented `api.openai.com` compact route. Do not invent another Codex URL.
  """
  @spec responses_host(ResolvedProviderRequest.t() | ResponsesBackend.t() | term()) ::
          :chatgpt_codex | :official_responses | :other
  def responses_host(%ResolvedProviderRequest{} = resolved) do
    responses_host(ResolvedProviderRequest.responses_backend(resolved))
  end

  def responses_host(%ResponsesBackend{} = backend) do
    cond do
      ResponsesBackend.mode(backend) == :chatgpt_codex ->
        :chatgpt_codex

      official_responses_compact_backend?(backend) ->
        :official_responses

      true ->
        :other
    end
  end

  def responses_host(_backend), do: :other

  @doc "True only when standalone `POST /responses/compact` exists on this host."
  @spec standalone_supported?(ResolvedProviderRequest.t() | term()) :: boolean()
  def standalone_supported?(%ResolvedProviderRequest{} = resolved) do
    ResolvedProviderRequest.dialect(resolved) != :anthropic and
      responses_host(resolved) == :official_responses
  end

  def standalone_supported?(_resolved), do: false

  @doc false
  @spec ensure_supported_backend(ResolvedProviderRequest.t()) :: :ok | {:error, map()}
  def ensure_supported_backend(%ResolvedProviderRequest{} = resolved) do
    if standalone_supported?(resolved), do: :ok, else: native_unavailable()
  end

  def ensure_supported_backend(_resolved), do: native_unavailable()

  @doc false
  @spec dispatch(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def dispatch(http_request, opts) when is_map(http_request) and is_list(opts) do
    init = %{status: nil, buffer: "", err_body: ErrBody.new()}

    case run_transport(opts, http_request, init, &handle_chunk/2) do
      {:ok, acc} ->
        decode(acc)

      {:error, reason, acc} ->
        {:error, with_attempted(TransportError.project(reason, status: acc.status))}

      {:error, reason} ->
        {:error, with_attempted(TransportError.project(reason))}
    end
  end

  defp run_transport(opts, http_request, init, fun) do
    case Keyword.get(opts, :transport) do
      transport when is_function(transport, 3) ->
        transport.(http_request, init, fun)

      nil ->
        Pixir.Provider.FinchTransport.stream(http_request, init, fun)

      transport ->
        transport.stream(http_request, init, fun)
    end
  end

  defp handle_chunk({:status, status}, acc), do: %{acc | status: status}
  defp handle_chunk({:headers, _headers}, acc), do: acc

  defp handle_chunk({:data, data}, %{status: status} = acc) when status in 200..299,
    do: %{acc | buffer: acc.buffer <> data}

  defp handle_chunk({:data, data}, acc),
    do: %{acc | err_body: ErrBody.append(acc.err_body, data)}

  defp handle_chunk(_chunk, acc), do: acc

  defp decode(%{status: status, buffer: buffer}) when status in 200..299 do
    case Jason.decode(buffer) do
      {:ok, decoded} when is_map(decoded) ->
        case Map.get(decoded, "output") do
          output when is_list(output) ->
            usage = Map.get(decoded, "usage")

            {:ok,
             %{
               output: output,
               usage: usage,
               usage_summary: Pixir.Provider.usage_summary(usage)
             }}

          _missing ->
            {:error,
             with_attempted(
               Tool.error(:invalid_response, "compact response missing output list", %{})
             )}
        end

      {:ok, _other} ->
        {:error,
         with_attempted(
           Tool.error(:invalid_response, "compact response must be a JSON object", %{})
         )}

      {:error, _reason} ->
        {:error,
         with_attempted(Tool.error(:invalid_response, "compact response was not JSON", %{}))}
    end
  end

  defp decode(%{status: 400}) do
    {:error,
     with_attempted(
       Tool.error(:backend_rejected, "compact endpoint rejected the request", %{status: 400})
     )}
  end

  defp decode(%{status: 404}) do
    {:error,
     with_attempted(
       Tool.error(:provider_http_error, "compact endpoint was not found", %{status: 404})
     )}
  end

  defp decode(%{status: status} = acc) when is_integer(status) do
    {:error, with_attempted(TransportError.project({:http_error, status}, status: acc.status))}
  end

  defp decode(_acc) do
    {:error,
     with_attempted(Tool.error(:invalid_response, "compact response missing HTTP status", %{}))}
  end

  defp with_attempted(%{error: %{details: details}} = error) when is_map(details) do
    put_in(error, [:error, :details, :compact_attempted], true)
  end

  defp with_attempted(%{error: error_map} = error) when is_map(error_map) do
    put_in(error, [:error, :details], %{compact_attempted: true})
  end

  defp with_attempted(error), do: error

  defp official_responses_compact_backend?(%ResponsesBackend{} = backend) do
    ResponsesBackend.mode(backend) == :open_responses and
      official_responses_http_url?(ResponsesBackend.endpoint(backend))
  end

  defp official_responses_http_url?({:responses_url, url}), do: official_responses_http_url?(url)

  defp official_responses_http_url?({:base_url, base}) when is_binary(base) do
    official_responses_http_url?(String.trim_trailing(base, "/") <> "/v1/responses")
  end

  defp official_responses_http_url?(url) when is_binary(url) do
    String.trim_trailing(url, "/") == @official_responses_http_url
  end

  defp official_responses_http_url?(_url), do: false

  defp native_unavailable do
    {:error,
     Tool.error(:native_unavailable, "native compact is unavailable on this Provider/backend", %{
       compact_attempted: false
     })}
  end
end
