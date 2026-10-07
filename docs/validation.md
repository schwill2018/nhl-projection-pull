# Validation — October 7, 2026

## Offline collector

`Rscript --vanilla tests/test_collector.R` passed. All HTTP calls in this suite
are replaced by fixture responses, and the fixture clock is fixed independently
of the machine's date. Included inputs are small synthetic schedule, standings,
team/roster JSON and article HTML; no model-folder files or network are required.

- Exact equality of V2 coverage and projection dataframes: normal, exact-start
  cutoff, stale, unpublished (404), current-season fallback, prior-season fallback,
  cached fallback and no-games scenarios.
- Visible failures with request evidence: missing schedule, malformed schedule
  JSON, lineup HTTP 503, and roster HTTP 503 even after a successful fallback.
- Zero lineup blocks, missing goalie row, duplicate team block, wrong opponent,
  same starter/backup, names belonging to another team, initials/middle names,
  ambiguous names, and accented/apostrophe normalization.
- Repeated same-day pulls keep separate archives; later stale/late pulls leave
  earlier eligible snapshots readable. Future observations are excluded.
- Changed starter and tied observation timestamps select a whole team snapshot
  without duplicate starter flags. Post-start rows have no eligible predictions.
- Actual CLI summary/status/exit behavior using fixture-injected environments:
  success, stale success, article request failure, schedule failure.

## Durable storage

`python -m unittest discover -s tests -p 'test_*.py' -v` passed **5 tests**.
These use temporary **local bare Git repositories**, never GitHub:

- Data-only branch creation, push verification, fresh-checkout restoration,
  repeated/stale/failed observations, identity-cache restoration and manifests.
- Byte-preserving raw response archives, including CRLF bytes.
- Rewriting prior observations is rejected.
- Concurrent stale writers cannot overwrite the newer archive.
- Inaccessible remotes and rejected pushes raise failures.
- Bootstrap receipts survive restoration failure and are adopted only after
  successful restoration, permitting recovery artifacts before collection.

Both workflow YAML files were parsed locally. Schedule, America/Chicago timezone,
manual trigger, opt-in, contents permission and queue settings were checked.
IANA conversion checks give 15:15/17:15/19:15/21:15 UTC in January and
14:15/16:15/18:15/20:15 UTC in July. Current syntax was verified against
[GitHub schedule documentation](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule)
and [queue documentation](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#concurrency).
GitHub has not executed these workflows yet; remote authentication/policies must
be verified by the first enabled manual run after publishing.

## Isolated live smoke tests

Two real runs of `Rscript --vanilla scripts/collect.R .local/live-smoke` succeeded,
with separate observations at **15:22:44.802 UTC** and **15:27:46.398 UTC**
(10:22 and 10:27 a.m. Chicago). Each archived **37 HTTP 200 responses**, including
the article and all supporting requests, plus coverage, projections, parsed
article, identity directory and pregame/post-start subsets. The directory contained
74 goalie identities across 33 distinct team IDs from V2's active-team lookup.

NHL scheduled PIT/WSH, COL/WPG and EDM/ANA. The rolling article had publication
date **2026-10-06** and 18 parsed team blocks. All **6 teams** were correctly
`stale_or_undated_article`; **0 eligible matched projections** were emitted.
The expected stale condition completed successfully, with all unknown flags.
No roster-order starter inference or attempt to reinterpret the stale date occurred.

Full raw evidence remains locally under ignored `.local/live-smoke/history/`;
it is isolated from production `Data/` and source publication. The first archive
contained approximately 691 KB before Git compression. This sample does not
predict long-term repository size or guarantee future NHL layout compatibility.

## Environment and boundaries

Package versions are recorded in [test-environment.csv](test-environment.csv).
Local tests used R 4.4.2 and isolated copies of installed package binaries under
ignored `.local/R-library`; no absolute user-library path is needed by committed
collector/tests. Fresh CRAN installation could not be exercised here because the
CRAN mirror hostname did not resolve in this environment. The installer and Actions
dependency setup are prepared, and must be verified on the published runner.
Actions uses current R release and declared dependencies, with fixtures before collection.

All five `reference/` copies were SHA-256 compared to their supplied originals
and were identical after setup. Runtime/scripts/workflows contain no original
model-folder or absolute R-library dependency. Local Git is initialized on `main`
with **no configured remote**; no GitHub repository or automation was enabled.
