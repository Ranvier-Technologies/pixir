# Delegate transport intent reaches child Providers

Delegate already accepted `transport` and `subagents.transport`, but placed the
resolved value at the top level of Subagent spawning options. Manager consumes
`provider_opts`, so real children could silently use an inherited/default transport
despite a different dry-run plan. Workflow dispatch also omitted this forwarding.

The selected transport now reaches nested Provider options for both strategies.
Explicit spec intent overrides the inherited transport while preserving unrelated
Provider options; omission leaves inherited/default behavior alone. The existing
precedence of `subagents.transport` over top-level `transport` is unchanged.

Regressions drive real Runner/Manager/Turn/Workflow paths with an injected Provider,
not only a spawn stub: shared, isolated and `virtual_overlay` children, both transport
locations, inheritance and absence. No network is needed for this verification.
Transport policy itself, authentication, workspace permissions and prompt versions
are unchanged.

This corrects plan-versus-execution drift; an accepted dry-run alone was not proof
that a live child used the requested transport. Live claims must be checked against
canonical `provider_usage.active_transport` evidence.
