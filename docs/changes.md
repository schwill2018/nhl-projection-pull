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
