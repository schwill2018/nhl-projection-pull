# NHL projected-goalie collection

Standalone R adaptation of the supplied V2. It reads NHL's rolling lineup
article once per run, matches **both** listed goalies to team-specific NHL player
IDs, and marks the first as projected starter. API roster ordering never chooses
a starter. The original hockey-model folder is untouched.

## Publish and enable

Create an **empty private GitHub repository**, then run from this folder:

```powershell
git add .
git commit -m "Prepare standalone NHL projected goalie collector"
git remote add origin https://github.com/YOUR_ACCOUNT/YOUR_PRIVATE_REPO.git
git push -u origin main
```

After publishing:

1. Keep `main` as the default branch. Under **Settings → Actions → General**,
   allow Actions, `actions/*`, and `r-lib/actions/*`. Allow `GITHUB_TOKEN` to write
   repository contents; organization policies/rulesets must permit creating and
   updating `data`. No PAT or NHL secret is required.
2. Run **Actions → Offline validation → Run workflow**; confirm success.
3. Under **Settings → Secrets and variables → Actions → Variables**, create
   repository variable **`NHL_COLLECTION_ENABLED`** with exact value **`true`**.
4. Run **Collect NHL projected goalies** manually. Verify its final archive step
   succeeds and the new `data` branch contains the observation and goalie cache.

Collection is gated off until step 3. Set that variable to `false` or disable the
workflow to stop collection. Nothing has been published or remotely enabled.

## Schedule, dependencies and local use

Every day at **9:15 a.m., 11:15 a.m., 1:15 p.m., and 3:15 p.m. America/Chicago**,
plus manual runs. [Current GitHub syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule)
supports DST through this timezone field (verified October 7, 2026):

```yaml
schedule:
  - cron: '15 9,11,13,15 * * *'
    timezone: America/Chicago
workflow_dispatch:
```

Requires R ≥ 4.4, Git and Python 3.10+ (standard library only). `DESCRIPTION`
declares dplyr ≥ 1.1.1, purrr, tibble, httr, jsonlite, xml2 and stringi. Actions
installs current R release/dependencies on Ubuntu with an expendable package
cache; versions are not locked, so offline fixtures run before every pull.
`setup-r-dependencies` handles Linux system dependencies, including curl/OpenSSL/
libxml2 development libraries. No model files or absolute library paths are needed.

From the repository root, with `Rscript`, Python and Git on PATH:

```powershell
Rscript --vanilla scripts/install_dependencies.R
Rscript --vanilla tests/test_collector.R
python -m unittest discover -s tests -p "test_*.py" -v
Rscript --vanilla scripts/collect.R
# Optional isolated live pull:
Rscript --vanilla scripts/collect.R .local/live-smoke
```

The installer uses ignored `.local/R-library`. Local collection writes
`Data/projected_goalies`, never pushes, and requires one writer per output folder.

## Durable history and model downloads

The **`data` branch** is automatically created on the first enabled run. Every
runner restores it and `goalie_directory_history.rds` before collecting. Unique
UTC/run-ID/attempt/UUID folders preserve repeated pulls and reruns:

```text
Data/projected_goalies/
  goalie_directory_history.rds, projected_goalie_latest.rds
  history/<unique-observation>/
    run.json, collection_status.txt, summary.md, sha256.json
    lineups.html, schedule.json, standings.json, teams.json, roster_*.json
    requests.rds/csv, parsed_lineups.rds, goalie_directory.rds
    coverage.rds/csv, projected_goalie_df.rds/csv
    eligible_pregame.rds/csv, post_start_observations.rds/csv
```

Raw fallback/error responses are retained too. Logs record URLs, HTTP status,
request start/completion UTC timestamps and errors. Receipts identify the source
commit and Actions URL; manifests record file hashes. Git preserves raw bytes.
Failed runs retain a receipt and whatever was collected before failure.

The workflow attempts a verified, ordinary push even after collection/setup/test
failure. Storage rejects changes to older observations and stale concurrent
writers; GitHub's shared `queue: max` serializes collection. **Do not force-push,
delete, or merge `data` into `main`.** No automatic history deletion is configured.

Authenticate for your private repository and clone `data` into a separate folder:

```powershell
git clone --single-branch --branch data https://github.com/YOUR_ACCOUNT/YOUR_PRIVATE_REPO.git nhl-goalie-history
git -C nhl-goalie-history pull --ff-only
```

Alternatively choose `data` in GitHub and download its ZIP. Git history survives
Actions artifact expiration; keep a local clone/mirror backup as an additional copy.
From the code repository root, point your model's as-of read at that download:

```r
source("R/projected_goalies.R")
projected <- read_projected_goalies_asof(
  game_date = "2026-10-07", cutoff_utc = "2026-10-07T18:00:00Z",
  base_path = file.path("..", "nhl-goalie-history", "Data", "projected_goalies"))
# Join on game_id + teamId + playerId, using your actual prediction cutoff.
```

The helper chooses the latest successful **whole-team** snapshot observed by the
cutoff and strictly before scheduled start. Later stale/missing pulls cannot erase
earlier eligible snapshots. Equal-time ties select one whole archive by path.
Archives with run receipts marked failed/interrupted are excluded from model reads;
older V2 archives without receipts remain supported.
`projected_goalie_latest.rds` is only the latest pull and may be incomplete;
historical models must use the as-of helper.

## Coverage, failures and recovery

Each Actions **Summary** lists matched-team count, article date, team/opponent,
name/ID, status and observation time. Archived `summary.md` and `coverage.csv`
retain those details. Green means execution and storage succeeded, **not complete
coverage**. Flags preserve V2: **1** = resolved first-listed goalie, **0** = other
goalies on that matched team/game, **NA** = unknown/idle.

Stale/undated articles, lineup HTTP 404 and missing blocks are expected gaps.
Malformed blocks, wrong opponents, ambiguous/unmatched names and unresolved
backups remain explicit coverage statuses. Both names must resolve distinctly.
Identity fallbacks are labeled. `not_pregame` rows retain post-start observations
separately with NA flags and no eligibility. FUT/PRE **and observation strictly
before scheduled start** are required; equality already fails, even if still PRE.
No-games days succeed with unknown flags.

Transport/non-404 HTTP errors, response decoding/collector exceptions,
dependency/test failures and storage/push errors **fail the workflow**. Inspect
failed step logs and enable GitHub failed-workflow notifications. Each attempt
also has a **14-day recovery artifact**, including a bootstrap receipt if restore
fails. A failed restore prevents a durable push to protect existing history.

For an unpushed observation, download its artifact before expiration, copy the
unique run folder into `Data/projected_goalies/history/` in an up-to-date separate
`data` clone, then commit/push the addition. Preserve its original directory name;
do not overwrite the current cache with an older artifact. A manual rerun creates
a new observation and cannot recreate the earlier historical timestamp.

## Platform limits

Schedules run from the default branch and can be delayed or dropped under load;
exact-minute delivery is not guaranteed. Actual response completion time governs
eligibility. The [concurrency queue](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#concurrency)
holds up to 100 waiting runs; further runs can be canceled. Runner termination
can prevent archival, so inspect canceled/missing runs as well as failures.

Private repositories consume plan minutes/artifact storage. GitHub Free currently
includes 2,000 minutes/month and 500 MB artifact storage; four daily pulls mean
about 120 jobs/month. See [current limits](https://docs.github.com/en/actions/reference/limits)
and account budgets. Artifacts expire after 14 days here and are subject to
[retention policies](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository);
they are secondary recovery copies.

The data branch grows indefinitely. Monitor clone/repository/cache size;
[GitHub blocks files over 100 MiB](https://docs.github.com/en/repositories/working-with-files/managing-large-files/about-large-files-on-github)
and recommends small repositories. Migrate to durable object storage if needed,
preserving all timestamps/raw inputs. The public-repository 60-day inactivity
schedule rule does not apply to this private setup. NHL endpoints/layout may change.

See [necessary V2 fixes](docs/changes.md) and [test evidence](docs/validation.md).
`reference/` contains unmodified supplied originals for comparison, not entrypoints.
