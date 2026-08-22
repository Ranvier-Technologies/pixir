defmodule PixirMonitor.UI.GlossaryDeliveryContractTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Pins the onboarding glossary's DELIVERY decision and its anti-rot property.

  The glossary ships INLINE, as a generated frozen literal in the app.js
  bundle, not as a served `/assets/glossary.json`. That choice is what makes
  this test cheap: both sides of the comparison are CHECKED-IN artifacts, so
  the drift check runs with `Jason` alone and needs no Python, no network, and
  no generator invocation inside `mix test`.

  The generated block's array payload is deliberately STRICT JSON as well as a
  valid JavaScript array literal, so drift is detected STRUCTURALLY (decode
  both, compare terms) rather than by brittle whole-string equality that any
  reindentation would break.
  """

  @app_js Path.expand("../../priv/static/app.js", __DIR__)

  # The corpus side of the comparison, emitted by gen_terms.py into the monitor
  # tree rather than read out of `.docs/`.
  #
  # The boundary is load-bearing, not stylistic. `.docs/scripts/sync-mirror.sh`
  # removes `.docs` wholesale as a curation exclusion and fail-closes if it
  # survives, while everything else -- monitor/ and the CI workflow that runs
  # this suite with `--warnings-as-errors` -- DOES reach the public mirror.
  # Reading `.docs/.../terms.json` from here therefore passes in this repo and
  # raises `File.Error` inside `setup_all` on the mirror, invalidating every test
  # in this module, the injection-refusal check included. A drift test that only
  # runs where the corpus happens to be present is not evidence anywhere else.
  #
  # So gen_terms.py writes the identical bytes twice, in one write phase from one
  # build(): terms.json for the handoff, this fixture for the monitor. Both sides
  # compared here remain checked-in and the check stays Jason-only, with no
  # Python in `mix test`.
  @terms_json Path.expand("../fixtures/glossary_terms.json", __DIR__)

  # The handoff's OWN copy -- the artifact T1 froze and that COMPARISON.md,
  # DESIGN.md and downstream tasks quote by byte.
  #
  # Moving the drift comparison onto the monitor fixture (correctly, for the
  # mirror-boundary reason above) silently dropped this third copy out of every
  # assertion: `terms.json` could be hand-edited and the whole suite stayed
  # green, so "neither copy can rot alone" was only two-thirds true. The parity
  # test below closes that, and it is PRESENCE-CONDITIONAL rather than a plain
  # `File.read!`: on the public mirror `.docs` is gone by design, and a hard read
  # would raise inside `setup_all` and take every test in this module down --
  # exactly the failure the fixture move existed to prevent. Present means
  # compared; absent means the artifact is out of scope here, never a silent
  # pass where the file exists.
  @handoff_terms_json Path.expand(
                        "../../../.docs/design-handoffs/pixir-monitor-onboarding/research/terms.json",
                        __DIR__
                      )

  @begin_marker "  // GENERATED BEGIN pixir-monitor-glossary -- gen_terms.py; do not hand-edit."
  @end_marker "  // GENERATED END pixir-monitor-glossary"

  # Every line the generator emits between the markers ahead of the payload,
  # verbatim from gen_terms.py's `glossary_block`. Pinned as literals because
  # the region is a "do not hand-edit" block: anything in it that is not
  # DERIVED from the corpus must be exactly what the generator wrote, or the
  # block has been hand-edited and the extraction is not evidence of anything.
  @preamble [
    "  // Delivered INLINE rather than as a served asset: see gen_terms.py's",
    "  // delivery-decision note. Regenerate with `uv run python gen_terms.py .`",
    "  // from .docs/design-handoffs/pixir-monitor-onboarding/research/."
  ]

  @freeze_open "  const GLOSSARY = Object.freeze("

  # The generator's LAST region line, verbatim: the payload's closing bracket
  # (indented by `glossary_block`'s two-space body reindent) plus the freeze
  # call's `);`. Pinned as an exact line so the region's tail is asserted the
  # same way its prelude is -- by CONTENT -- rather than by a property of its
  # final bytes.
  @freeze_close "  ]);"

  @keys ["term", "surface_string", "code_citation", "plain_definition", "confused_with", "slug", "concern"]

  setup_all do
    {:ok, js: File.read!(@app_js), terms: Jason.decode!(File.read!(@terms_json))}
  end

  @doc false
  # Extracts the generated glossary from a JavaScript bundle's SOURCE.
  #
  # Exposed as a function (not inlined into one test) precisely so the
  # mutation tests below can run the very same extractor over a deliberately
  # corrupted copy and watch it go red. A check that is never proven to bite is
  # not evidence.
  #
  # The region is consumed WHOLE, front to back, and every one of its bytes must
  # land in exactly one of two buckets: a literal the generator is known to emit
  # (`@preamble`, `@freeze_open`, `@freeze_close`) or the JSON payload compared
  # against terms.json. Nothing is skipped over.
  #
  # That totality is the whole point, and it is the property an earlier version
  # of this extractor lacked. Splitting the region on the freeze call and
  # keeping only the half after it pinned the TAIL alone: `);` refused trailing
  # junk, so hand-edits after the array were caught, but everything between the
  # BEGIN marker and the freeze call was discarded unread. A statement injected
  # there (`document.cookie;`, `fetch('/bootstrap',{method:'POST'});`,
  # `window.PixirMonitorUI=1;` overriding the exported seam) still decoded to a
  # corpus byte-identical to terms.json, so the suite reported full parity for a
  # bundle that had been hand-edited inside the "do not hand-edit" block and
  # whose injected line the browser would execute. The asymmetry was the trap:
  # one guarded side made the check look total while half the region was open.
  #
  # So the shape is asserted line by line rather than searched for. A drift test
  # over a generated region is only evidence about the region it read ALL of.
  def extract_glossary(js) do
    lines = String.split(js, "\n")
    begins = Enum.count(lines, &(&1 == @begin_marker))
    ends = Enum.count(lines, &(&1 == @end_marker))

    with true <- begins == 1,
         true <- ends == 1,
         begin_index when is_integer(begin_index) <- Enum.find_index(lines, &(&1 == @begin_marker)),
         end_index when is_integer(end_index) <- Enum.find_index(lines, &(&1 == @end_marker)),
         true <- begin_index < end_index,
         region <- Enum.slice(lines, (begin_index + 1)..(end_index - 1)),
         {:ok, payload} <- strip_generated_prelude(region),
         {:ok, trimmed} <- strip_call_suffix(payload),
         {:ok, decoded} <- Jason.decode(trimmed) do
      {:ok, decoded}
    else
      _ -> {:error, :no_generated_glossary}
    end
  end

  # Consumes the generator's fixed prelude off the FRONT of the region: the
  # three delivery-decision comment lines, then the freeze call's opening line.
  # Returns only what follows the `Object.freeze(` on that line, joined with the
  # rest of the region's lines, so the caller's tail check and JSON decode
  # between them account for every remaining byte.
  defp strip_generated_prelude(@preamble ++ [freeze_line | rest]) do
    case String.starts_with?(freeze_line, @freeze_open) do
      true ->
        head = binary_part(freeze_line, byte_size(@freeze_open), byte_size(freeze_line) - byte_size(@freeze_open))
        {:ok, [head | rest]}

      false ->
        {:error, :unexpected_freeze_line}
    end
  end

  defp strip_generated_prelude(_region), do: {:error, :hand_edited_generated_region}

  # Consumes the freeze call's closing line off the BACK, by exact equality
  # against the one line `glossary_block` emits there.
  #
  # Equality rather than `String.ends_with?(joined_region, ");")`. Both refuse a
  # same-line append after the `);` -- an injected `document.cookie;` fails the
  # suffix outright, and one that does end in `);` (`fetch(...)`, `Function(...)`)
  # leaves `]); fetch(...` as trailing garbage that `Jason.decode/1` rejects --
  # so this is a hardening, not a hole being plugged. It is worth making anyway:
  # under the suffix form that refusal depends on a downstream decoder's
  # strictness about trailing bytes, which is a property of Jason rather than a
  # statement about the generated region. Equality pins the tail the same way
  # @preamble pins the front, so BOTH ends of a "do not hand-edit" block are
  # asserted to be exactly what the generator wrote and neither leans on the
  # other's leftovers. The `injections` loop proves each shape is refused.
  #
  # No trimming, either: a trailing whitespace line after the call is still a
  # hand-edit in a generated block, and whitespace is how one would be smuggled
  # past a reviewer. `Jason.decode/1` tolerates the payload's own surrounding
  # whitespace, so nothing needs trimming here.
  #
  # The closing line is put back as its payload half -- @freeze_close minus the
  # trailing `);` -- rather than as a bare "]", so the bytes handed to the
  # decoder are the generator's own, indentation included, and the two literals
  # cannot drift apart if the generator's indent ever changes.
  defp strip_call_suffix(lines) do
    case List.pop_at(lines, -1) do
      {@freeze_close, body_lines} ->
        closing = binary_part(@freeze_close, 0, byte_size(@freeze_close) - 2)
        {:ok, Enum.join(body_lines ++ [closing], "\n")}

      _ ->
        {:error, :unterminated_freeze_call}
    end
  end

  test "the generated app.js block is byte-recoverable and decodes as strict JSON", %{js: js} do
    assert {:ok, glossary} = extract_glossary(js)
    assert is_list(glossary)
    assert length(glossary) == 56

    for entry <- glossary do
      assert Enum.sort(Map.keys(entry)) == Enum.sort(@keys)
      assert Enum.sort(Map.keys(entry["concern"])) == ["blurb", "key", "title"]
    end
  end

  test "the generated block does not drift from the checked-in terms.json", %{js: js, terms: terms} do
    assert {:ok, glossary} = extract_glossary(js)

    assert glossary == terms,
           "the app.js glossary block and research/terms.json disagree; regenerate with " <>
             "`uv run python gen_terms.py .` from " <>
             ".docs/design-handoffs/pixir-monitor-onboarding/research/"
  end

  test "the handoff's terms.json has not rotted away from the monitor fixture" do
    # BYTE equality, not decoded equality: gen_terms.py writes the identical
    # bytes to both paths in one write phase, so any difference at all -- a
    # reordered key, a reindent, a hand-edited term -- means one copy was
    # touched outside the generator and the handoff no longer says what the
    # bundle ships.
    if File.exists?(@handoff_terms_json) do
      assert File.read!(@handoff_terms_json) == File.read!(@terms_json),
             "research/terms.json and the monitor fixture disagree; one of them was " <>
               "hand-edited. Regenerate both with `uv run python gen_terms.py .` from " <>
               ".docs/design-handoffs/pixir-monitor-onboarding/research/"
    else
      # The mirror, where `.docs` is a curation exclusion. Nothing to compare.
      assert true
    end
  end

  test "the drift check bites: a mutated copy of the bundle goes red", %{js: js, terms: terms} do
    # Red-proof (the #362 idiom). Each mutation is a realistic way the block
    # could rot, and the extractor must refuse or disagree for every one of
    # them. A green suite is only evidence if these are red.
    # `~s|...|` throughout, never `~s(...)`: a paren-delimited sigil balances
    # the parens in its own body, so a mutation string containing one would end
    # the sigil early and break this file's parse.
    mutated_value = String.replace(js, ~s|"slug": "liveness"|, ~s|"slug": "liveness-typo"|, global: false)
    assert mutated_value != js
    assert {:ok, drifted} = extract_glossary(mutated_value)
    refute drifted == terms

    dropped_entry =
      String.replace(js, ~s|"term": "Liveness"|, ~s|"term": "Liveness (edited by hand)"|, global: false)

    assert dropped_entry != js
    assert {:ok, edited} = extract_glossary(dropped_entry)
    refute edited == terms

    # A hand-edit that breaks the JSON payload must fail extraction outright
    # rather than silently comparing a partial corpus.
    broken_json = String.replace(js, ~s|"slug": "liveness"|, ~s|slug: "liveness"|, global: false)
    assert broken_json != js
    assert {:error, :no_generated_glossary} = extract_glossary(broken_json)

    # Marker loss, duplication, and inversion are all refusals, never a guess.
    assert {:error, :no_generated_glossary} = extract_glossary(String.replace(js, @begin_marker, "  // gone"))
    assert {:error, :no_generated_glossary} = extract_glossary(String.replace(js, @end_marker, "  // gone"))

    duplicated_marker = Enum.join([@begin_marker, @begin_marker], "\n")
    assert {:error, :no_generated_glossary} = extract_glossary(String.replace(js, @begin_marker, duplicated_marker))

    inverted = String.replace(js, @begin_marker, "\0BEGIN\0") |> String.replace(@end_marker, @begin_marker)
    inverted = String.replace(inverted, "\0BEGIN\0", @end_marker)
    assert {:error, :no_generated_glossary} = extract_glossary(inverted)
  end

  test "hand-injected code anywhere in the generated region is refused, on BOTH sides of the payload",
       %{js: js} do
    # The specific hole this pins closed. An extractor that searches for the
    # freeze call and reads only what follows it reports full parity for every
    # statement below: the corpus it decodes is byte-identical to terms.json
    # while the shipped bundle carries a line the browser executes, inside the
    # block whose own marker says do not hand-edit.
    #
    # These are not decorative payloads. `document.cookie` and a POST to
    # /bootstrap (the monitor's one security-state-transition route) are what an
    # injection into this bundle would actually be FOR; `Function(...)` is the
    # eval path the corpus scan below bans in the corpus but cannot see here;
    # and assigning `window.PixirMonitorUI` overrides the very seam the accessor
    # contracts assert against, so an injection could satisfy those tests too.
    injections = [
      ~s|  document.cookie;|,
      ~s|  fetch('/bootstrap',{method:'POST'});|,
      ~s|  const f=Function; f('return 1')();|,
      ~s|  window.PixirMonitorUI=1;|,
      ~s|  // a comment is not generated output either|,
      ~s||
    ]

    for injection <- injections do
      before_payload = String.replace(js, @freeze_open, injection <> "\n" <> @freeze_open, global: false)

      assert before_payload != js, "injection #{inspect(injection)} did not apply"

      assert {:error, :no_generated_glossary} = extract_glossary(before_payload),
             "code injected BEFORE the freeze call survived extraction: #{inspect(injection)}"

      after_payload = String.replace(js, "\n" <> @end_marker, "\n" <> injection <> "\n" <> @end_marker, global: false)

      assert after_payload != js, "injection #{inspect(injection)} did not apply after the payload"

      assert {:error, :no_generated_glossary} = extract_glossary(after_payload),
             "code injected AFTER the payload survived extraction: #{inspect(injection)}"

      # And on the closing line ITSELF, appended after the `);` -- the one
      # placement the whole-line mutations above cannot reach, since both of
      # them insert NEW lines. Line-granular totality does not imply
      # character-granular totality, so the last line gets its own case.
      #
      # Anchored to the END marker, not matched loosely: `  ]);` closes other
      # frozen literals earlier in the bundle (SEVERITY_ORDER at :50 among
      # them), so a first-match replace would mutate a line OUTSIDE the region
      # and the extractor would rightly still return {:ok, terms} -- a green
      # assertion proving nothing about the tail.
      same_line =
        String.replace(
          js,
          @freeze_close <> "\n" <> @end_marker,
          @freeze_close <> " " <> String.trim(injection) <> "\n" <> @end_marker,
          global: false
        )

      assert same_line != js, "injection #{inspect(injection)} did not apply on the closing line"

      assert {:error, :no_generated_glossary} = extract_glossary(same_line),
             "code injected ON the closing line survived extraction: #{inspect(injection)}"
    end

    # The prelude is pinned by CONTENT, not merely by line count: a rewritten
    # comment line is a hand-edit even though it keeps the region's shape.
    rewritten_prelude =
      String.replace(
        js,
        "  // Delivered INLINE rather than as a served asset: see gen_terms.py's",
        "  // Delivered INLINE rather than as a served asset: see somewhere else",
        global: false
      )

    assert rewritten_prelude != js
    assert {:error, :no_generated_glossary} = extract_glossary(rewritten_prelude)

    # And the freeze call's own line must be the generator's, not a lookalike
    # that smuggles a statement in ahead of it on the same line.
    smuggled_line = String.replace(js, @freeze_open, "  document.cookie; " <> @freeze_open, global: false)

    assert smuggled_line != js
    assert {:error, :no_generated_glossary} = extract_glossary(smuggled_line)
  end

  test "every slug is unique and every concern key resolves to one record", %{js: js} do
    assert {:ok, glossary} = extract_glossary(js)

    slugs = Enum.map(glossary, & &1["slug"])
    assert length(Enum.uniq(slugs)) == length(slugs)
    assert Enum.all?(slugs, &(&1 =~ ~r/^[a-z0-9]+(-[a-z0-9]+)*$/))

    concerns = glossary |> Enum.map(& &1["concern"]) |> Enum.uniq()
    assert length(concerns) == 8
    assert length(Enum.uniq(Enum.map(concerns, & &1["key"]))) == 8
  end

  test "the accessor seam is defined and exported for the manual pane", %{js: js} do
    assert js =~ "function glossaryEntries()"
    assert js =~ "function glossaryBySlug(slug)"
    assert js =~ "function glossaryConcerns()"

    assert js =~ "glossaryEntries: glossaryEntries"
    assert js =~ "glossaryBySlug: glossaryBySlug"
    assert js =~ "glossaryConcerns: glossaryConcerns"

    # Synchronous by construction: the seam never awaits and never fetches. The
    # assertion targets a FETCH of a glossary asset, not the substring, because
    # the delivery-decision comment names the rejected /assets/glossary.json on
    # purpose and that prose must stay readable.
    refute js =~ ~r/fetch\([^)]*glossary/i
    refute js =~ ~r|"/assets/glossary|
    refute js =~ "async function glossary"
    refute js =~ "await glossary"
  end

  test "the inline delivery decision left the four served-asset surfaces untouched" do
    assets = File.read!(Path.expand("../../lib/pixir_monitor/assets.ex", __DIR__))
    router = File.read!(Path.expand("../../lib/pixir_monitor/router.ex", __DIR__))
    self_check = File.read!(Path.expand("../../lib/pixir_monitor/self_check.ex", __DIR__))

    # The served-asset option would have required a clause, a route, and a
    # verify_asset link for a third asset. It was rejected; none exist.
    refute assets =~ "glossary"
    refute router =~ "glossary"
    refute self_check =~ "glossary"

    assert assets =~ ~s|def fetch("app.js"), do:|
    assert assets =~ ~s|def fetch("app.css"), do:|
    refute assets =~ ~s|def fetch("glossary|
  end

  test "the generated block introduces no forbidden sink and no executable payload", %{js: js} do
    assert {:ok, glossary} = extract_glossary(js)
    corpus = Jason.encode!(glossary)

    for sink <- ["innerHTML", "insertAdjacentHTML", "DOMParser", "document.write", "eval(", "Function("] do
      refute String.contains?(corpus, sink), "the glossary corpus carries the forbidden sink #{sink}"
    end

    # Characters that are legal JSON but illegal in a JavaScript source literal
    # would produce a bundle that does not parse. gen_terms.py fail-stops on
    # them; this is the checked-in proof that none survived.
    refute String.contains?(corpus, "\u2028")
    refute String.contains?(corpus, "\u2029")
    refute String.contains?(corpus, "</script")
  end
end
