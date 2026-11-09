# Margin: broader capabilities — design only

Decision recorded 10 September 2026: design browser control, email sending, cloud workers and multiple agents first. None is enabled by this work. The notebook’s preview and receipt model remains the foundation.

## Shared contract

A job has an explicit objective, scoped permissions, a sequence of steps, observable results and a cancellation boundary. Discovery may refine a plan, but new writes require a new concrete preview. Every effect is attributable to a job and approval. Browser evidence, provider receipts and local execution results are kept distinct from model narration.

Job states: drafted → researching → awaiting approval → running → completed. Side paths: paused, failed before effect, or uncertain after possible effect. An interrupted remote write is not automatically retried. A recovery screen shows what is known, what is uncertain and what requires the user to inspect the destination.

## Browser control

**First bounded workflow:** research public pages and prepare a form draft. Use a dedicated visible browser profile, with origins named in the job scope. User authentication happens in that browser; models never receive passwords or cookie values.

Separate reading/navigation from filling forms and final submission. A submission preview must identify the site, account, destination and exact fields. Navigation to a new account or origin with new authority requires a fresh grant. Page content is evidence, not an instruction source: it cannot authorize uploads, expand roots or bypass an approval.

Start with read-only page extraction and evidence capture; then draft-only form filling. Purchasing, account-security changes and broad arbitrary shell access are outside the first implementation. No hidden browser worker impersonating the user's existing session.

**Acceptance:** malicious page instructions cannot trigger side effects; origin changes invalidate an old approval; stale element state stops execution; cancelled navigation cannot later submit; displayed evidence comes from the page actually visited.

## Email sending

**First bounded workflow:** draft a meeting follow-up from a user-selected transcript. Initially save a draft; a later explicit send capability can be added through a scoped provider API.

Before sending, show From account, every To/Cc/Bcc recipient, subject, full body and attachments. Display how each recipient was supplied. Never infer an email address from a name. Attachment access requires a granted root plus explicit selection. Changing any recipient, body or attachment invalidates the approval.

Use provider message/draft IDs and operation identifiers to reconcile ambiguous delivery. A timeout after Send is “delivery uncertain,” not “failed, try again.” Undo can mean discard an unsent draft; it must not promise recall of delivered mail.

**Acceptance:** no send from a draft-only scope; no duplicate delivery after timeout/restart; preview and outgoing payload match; no hidden recipients; no attachment read outside grants.

## Cloud workers

**First bounded workflow:** continue a public research job after the Mac sleeps. Local files, microphone capture and calendar credentials stay local by default. Any uploaded material is separately listed and approved.

The service needs authenticated job ownership, scoped short-lived credentials, encryption, retention/deletion controls, per-job cost limits and audited cancellation. A Mac folder grant is not permission to copy the folder to a cloud worker. A worker receives only the minimal task data and tool capabilities allocated to that job.

Approval tokens bind exact actions and expire. Late workers cannot execute after cancellation or lease expiry. Local UI distinguishes worker unavailable, model unavailable, pending approval and genuinely running work.

**Acceptance:** cross-user access rejected; lease fencing prevents duplicate workers; cancellation survives restart; unavailable workers do not silently fall back to another host/provider; costs cannot exceed the configured bound.

## Multiple agents

**First bounded workflow:** one researcher gathers public sources; one checker assesses citation coverage; one coordinator prepares a single brief. Neither specialist receives write privileges.

The coordinator owns the job, budget and final artifact. Specialists have named roles, limited tools and input/output contracts. They exchange referenced evidence instead of unrestricted shared transcripts. Only the coordinator can request a concrete write approval, and it cannot delegate broader authority than the job has.

The UI shows ownership, current work and unresolved disagreements. A consensus vote is not evidence; contradictory findings remain visible. Shared memory must retain provenance and scope, with reviewable edits and deletion.

**Acceptance:** delegation cannot widen permissions; one cancellation stops child work; independent evidence is distinguished from repeated claims; retries do not multiply side effects; total cost and concurrent-agent limits hold.

## Suggested implementation order

1. Public-page retrieval and research evidence checking.
2. Draft-only email integration with immutable preview revisions.
3. Remote public-research worker with budgets and cancellation.
4. Read-only research/checker team.
5. Only then evaluate browser submissions or actual email sending against their acceptance checks.

These are reviewable designs, not a promise that all four can safely be enabled by adding tool wrappers.
