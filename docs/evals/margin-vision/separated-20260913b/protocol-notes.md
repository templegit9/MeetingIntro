# Corrected reading/planning comparison

Unadapted, epoch 1, epoch 2 and epoch 3 run serially. Each uses 43 reading probes, 10 direct image-to-native-plan probes, 10 plans from its own extracted facts, 10 plans from annotated facts, and the full 96-request language regression plus excluded deterministic dispatch. Total: 676 model requests.

Reader and planner run in fresh conversations. Verified facts are supplied only in the explicitly labelled gold-planner arm. The predicted-facts arm consumes the reader output, including uncertainty; invalid extraction is passed as unavailable evidence, never replaced with annotated answers. No native tools execute.

The earlier separated-20260913 partial run is retained. Its inner-facts-only schema conflicted with the outer response format, producing correct bare fact objects that failed the envelope contract. This new manifest provides the complete response schema. Earlier scores are not transferred or regraded into this run.

Nine newly rendered documents and one missing-image control supplement the previously audited screen. This is synthetic evidence, not a real-photo benchmark. The current text Pilot 1 remains unchanged; cross-model reader-to-Pilot-1 planning, image save/write contracts, independent real-image validation and Mac packaging remain separate follow-ups.
