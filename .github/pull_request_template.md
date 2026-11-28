## What changes

<!-- One or two sentences: what this PR changes and why. -->

## Module(s)

- [ ] org
- [ ] inventory
- [ ] training
- [ ] booking
- [ ] service
- [ ] finance
- [ ] audit / roles / RLS
- [ ] report views
- [ ] indexes
- [ ] seed data / tests
- [ ] docs / diagrams
- [ ] tooling / CI (`run`, `tools/`, `.github/`)

## How it was tested

- [ ] `./run` (or `.\run`) finishes with every script `OK` and **all tests passing**
- [ ] new behaviour has a positive and a negative test in `tests/95_tests.sql`
- [ ] new or changed indexes are justified in `tests/96_explain.sql`
- [ ] `output/diagrams.html` checked: the relational diagrams show the change

<!-- Paste the summary block printed at the end of ./run: -->
```
tests       ... / ... passed
```

## Documentation

- [ ] `docs/design.md` updated (mapping, functional dependencies, normal forms, rules) if the schema changed
- [ ] EER (`docs/eer/build_eer.py`) updated if entities or relationships changed
- [ ] `README.md` updated if how to run or the module list changed

## Notes for the reviewer

<!-- Anything non-obvious: trade-offs, follow-ups, known limitations. -->
