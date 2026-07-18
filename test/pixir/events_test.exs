defmodule Pixir.EventsTest do
  use ExUnit.Case, async: false

  alias Pixir.{Conversation, Event, Events}

  setup do
    # Unique session id per test so duplicate-keyed Registry entries don't leak.
    %{sid: "test-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}
  end

  test "subscriber receives published events for its session", %{sid: sid} do
    :ok = Events.subscribe(sid)
    event = Event.status(sid, "thinking")

    assert ^event = Events.publish(event)
    assert_receive {:pixir_event, ^event}
  end

  test "events are isolated by session_id", %{sid: sid} do
    :ok = Events.subscribe(sid)
    Events.publish(Event.status("other-session", "noise"))

    refute_receive {:pixir_event, _}, 50
  end

  test "unsubscribe stops delivery", %{sid: sid} do
    :ok = Events.subscribe(sid)
    :ok = Events.unsubscribe(sid)

    Events.publish(Event.status(sid, "thinking"))
    refute_receive {:pixir_event, _}, 50
  end

  test "subscriber can filter by event type", %{sid: sid} do
    :ok = Events.subscribe(sid, only: [:status])

    Events.publish(Event.text_delta(sid, "noise"))
    refute_receive {:pixir_event, _}, 50

    event = Event.status(sid, "thinking")
    Events.publish(event)
    assert_receive {:pixir_event, ^event}
  end

  test "subscriber_count reflects registrations", %{sid: sid} do
    assert Events.subscriber_count(sid) == 0
    :ok = Events.subscribe(sid)
    assert Events.subscriber_count(sid) == 1
  end

  test "invalid Session ids are refused before event Registry operations" do
    hostile = "../events-registry;PWN"

    for result <- [
          Events.subscribe(hostile),
          Conversation.subscribe(hostile),
          Events.unsubscribe(hostile),
          Events.subscriber_count(hostile),
          Events.publish(Event.status(hostile, "must not dispatch"))
        ] do
      assert {:error, %{error: %{kind: :invalid_args}} = error} = result
      refute inspect(error) =~ hostile
    end

    assert Registry.lookup(Pixir.Events.Registry, hostile) == []

    # Register directly only as an observation seam: a missing validation in
    # publish/1 would dispatch to this otherwise-unreachable hostile key.
    assert {:ok, _owner} =
             Registry.register(Pixir.Events.Registry, hostile, %{only: :all})

    assert {:error, %{error: %{kind: :invalid_args}}} =
             Events.publish(Event.status(hostile, "still must not dispatch"))

    refute_receive {:pixir_event, _event}, 50
    Registry.unregister(Pixir.Events.Registry, hostile)
  end
end
