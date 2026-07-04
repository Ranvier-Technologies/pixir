defmodule Pixir.Provider.CacheTest do
  use ExUnit.Case, async: true

  alias Pixir.Provider.Cache

  test "metadata builds a bounded safe cache-family key" do
    assert {:ok, metadata} =
             Cache.metadata(%{
               session_id: "session-with-private-path-/Users/bastian/project",
               model: "gpt-5.5",
               mode: :build,
               tools: [%{"name" => "read"}, %{"name" => "bash"}],
               skill_index:
                 "<available_skills><skill><name>alpha</name></skill></available_skills>"
             })

    key = metadata["prompt_cache_key"]
    assert byte_size(key) <= 96
    assert key =~ "px3:"
    assert key =~ "m_gpt-5.5"
    assert key =~ "r_build"
    refute key =~ "/Users"
    refute key =~ "bastian"
    refute key =~ "alpha"
    assert byte_size(metadata["toolset_hash"]) == 16
    assert byte_size(metadata["skill_index_hash"]) == 16
  end

  test "key leads with the prompt-contract version and reports it in metadata" do
    assert {:ok, metadata} =
             Cache.metadata(%{
               session_id: "sid",
               model: "gpt-5.5",
               mode: :build,
               tools: [],
               skill_index: ""
             })

    version = Cache.prompt_contract_version()
    assert version == "px3"
    assert metadata["prompt_contract_version"] == version
    assert String.starts_with?(metadata["prompt_cache_key"], version <> ":")
  end

  test "forks sharing a fork-root session share the cache family" do
    base = %{model: "gpt-5.5", mode: :build, tools: [], skill_index: ""}

    {:ok, root} = Cache.metadata(Map.merge(base, %{session_id: "root-sid"}))

    {:ok, fork} =
      Cache.metadata(Map.merge(base, %{session_id: "fork-sid", fork_root_session_id: "root-sid"}))

    {:ok, unrelated} = Cache.metadata(Map.merge(base, %{session_id: "fork-sid"}))

    # The fork inherits the ROOT's family — identical key, identical s_ segment.
    assert fork["prompt_cache_key"] == root["prompt_cache_key"]
    assert fork["session_family_hash"] == root["session_family_hash"]

    # Without the fork-root, the same session id is its own (different) family.
    refute unrelated["session_family_hash"] == root["session_family_hash"]
  end

  test "blank fork-root falls back to the session id" do
    base = %{model: "gpt-5.5", mode: :build, tools: [], skill_index: ""}

    {:ok, plain} = Cache.metadata(Map.merge(base, %{session_id: "sid-a"}))

    {:ok, blank_root} =
      Cache.metadata(Map.merge(base, %{session_id: "sid-a", fork_root_session_id: ""}))

    assert blank_root["prompt_cache_key"] == plain["prompt_cache_key"]
  end

  test "metadata rejects missing required keys without raising" do
    assert {:error, :invalid_args} = Cache.metadata(%{model: "gpt-5.5"})
  end

  test "metadata cache key remains byte-bounded with multibyte input" do
    assert {:ok, metadata} =
             Cache.metadata(%{
               session_id: String.duplicate("sess-🛡️", 40),
               model: String.duplicate("gpt-🛡️", 40),
               mode: :build,
               tools: [],
               skill_index: ""
             })

    assert byte_size(metadata["prompt_cache_key"]) <= 96
    assert String.valid?(metadata["prompt_cache_key"])
  end

  test "stable_hash is independent of map insertion order" do
    left = %{"b" => 2, "a" => %{"z" => 9, "y" => 8}}
    right = %{"a" => %{"y" => 8, "z" => 9}, "b" => 2}

    assert {:ok, left_hash} = Cache.stable_hash(left)
    assert {:ok, right_hash} = Cache.stable_hash(right)
    assert left_hash == right_hash
  end

  test "stable_hash returns an error tuple for unsupported terms" do
    assert {:error, %Protocol.UndefinedError{}} = Cache.stable_hash(%{{:tuple, :key} => "bad"})
  end

  test "metadata degrades to :invalid_args on unhashable input, never a raw exception" do
    # A leaked exception struct crashed the Turn task via to_string/1; the contract
    # is the atom the caller can branch on.
    assert {:error, :invalid_args} =
             Cache.metadata(%{
               session_id: "sid",
               model: "gpt-5.5",
               mode: :build,
               tools: [%{{:tuple, :key} => "unhashable"}],
               skill_index: ""
             })
  end
end
