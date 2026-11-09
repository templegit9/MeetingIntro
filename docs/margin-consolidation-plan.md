# Margin feature consolidation

2026-09-13. Scope: margin branch; local installation, no master merge or public release.

## Effects and decisions

| Order | Effect | Decision |
| --- | --- | --- |
| First | Removing Plugins changes navigation and discovery. | Margin gets a dedicated Settings destination and entry in both menu-bar layouts. Ticker lives under Reminders; Camera Cover under In-Meeting. |
| First | Dictionary is not currently in Margin's registry. | Add define_word backed by the existing dictionary service; render definitions, examples and spelling suggestions in the notebook. |
| First | Files need more review space than a narrow page. | Keep the existing preview editor as Margin · Files, reached from Margin settings and the notebook spine menu. Preserve preview, confirmation and undo. |
| Second | Moving controls can accidentally reset switches or strand jobs. | Reuse existing preference keys, jobs, grants and review-window ID. File automation remains independently controlled under Margin. |
| Second | A typo or offline model must not block a simple lookup. | Route explicit definitions and single-word lookups directly; try the system dictionary first. Unknown words show spelling suggestions without silently substituting. |
| Second | Existing schedules may use a separately configured model. | Keep its model configuration and explain its ownership; do not silently switch providers or download a model. |
| Third | Margin becomes the umbrella, so claims must match callable tools. | Capability listing derives from the registry. A files workspace is distinguished from notebook tool calls. |
| Third | Consolidation could couple unrelated background behavior to AI. | Ticker, camera reminders and existing file jobs remain independently enabled. Margin activation retains its introduction and setup consent. |
| Third | Old shortcuts/window identities may be relied on by users or review notifications. | Retain legacy window IDs as compatibility entry points, relabel them under Margin; remove public plugin tiles/footer links. |

## Execution

1. Replace plugin grid with Margin activation/configuration and Files access; relocate Ticker/Camera Cover controls.
2. Add dictionary tool and direct dispatch, including offline definitions and spelling guidance.
3. Add menu-bar Margin access, preserve setup consent and existing persistent state.
4. Verify routing and dictionary behavior deterministically, build/sign, inspect native navigation, install locally.

## Acceptance

No Plugins sidebar item. Margin, Ticker and Camera Cover have usable destinations. All previous preferences remain intact. Dictionary requests do not need model inference; unknown spelling never causes a write. Files still use existing preview and undo. A signed build passes and remaining native verification limits are recorded.

## Verification findings

- Routing checks pass for explicit definitions and bare words, while help/cancel/undo and multiword action requests remain outside dictionary dispatch.
- A real macOS offline lookup of “onomatopoeia” passed without model inference.
- macOS returned no spelling suggestions for the screenshot’s exact “Oneumatopia”. In that case the notebook explains that no definition was found and asks for spelling/context; it does not invent a correction. Suggestions are shown when the spell checker supplies them.
- One Release compile failed on a complex dictionary-formatting expression; replaced with explicit loops before rebuilding.

## Installed outcome

Build 202609130150 signed and installed locally. Native Margin settings rendered and inspected; sidebar has no Plugins item. Ticker and Camera Cover destinations expose their existing independent switches/configuration. Margin · Files was observed with existing jobs, rules and undo records. Dictionary routing/offline checks passed. No live file changes or reminder delivery was exercised, and no full model eval was rerun. The disabled-Margin setup link and both menu-bar entry paths still need end-to-end UI exercise. See `evals/margin-consolidation/verification.json`.
