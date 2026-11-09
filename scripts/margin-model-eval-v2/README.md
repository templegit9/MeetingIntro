# Evaluator v2 audit

This is an offline replay evaluator, not a new inference run. It deliberately leaves
`scripts/margin-model-eval` and all historical manifests/raw outputs unchanged.

`policy.py` derives corrected fixtures with explicit severity metadata. It checks
that a date-only move does not invent a clock time, accepts the observed valid
uncertainty wording while still requiring both prices and citations, and classifies
negative memory fixtures as critical regardless of ID.

Run tests: `python3 -m unittest discover -s scripts/margin-model-eval-v2`.
`replay.py` writes a new audit directory and refuses to overwrite an existing one.
Its provenance captures source manifest/response hashes and evaluator hashes.
Do not mix replay scores with original frozen scores without labeling them.

The ambiguous “Thursday” fixture does not assert one exact destination day. It
checks the unambiguous no-invented-time invariant. These targeted fixes are not a
complete semantic judge. Further evaluator changes require versioned fixtures
and adversarial tests; do not change expectations simply to make a model pass.
