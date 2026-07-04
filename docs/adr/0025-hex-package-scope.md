# 25. Hex package scope is CLI/ACP-only until public Elixir APIs are explicit

Date: 2026-06-19
Status: Accepted
Implementation status: Accepted package scope for the first Hex release. This ADR
defines the distribution contract before and after initial publication.

## Context

ADR 0016 intentionally deferred Hex publication. Pixir's source-install beta is now
usable for a local operator through the CLI and ACP, but publishing to Hex would create
a public distribution contract. That contract is easy to overstate: a Hex package can
look like a stable Elixir library even when the intended product surface is an escript
and an ACP server.

Pixir already has much of the mechanical Hex metadata in `mix.exs`: `app`, `version`,
`description`, `package`, `licenses`, `links`, `docs`, dependencies from Hex, and an
escript configuration. Release candidates are verified by package build and unpack
checks before publication. The remaining question is not "can Hex build a tarball?" but
"what public contract does that tarball imply?"

## Decision

**1. Hex scope is CLI/ACP-only.** The Hex package is a distribution path for installing
and running Pixir as a local tool:

```bash
mix escript.install hex pixir
pixir doctor --json
pixir acp
```

It does not promise a stable public Elixir library API.

**2. Public API promise stays narrow.** The stable surface for a first Hex release is:

- CLI behavior documented in README and quickstart docs;
- ACP over stdio;
- local diagnostics such as `pixir doctor --json`;
- documented local file/log behavior and security boundaries.

Internal modules under `Pixir.*` may be documented for transparency, but are not stable
extension points until a later ADR explicitly marks them public.

**3. Hex ownership is explicit and separate from GitHub.** Package ownership is a
release-governance decision and is not implied by the GitHub repository owner.

**4. Package contents must be curated before publishing.** The first publication should
not rely only on Hex defaults. The package should explicitly include runtime and public
documentation files and exclude local agent instructions, scratch artifacts, benchmark
state, generated docs, and local runtime state.

**5. A GitHub Release binary may still precede Hex.** Hex is useful for Elixir-native
installation, but it is not the only way to improve operator ergonomics. A prebuilt
binary release can remain the lower-API-commitment path if package API boundaries are
not ready.

## Consequences

- Hex is no longer blocked on the idea that every `Pixir.*` module must be stable.
- The first package can be judged as a CLI/ACP install surface rather than as a library.
- Docs and ExDoc must clearly say which surfaces are stable and which are internal.
- `mix.exs` should get explicit package file curation before publication.
- Ownership is a release decision, not an accident of whoever runs `mix hex.publish`.

## Non-goals

- Do not publish in this ADR.
- Do not claim a stable public Elixir API.
- Do not imply packaged client integration beyond ACP stdio.
- Do not add telemetry, self-update, MCP, web UI, multi-provider support, or SLA promises.
- Do not treat a successful `mix hex.build` as sufficient for publication readiness.

## Verification Direction

Before any Hex publication, the release candidate should pass:

```bash
mix check
mix docs --warnings-as-errors
mix hex.publish --dry-run
mix hex.build --unpack
mix escript.build
./pixir doctor --json
```

The unpacked package must be inspected for:

- no local runtime state (`.pixir`, `_build`, `deps`, `tmp`, generated `doc`);
- no local/private agent scaffolding;
- no secrets or machine-specific paths;
- expected README, LICENSE, `mix.exs`, runtime `lib`, and public docs;
- install instructions for `mix escript.install hex pixir`;
- clear CLI/ACP-only API stability wording.

After publication, test installation in a fresh project/shell:

```bash
mix escript.install hex pixir
pixir --version
pixir doctor --json
pixir acp
```

## References

- ADR 0016: open beta scope and developer-preview support boundary.
- ADR 0017: minimal Harness core and Presenter boundary.
- Hex publishing guide: https://hex.pm/docs/publish
- `mix hex.publish`: https://hex.hexdocs.pm/Mix.Tasks.Hex.Publish.html
- `mix escript.install`: https://mix.hexdocs.pm/main/Mix.Tasks.Escript.Install.html
