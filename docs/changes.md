# Changes from supplied V2

The six readable stages, team-scoped name resolution, publication-date/opponent
checks, two distinct goalie requirements, roster fallback labels, strict FUT/PRE
and observation-before-start cutoff, and original output columns are preserved.
Unaffected scenarios are compared directly against the unmodified V2 reference.

Necessary fixes and additions:

- A dated page with zero team blocks now returns an empty **typed** block table.
  V2 returned a zero-column tibble, which made coverage filtering throw instead
  of reporting `missing_or_duplicate_team_block`.
- HTML parser exceptions now fail visibly rather than being swallowed as an
  unavailable article. HTTP 404 remains an expected unpublished-source condition.
  Non-404 HTTP/transport errors and JSON decoding failures are logged and fail
  collection, including transient roster errors even when a fallback succeeds.
  Usable coverage is saved before the final request-error check when possible.
- The request log gains labels, decoding errors and CSV export; raw responses
  retain the existing response bodies and start/completion timestamps.
- An optional `run_dir` permits the Actions receipt to exist before dependencies
  or collection execute. Existing observation output cannot be overwritten.
- Parsed article objects and explicit eligible/post-start subsets accompany the
  unchanged V2 coverage and projection files. Post-start names are observations,
  with unknown projected ID/flag and `eligible_for_backtest=FALSE`.
- As-of reads resolve equal observation timestamps to one whole-run snapshot.
  V2 could combine player rows from different tied snapshots and retain two 1s
  after a starter change. Ties are deterministically ordered by archive path;
  no finer chronological claim is made when timestamps are equal.
- A CLI receipt, run summary, integrity manifest and durable Git data branch
  preserve attempts beyond runner lifetimes and artifact retention. Failures in
  persistence fail the workflow. Latest/cache writes do not touch old snapshots.

No new fuzzy matching, lineup-date inference, starter inference from API order,
post-start prediction eligibility, or local-model integration was introduced.

## First GitHub run: fixture environment isolation

The initial CLI tests inherited Actions' `PG_RUN_DIR` and `GITHUB_STEP_SUMMARY`.
They wrote synthetic fixture outputs into the live run folder, then failed their
isolated-directory assertion. The harness now masks those variables, and the
workflow clears them in the fixture step. Regression checks simulate Actions
variables and confirm both production receipt and summary remain untouched.

The failed run `37659825514`, attempt 1, was inspected read-only on `data`.
Its run receipt says `failure`, but it contains synthetic NSH/TOR projections
dated October 6. Retain this evidence; do not treat it as a live prediction.
As-of model reads now exclude receipt-bearing runs whose state is not `success`.
Legacy V2 folders without receipts retain their prior behavior. Future successful
live runs are eligible under the unchanged matching and pregame rules.

Checkout v5 and upload-artifact v6 use Node 24, resolving the Node 20 warning
([checkout definition](https://raw.githubusercontent.com/actions/checkout/v5/action.yml),
[upload definition](https://raw.githubusercontent.com/actions/upload-artifact/v6/action.yml)).
Recovery upload includes hidden files only within its explicitly selected run/cache
paths, so pending `.local` bootstrap receipts are not silently skipped.
The Ubuntu migration notice is informational and requires no collector change.

## Full projected roster extension (October 8, 2026)

Added `R/projected_rosters.R`, sourced by the existing entry point. It parses
published forward/defense groups, both goalie roles, explicit scratches/injuries
and matchup-level notes from the already archived responses. No extra NHL
requests, R packages, changes to schedule/R installation, or remote publication.
Existing V2 goalie rows/columns/matching/cutoff behavior are retained.

New player outputs/cache live alongside goalie files in the existing run/Data
tree, so the current durable data-branch persistence restores and archives both.
Recovery artifacts include the new player cache. Old archived observations are
not rewritten. Full-roster eligibility is independently validated and invalid
teams get unknown membership; absence-list coverage is reported separately.

Direct local collector calls now write running/success/failure completion
markers, allowing both as-of readers to reject failed local attempts. The goalie
reader also respects these markers when present; marker-free legacy snapshots
retain their previous behavior. This closes a failure-filtering gap without
changing goalie projection values or cutoff rules.
The old fixture's `coverage.csv` filename check now uses an exact filename
pattern so `roster_coverage.csv` is not mistaken for a duplicate goalie output.
Both R fixture suites run before collection. Source/data branch separation and
GitHub Desktop update steps are documented in README.

The live smoke test exposed typographic apostrophes in skater/injury names.
The new roster parser now accepts those characters before using the unchanged
normalized-name matching logic; a fixture covers accents and curly apostrophes.
Spelling mismatches and injured players absent from identity sources remain
unresolved, with explicit participant/absence coverage rather than guessed IDs.

## R and Ubuntu version pins (October 8, 2026)

Both Actions workflows now select R 4.4.2 and `ubuntu-24.04`, matching the locally
tested R version and keeping the Ubuntu major version stable. Package versions,
action tags and the runner image's ongoing 24.04 updates are not locked. No
collector behavior, schedule, data-branch persistence or prebuilt container change
is included. R installation/download overhead remains; this change improves
version consistency rather than claiming to fix the earlier slow network path.
