defmodule Pixir.SessionIdTest do
  use ExUnit.Case, async: true

  alias Pixir.{Session, SessionId}

  test "accepts generated, legacy, and Unicode-compatible Session ids" do
    valid = [
      Session.gen_id(),
      "sess-1",
      "legacy_name.v1",
      "utf8-load-acción",
      "a\u0301",
      "你42",
      "_",
      "9-start"
    ]

    for session_id <- valid do
      assert :ok = SessionId.validate(session_id), session_id
      assert SessionId.valid?(session_id)
    end
  end

  test "enforces the 235-byte filename-component budget including multibyte boundaries" do
    ascii_235 = "a" <> String.duplicate("b", 234)
    ascii_236 = ascii_235 <> "c"
    utf8_235 = "a" <> String.duplicate("é", 117)
    utf8_236 = String.duplicate("é", 118)

    assert byte_size(ascii_235) == 235
    assert byte_size(utf8_235) == 235
    assert :ok = SessionId.validate(ascii_235)
    assert :ok = SessionId.validate(utf8_235)

    for session_id <- [ascii_236, utf8_236] do
      assert {:error, %{error: %{kind: :invalid_args, details: %{"reason" => "too_long"}}}} =
               SessionId.validate(session_id)
    end
  end

  test "rejects traversal, separators, controls, shell syntax, and invalid UTF-8" do
    invalid = [
      "",
      ".",
      "..",
      "-leading",
      ".leading",
      "a/b",
      "a\\b",
      "a b",
      "a\n",
      "a\0b",
      "a:b",
      "a;$HOME",
      "a%2fb",
      <<255>>,
      :not_a_string
    ]

    for session_id <- invalid do
      assert {:error, %{error: %{kind: :invalid_args}}} = SessionId.validate(session_id)
      refute SessionId.valid?(session_id)
    end
  end

  test "invalid errors never echo, normalize, or decode the supplied value" do
    hostile = "../../../outside/PWN;$HOME%2fsecret"

    assert {:error, error} = SessionId.validate(hostile)
    rendered = inspect(error)

    refute rendered =~ hostile
    refute rendered =~ "outside"
    refute rendered =~ "PWN"
    assert error.error.details["field"] == "session_id"
    assert error.error.details["reason"] in ["invalid_start", "invalid_character"]
  end
end
