# Margin image workflow evaluation

Developer-only. No consumer eval UI. No native OCR; candidates must receive image pixels.

This pack separates a runnable synthetic screening set from a full workflow coverage backlog. Synthetic passes are not real-photo, native app, execution, or 16 GB qualification.

Commands (Python 3.10+; macOS Swift/AppKit needed only to regenerate PNG fixtures):

```
python scripts/margin-vision-eval/build_suite.py
python scripts/margin-vision-eval/eval.py validate
python scripts/margin-vision-eval/test_eval.py
python scripts/margin-vision-eval/eval.py report
```

`eval.py grade --responses responses.jsonl --label candidate-name` evaluates externally captured normalized responses, not live model calls. Each line needs `case_id`, `repeat`, `started_at`, `finished_at`, `architecture`, `models` (exact IDs/digests), `latency_seconds`, and either `output` or `infrastructure_error`. Output contains `facts` (a task-specific object), `disposition` (`answer`, `propose`, `clarify`, `grant_required`, `unsupported`), `operations` (ordered names), `destination` (string or null), `filename` (string or null), `confirmed` (must be false), `uncertainties` (array), `answer` (string), and `citations` (array). Preserve raw model responses separately; manual rubric review remains required. Grade never runs file/calendar tools.

The grader only verifies explicitly annotated fields. It reports automated screening passes, never a release pass or an end-to-end accuracy claim. Missing outputs, pending review, infra failures and model failures remain separate. Repeats are three per case; duplicate/unknown case IDs are rejected. A JSON parse failure returned by a healthy model is a model failure, not infrastructure. Backend failures must include their raw evidence.

Read `docs/margin-vision-eval-plan.md` for full coverage, native checks, candidate protocol, gates and the training decision. Open `docs/evals/margin-vision/index.html` for the readable catalogue and latest run links.
