defmodule Pixir.Provider.OpenResponsesSchemaTest do
  use ExUnit.Case, async: true

  alias Pixir.Provider.{OpenResponsesSchema, ResponsesExtensions}
  alias Pixir.Provider.OpenResponsesSchema.Generated

  @fixture_dir Path.expand("../../fixtures/provider/open_responses", __DIR__)
  @subset Path.join(@fixture_dir, "schema_subset.json")
  @corpus Path.join(@fixture_dir, "schema_corpus.jsonl")
  @corpus_bases Path.join(@fixture_dir, "schema_corpus_bases.json")
  @manifest Path.join(@fixture_dir, "schema_manifest.json")

  test "generated authority enumerates all roots refs keywords limits and Resource requirements" do
    manifest = Jason.decode!(File.read!(@manifest))
    generated = Generated.manifest()

    assert generated == manifest
    assert manifest["root_count"] == 24
    assert manifest["reachable_schema_count"] == 69
    assert manifest["response_resource_required_property_count"] == 31
    assert map_size(manifest["roots"]) == 24
    assert length(manifest["reachable_schemas"]) == 69
    assert manifest["limits"] == %{"max_depth" => 64, "max_evaluations" => 250_000}

    assert manifest["validation_keywords"] ==
             ~w($ref additionalProperties allOf anyOf enum items oneOf properties required type)

    assert Map.keys(manifest["corpus"]["counts"]) |> Enum.sort() ==
             ~w(ignored-safe invalid local-limit portable unsupported)

    assert manifest["corpus"]["counts"] |> Map.values() |> Enum.sum() ==
             manifest["corpus"]["row_count"]

    assert manifest["corpus"]["encoding"] == "base-event-recipe-v1"
    assert Enum.all?(manifest["corpus"]["zero_conditions"], fn {_name, count} -> count == 0 end)
    assert digest(File.read!(@subset)) == manifest["digests"]["canonical_subset_sha256"]
    assert digest(File.read!(@corpus)) == manifest["digests"]["corpus_sha256"]
    assert digest(File.read!(@corpus_bases)) == manifest["digests"]["corpus_bases_sha256"]
  end

  test "coverage gate is complete and independently rejects removed type union and array evidence" do
    coverage =
      @manifest
      |> File.read!()
      |> Jason.decode!()
      |> get_in(["corpus", "coverage"])

    assert coverage_complete?(coverage)

    for path <- [
          ["json_incompatible_kinds", "observed", "null"],
          ["json_integer_representations", "observed", "integral_float"],
          ["union_branches", "oneOf_observed"],
          ["array_branches", "observed"]
        ] do
      assert get_in(coverage, path) > 0
      refute coverage |> put_in(path, get_in(coverage, path) - 1) |> coverage_complete?()
    end
  end

  test "every differential corpus row has exactly one runtime disposition" do
    rows = corpus_rows()
    assert length(rows) == manifest_row_count()
    assert Enum.uniq_by(rows, & &1["id"]) == rows

    assert Enum.uniq_by(rows, fn row ->
             Jason.encode!([row["disposition"], row["event"]])
           end) == rows

    Enum.each(rows, fn row ->
      result = ResponsesExtensions.validate_stream_event(row["event"])

      case row["disposition"] do
        "invalid" -> assert result == {:error, :invalid_event_shape}, row["label"]
        "local-limit" -> assert result == {:error, :invalid_event_shape}, row["label"]
        "portable" -> assert result == {:ok, :known}, row["label"]
        "ignored-safe" -> assert result == {:ok, :known}, row["label"]
        "unsupported" -> assert match?({:unsupported, _fixed_capability}, result), row["label"]
      end
    end)
  end

  test "Draft 2020-12 integral floats validate as integers before local policy" do
    event = %{
      "type" => "response.output_text.delta",
      "sequence_number" => 1.0,
      "item_id" => "item",
      "output_index" => -0.0,
      "content_index" => 0.0,
      "delta" => "text",
      "logprobs" => []
    }

    assert OpenResponsesSchema.validate(event["type"], event) == :ok
    assert ResponsesExtensions.validate_stream_event(event) == {:ok, :known}
  end

  test "unusual pinned rules retain their independent oracle dispositions" do
    by_label = Map.new(corpus_rows(), &{&1["label"], &1})

    expected = %{
      "golden:metadata_unconstrained:response.completed" => "portable",
      "golden:json_schema_format_schema_null:response.completed" => "portable",
      "golden:function_tool_choice_name_optional:response.completed" => "portable",
      "golden:input_file_only_type:response.completed" => "unsupported",
      "golden:reasoning_summary_required_content_optional:response.completed" => "unsupported"
    }

    Enum.each(expected, fn {label, disposition} ->
      assert by_label[label]["openapi_valid"] == true
      assert by_label[label]["disposition"] == disposition
    end)
  end

  test "local coordinate limits cover every exact owner and preserve every non-owner" do
    rows = corpus_rows()
    local_rows = Enum.filter(rows, &String.starts_with?(&1["label"], "local-limit:"))
    nonowner_rows = Enum.filter(rows, &String.starts_with?(&1["label"], "nonowner:"))

    assert Enum.frequencies_by(local_rows, fn row ->
             row["label"] |> String.split(":") |> Enum.at(1)
           end) == %{
             "content_index_owner" => 5,
             "function_call_call_id_empty" => 1,
             "function_call_id_empty" => 1,
             "function_call_name_empty" => 1,
             "item_id_owner" => 7,
             "message_id_empty" => 1,
             "output_index_owner" => 7,
             "sequence_number_negative" => 24
           }

    assert Enum.frequencies_by(nonowner_rows, fn row ->
             row["label"] |> String.split(":") |> Enum.at(1)
           end) == %{"content_index" => 19, "item_id" => 17, "output_index" => 17}

    assert Enum.all?(nonowner_rows, &(&1["openapi_valid"] == true))

    for family <- ~w(response.reasoning response.reasoning_summary response.refusal),
        row <- nonowner_rows,
        String.starts_with?(row["base"], family) do
      assert row["disposition"] == "unsupported", row["label"]
    end
  end

  test "budget exhaustion is fixed and does not expose remote values" do
    logprob = %{"token" => "secret", "logprob" => 0, "bytes" => [], "top_logprobs" => []}

    event = %{
      "type" => "response.output_text.done",
      "sequence_number" => 0,
      "item_id" => "item",
      "output_index" => 0,
      "content_index" => 0,
      "text" => "remote text",
      "logprobs" => List.duplicate(logprob, 50_000)
    }

    assert OpenResponsesSchema.validate(event["type"], event) ==
             {:error, :validation_budget_exceeded}

    refute inspect(OpenResponsesSchema.validate(event["type"], event)) =~ "secret"
    refute inspect(OpenResponsesSchema.validate(event["type"], event)) =~ "remote text"
  end

  test "validator is total over deterministic arbitrary decoded JSON" do
    values = arbitrary_json_values(1_000, 0x320)

    Enum.each(Generated.known_event_types(), fn type ->
      Enum.each(values, fn value ->
        assert OpenResponsesSchema.validate(type, value) in [
                 :ok,
                 {:error, :invalid_event_shape},
                 {:error, :validation_budget_exceeded}
               ]
      end)
    end)
  end

  defp corpus_rows do
    bases = @corpus_bases |> File.read!() |> Jason.decode!()

    @corpus
    |> File.stream!(:line, [])
    |> Enum.map(fn line ->
      row = Jason.decode!(line)
      Map.put(row, "event", expand_recipe!(Map.fetch!(bases, row["base"]), row["ops"]))
    end)
  end

  defp expand_recipe!(base, operations) do
    Enum.reduce(operations, base, fn
      %{"op" => "replace-root", "value" => value}, _event -> value
      %{"op" => "set", "path" => path, "value" => value}, event -> put_path!(event, path, value)
      %{"op" => "delete", "path" => path}, event -> delete_path!(event, path)
    end)
  end

  defp put_path!(_value, [], replacement), do: replacement
  defp put_path!(map, [key], value) when is_map(map), do: Map.put(map, key, value)

  defp put_path!(map, [key | rest], value) when is_map(map),
    do: Map.put(map, key, put_path!(Map.fetch!(map, key), rest, value))

  defp delete_path!(map, [key]) when is_map(map), do: Map.delete(map, key)

  defp delete_path!(map, [key | rest]) when is_map(map),
    do: Map.put(map, key, delete_path!(Map.fetch!(map, key), rest))

  defp coverage_complete?(coverage) do
    coverage["missing_token_count"] == 0 and
      coverage["expected_token_count"] == coverage["observed_token_count"] and
      coverage["expected_token_sha256"] == coverage["observed_token_sha256"] and
      coverage["response_wrapper_equal"] and
      coverage["schema_families"]["expected"] == coverage["schema_families"]["observed"] and
      coverage["schema_families"]["missing"] == [] and
      coverage["array_branches"]["expected"] == coverage["array_branches"]["observed"] and
      coverage["union_branches"]["oneOf_expected"] ==
        coverage["union_branches"]["oneOf_observed"] and
      coverage["union_branches"]["anyOf_expected"] ==
        coverage["union_branches"]["anyOf_observed"] and
      coverage["json_incompatible_kinds"]["expected"] ==
        coverage["json_incompatible_kinds"]["observed"] and
      coverage["json_integer_representations"]["expected"] ==
        coverage["json_integer_representations"]["observed"]
  end

  defp manifest_row_count do
    @manifest |> File.read!() |> Jason.decode!() |> get_in(["corpus", "row_count"])
  end

  defp arbitrary_json_values(count, seed) do
    :rand.seed(:exsss, {seed, seed + 1, seed + 2})
    Enum.map(1..count, fn _index -> arbitrary_json(0) end)
  end

  defp arbitrary_json(depth) when depth >= 5,
    do: Enum.random([nil, true, false, :rand.uniform(10), :rand.uniform(), "leaf"])

  defp arbitrary_json(depth) do
    case :rand.uniform(8) do
      1 -> nil
      2 -> :rand.uniform(100) - 50
      3 -> :rand.uniform()
      4 -> :rand.uniform(2) == 1
      5 -> "value-#{:rand.uniform(20)}"
      6 -> Enum.map(1..:rand.uniform(3), fn _ -> arbitrary_json(depth + 1) end)
      _ -> Map.new(1..:rand.uniform(3), fn index -> {"k#{index}", arbitrary_json(depth + 1)} end)
    end
  end

  defp digest(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
