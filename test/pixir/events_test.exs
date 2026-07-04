defmodule Pixir.EventsTest do
  use ExUnit.Case, async: false

  alias Pixir.{Event, Events}

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
end
