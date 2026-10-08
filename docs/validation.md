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
Actions is now configured for R 4.4.2 on Ubuntu 24.04, with declared dependencies
and fixtures before collection. Hosted execution of these pins must be verified
after the user pushes the workflow update; local suites passed on R 4.4.2.

All five `reference/` copies were SHA-256 compared to their supplied originals
and were identical after setup. Runtime/scripts/workflows contain no original
model-folder or absolute R-library dependency. Local Git is initialized on `main`
with **no configured remote**; no GitHub repository or automation was enabled.

## Follow-up: first hosted run failure

The initial hosted run successfully installed R/dependencies and passed all core
fixture scenarios, then failed in the CLI harness because it inherited the live
`PG_RUN_DIR`. Its synthetic outputs were durably archived under a failure receipt.
The archive was inspected read-only; no GitHub history was changed or deleted.

The corrected harness is tested with simulated Actions destination/summary
variables and verifies those files remain untouched. The workflow also clears
the variables for offline fixtures. As-of checks cover exclusion of failed
receipts, inclusion of successful receipts, and compatibility with legacy V2
archives. No NHL collection/matching/cutoff rule was changed.

## Projected roster extension: October 8, 2026

Both offline R suites passed after the final changes. Existing goalie outputs
remain equivalent to original V2 across normal, stale, late, missing-article,
season/prior/cache fallback and no-game scenarios. New synthetic roster fixtures
cover 12F/6D and 11F/7D, forward/pair order, both goalies' membership, unlisted
players, scratches/injuries, embedded commas, accents/typographic apostrophes,
ambiguous/unresolved/duplicate identities, position/status conflicts, missing
sections versus None, shared notes, labeled identity fallback, no games, strict
cutoff, whole-team replacement/ties, failed local calls/receipts, and CLI summaries.
The fixture proves full-roster parsing adds no HTTP requests.

Five offline Python storage tests passed using temporary local bare repositories.
They exercise fresh-runner restoration of both goalie/player caches and new roster
files, repeated/failed runs, byte preservation/manifests, concurrent writer and
push failures, and rejection of changes to old observations. Git's Windows MSYS
process setup is blocked within the filesystem sandbox; this suite passed outside
that sandbox, still using only local temporary remotes and never GitHub pushes.

An isolated live CLI pull at `2026-10-08T15:12:21.482Z` archived 37 HTTP 200
responses, 794 identity/player rows and all new output files. NHL's article was
dated October 7 while the target was October 8: all 20 scheduled teams correctly
remained ineligible with unknown membership. This expected condition completed
successfully. Evidence stays under ignored `.local/roster-live-smoke/`.

The saved live article was then reparsed in memory after the apostrophe fix,
without editing the archived run. Five of its six published participant blocks
resolved; Capitals' `Alaiksei Protas` remained unresolved under the unchanged
name-matching rules. Several injured names were absent from the fetched identity
directory. Those gaps are explicit, not guessed IDs or false negative flags.
Because the article was stale, this live test did not establish eligible current-day
coverage; fixtures validate the complete eligible path. No remote branch, original
Hockey_Model file, schedule, or R setup was changed during this extension.
