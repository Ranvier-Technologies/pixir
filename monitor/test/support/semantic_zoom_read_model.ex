defmodule PixirMonitor.SemanticZoomReadModel do
  @moduledoc false

  def materialize_window(%{"graph" => %{"waves" => []}}, _start) do
    %{start: 0, entities: []}
  end

  def materialize_window(projection, start) do
    waves = projection["graph"]["waves"]

    safe_start =
      if is_integer(start) and start >= 0 and start < length(waves), do: start, else: 0

    last_wave = length(waves) - 1
    indexes = Enum.to_list(safe_start..last_wave)

    entities =
      if length(indexes) > 6 do
        visible = Enum.take(indexes, 6)

        visible_entities =
          visible
          |> Enum.filter(&(Enum.at(waves, &1) != []))
          |> Enum.map(&wave_entity(waves, &1, 0, 1))

        overflow_members = waves |> Enum.slice((safe_start + 6)..last_wave) |> List.flatten()

        if overflow_members == [] do
          visible_entities
        else
          visible_entities ++
            [
              %{
                key: "overflow:waves:#{safe_start + 6}-#{last_wave}",
                kind: :overflow,
                members: overflow_members
              }
            ]
        end
      else
        buckets = allocate_buckets(waves, indexes)

        Enum.flat_map(indexes, fn wave ->
          case Map.fetch(buckets, wave) do
            {:ok, bucket_count} ->
              Enum.map(0..(bucket_count - 1), fn bucket ->
                wave_entity(waves, wave, bucket, bucket_count)
              end)

            :error ->
              []
          end
        end)
      end

    boundary =
      if safe_start > 0 do
        [
          %{
            key: "boundary:upstream:waves:0-#{safe_start - 1}",
            kind: :boundary,
            members: waves |> Enum.slice(0, safe_start) |> List.flatten()
          }
        ]
      else
        []
      end

    entities =
      Enum.map(boundary ++ entities, fn entity ->
        Map.put(entity, :limitations, semantic_zoom_limitations(projection, entity))
      end)

    %{start: safe_start, entities: entities}
  end

  def semantic_zoom_limitations(projection, entity) do
    lookup = MapSet.new(projection["units"], & &1["logical_id"])
    root_limitations = Enum.map(projection["limitations"] || [], &to_string/1)

    member_limitations =
      if Enum.any?(entity.members, &(not MapSet.member?(lookup, &1))) do
        ["unit_evidence_absent"]
      else
        []
      end

    Enum.uniq(root_limitations ++ member_limitations)
  end

  def arc_limitations(projection, arc) do
    members = Enum.flat_map(arc.edges, &[&1["from"], &1["to"]])
    semantic_zoom_limitations(projection, %{members: members})
  end

  def materialize_arcs(window, projected_edges) do
    assignment = entity_assignment(window)

    projected_edges
    |> Enum.group_by(&{assignment[&1["from"]], assignment[&1["to"]]})
    |> Enum.map(fn {{from, to}, edges} -> %{from: from, to: to, edges: edges} end)
  end

  def exact_edge_union?(window, arcs, projected_edges) do
    assignment = entity_assignment(window)
    entity_keys = MapSet.new(window.entities, & &1.key)
    ledger = arcs |> Enum.flat_map(& &1.edges) |> Enum.map(&edge_tuple/1)
    projected = Enum.map(projected_edges, &edge_tuple/1)

    valid_arc_assignments? =
      Enum.all?(arcs, fn arc ->
        is_binary(arc.from) and is_binary(arc.to) and
          MapSet.member?(entity_keys, arc.from) and MapSet.member?(entity_keys, arc.to) and
          Enum.all?(arc.edges, fn edge ->
            assignment[edge["from"]] == arc.from and assignment[edge["to"]] == arc.to
          end)
      end)

    arc_keys = MapSet.new(arcs, &{&1.from, &1.to})
    unique_arc_keys? = MapSet.size(arc_keys) == length(arcs)

    valid_arc_assignments? and unique_arc_keys? and
      length(ledger) == length(Enum.uniq(ledger)) and
      MapSet.new(ledger) == MapSet.new(projected)
  end

  def entity_keys(window), do: Enum.map(window.entities, & &1.key)

  defp allocate_buckets(waves, indexes) do
    initial =
      indexes
      |> Enum.filter(&(Enum.at(waves, &1) != []))
      |> Map.new(&{&1, 1})

    slots = List.duplicate(:slot, 6 - length(indexes))

    Enum.reduce_while(slots, initial, fn :slot, buckets ->
      candidate =
        indexes
        |> Enum.filter(fn wave ->
          Map.has_key?(buckets, wave) and buckets[wave] < length(Enum.at(waves, wave))
        end)
        |> Enum.reduce(nil, fn
          wave, nil ->
            wave

          wave, best ->
            wave_units = length(Enum.at(waves, wave))
            best_units = length(Enum.at(waves, best))

            if wave_units * buckets[best] > best_units * buckets[wave],
              do: wave,
              else: best
        end)

      if is_nil(candidate) do
        {:halt, buckets}
      else
        {:cont, Map.update!(buckets, candidate, &(&1 + 1))}
      end
    end)
  end

  defp wave_entity(waves, wave, bucket, bucket_count) do
    ids = Enum.at(waves, wave)
    quotient = div(length(ids), bucket_count)
    remainder = rem(length(ids), bucket_count)
    size = quotient + if(bucket < remainder, do: 1, else: 0)
    offset = bucket * quotient + min(bucket, remainder)

    %{
      key: "wave:#{wave}:bucket:#{bucket}",
      kind: :cluster,
      members: Enum.slice(ids, offset, size)
    }
  end

  defp entity_assignment(window) do
    for entity <- window.entities, id <- entity.members, into: %{} do
      {id, entity.key}
    end
  end

  defp edge_tuple(edge), do: {edge["from"], edge["to"], edge["state"]}
end
