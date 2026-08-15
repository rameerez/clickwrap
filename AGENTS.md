# Agent instructions

This repository is in a documentation-first product-definition phase.

Before changing anything, read in full:

- `docs/PRD.md`
- every file in `docs/research/`
- every file in `docs/decisions/`
- every file in `docs/strategy/`

Until the PRD is explicitly approved:

- do not add a gemspec, `lib/`, Rails engine, generator, migration, CI workflow, or implementation test;
- do not create a GitHub repository, push a branch, publish or reserve a gem name, or contact any third party;
- preserve the distinction between law, cases, regulator guidance, technical standards, vendor claims, pinned source-code observations, and product-design inferences;
- add an exact, direct URL for every new external factual or legal claim;
- pin source-code citations to immutable commits rather than moving branches;
- never describe the project as guaranteeing enforceability, compliance, audit acceptance, identity, trusted time, a qualified electronic signature, or legal advice.

Engineering values inherited from the surrounding gem ecosystem are: idiomatic Ruby and Rails, a small public API, one annotated configuration block, server-owned security decisions, adaptive generators, host-owned UI escape hatches, Minitest, Appraisal matrices, SimpleCov, RuboCop, and minimal runtime dependencies. These are proposed constraints until the PRD is approved; their evidence is in `docs/research/01-ecosystem.md`.
