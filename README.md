# NHL Projection Pull

Collect NHL projected lineups and keep a timestamped history for pregame modeling.

Each run reads NHL.com's lineup projections, matches the listed players to NHL IDs, and saves the source responses alongside the results. That gives you a record of what was available when you made a prediction, even after the article changes.

The collector saves projected starting goalies, forward lines, defense pairs, scratches, injuries, and matchup notes. It collects today's projections using the Chicago date. Past dates come from saved observations; it cannot recreate projections that were never collected.

## What you get

- **Goalies:** both listed goalies matched to the correct team's NHL IDs. The first listed goalie is the projected starter. API roster order never picks the starter.
- **Full rosters:** published forward lines and defense pairs, both goalies, and explicit scratch and injury information.
- **Coverage:** which teams resolved, which did not, and why. Missing or incomplete information stays unknown.
- **History:** separate observations for every pull, with raw responses, request timestamps, and parsed results.

These are published projections. The collector does not fetch player performance stats or confirm who actually played.

## Run locally

Use R 4.4 or newer. Git and Python 3.10+ are also needed for the archive tooling and its tests. R dependencies are listed in [DESCRIPTION](DESCRIPTION).

From the repository root:

```powershell
Rscript --vanilla scripts/install_dependencies.R
Rscript --vanilla scripts/collect.R
```

The installer uses `.local/R-library`. Collection writes to `Data/projected_goalies/`; both directories are ignored by Git. Local runs do not push anything to GitHub. Use one writer per output folder.

For an optional pull into a separate output folder:

```powershell
Rscript --vanilla scripts/collect.R .local/live-smoke
```

## Use the data in a model

**Use the as-of readers for historical predictions.** The `latest` files only describe the most recent pull and may be incomplete.

Run this from the code repository root after installing the dependencies:

```r
.libPaths(c(normalizePath(".local/R-library"), .libPaths()))
source("R/projected_goalies.R")  # Loads both readers without collecting data.

history_path <- file.path("Data", "projected_goalies")

# Example: replace these with your game date and actual prediction cutoff.
game_date <- "2026-10-08"
cutoff_utc <- "2026-10-08T18:00:00Z"

goalies <- read_projected_goalies_asof(
  game_date = game_date,
  cutoff_utc = cutoff_utc,
  base_path = history_path
)

rosters <- read_projected_rosters_asof(
  game_date = game_date,
  cutoff_utc = cutoff_utc,
  base_path = history_path
)
```

Join to your model on `game_id + teamId + playerId`. The example needs saved observations for that date; the readers do not fetch historical data.

Each reader selects the latest eligible **whole-team snapshot** available by the cutoff. A later missing, stale, or incomplete pull does not erase an earlier valid snapshot. Failed or interrupted runs are excluded. Goalie and full-roster coverage are checked independently, so a usable goalie projection does not guarantee a complete lineup.

Pregame eligibility requires a current article date, a game state of `FUT` or `PRE`, and an observation strictly before scheduled puck drop. An observation at the exact start time is already too late. The timestamp is when the article response finished downloading.

| Field | Meaning |
|---|---|
| `projected_goalie` | `1` for the resolved first-listed goalie, `0` for other goalies on that matched team/game, `NA` when unknown |
| `in_projected_lineup` | `1` for listed participants, including both goalies; `0` for other output players on a complete eligible team; otherwise `NA` |
| `forward_line` / `defense_pairs` | Group number in the published lineup |
| `goalie_role` | `starter` or `backup` when the full-roster snapshot is eligible and complete |
| `scratched` / `injured` | Explicit absence-section flags; unknown sections stay `NA` |

A zero lineup flag does not mean a player is injured or scratched. See the [roster data contract](docs/projected-rosters.md) for columns, matching rules, and supported lineup structures.

## Collect automatically with GitHub Actions

The collection workflow is configured for **9:15 a.m., 11:15 a.m., 1:15 p.m., and 3:15 p.m. America/Chicago**, plus manual runs. Collection stays disabled until the repository variable below is set.

To enable it in your repository:

1. Keep `main` as the default branch. Allow GitHub Actions, including `actions/*` and `r-lib/actions/*`. Repository policies must allow the workflow's `GITHUB_TOKEN` to write contents and create or update the `data` branch.
2. Run **Actions → Offline validation → Run workflow** and check that it passes.
3. Under **Settings → Secrets and variables → Actions → Variables**, set `NHL_COLLECTION_ENABLED` to exactly `true`.
4. Run **Collect NHL projected goalies** manually. Check the coverage summary and the final **Commit and verify durable archive** step.

No personal access token or NHL secret is required. To stop collection, set `NHL_COLLECTION_ENABLED` to `false` or disable the workflow.

Both workflows use R 4.4.2 on Ubuntu 24.04. R packages are not pinned. The collection workflow runs the offline R fixtures before each live pull.

## Where the history lives

Code lives on `main`. Automated collection stores history on the separate **`data` branch**, created on the first enabled run. Each run restores that history and the player identity caches before collecting.

```text
Data/projected_goalies/
  goalie_directory_history.rds
  player_directory_history.rds
  projected_goalie_latest.rds
  projected_roster_latest.rds
  history/
    <unique-observation>/
```

Each observation contains the following files when collection reaches the relevant step:

| Files | Purpose |
|---|---|
| `projected_goalie_df.rds/csv`, `projected_roster_df.rds/csv` | Player-level results |
| `coverage.rds/csv`, `roster_coverage.rds/csv` | Team coverage and eligibility |
| `roster_diagnostics.rds/csv`, `roster_notes.rds/csv` | Name matches, unresolved names, and published notes |
| `eligible_pregame.rds/csv`, `roster_eligible_pregame.rds/csv` | Eligible pregame rows |
| `post_start_observations.rds/csv`, `roster_post_start_observations.rds/csv` | Observations made after scheduled start |
| `lineups.html`, supporting JSON, `requests.rds/csv` | Source responses and request logs |
| `summary.md`, `collection_status.txt` | Run summary and collection outcome |

Actions also writes `run.json` and `sha256.json` for the run receipt and file hashes. Failed runs preserve whatever was collected before failure.

To download the automated history, authenticate for repository access and clone the `data` branch into a separate folder:

```powershell
git clone --single-branch --branch data https://github.com/schwill2018/nhl-projection-pull.git nhl-projection-history
git -C nhl-projection-history pull --ff-only
```

Set `history_path` in the R example to that clone's `Data/projected_goalies` directory. You can also download a ZIP of the `data` branch from GitHub.

**Do not force-push, delete, or merge `data` into `main`.** Push code changes to `main`. The archive tooling rejects changes to older observations and stale concurrent writes. History is not automatically deleted, so storage needs grow over time. A separate local backup is optional.

## Check coverage and failures

**A green run means the workflow succeeded. It does not mean every team has a projection.** Check the Actions summary or the archived coverage files before using a pull.

Stale or unpublished articles, missing team blocks, and unresolved names are recorded as coverage gaps. No-games days can also complete successfully. Transport errors, non-404 HTTP failures, decoding errors, test failures, and archive failures fail the workflow.

Actions attempts to archive failed collection runs when history restoration succeeded. A failed restore blocks the archive push to protect existing history. Each attempt also has a recovery artifact configured for 14-day retention.

If an observation was not pushed, download its recovery artifact before it expires. Copy the unique observation folder into `Data/projected_goalies/history/` in an up-to-date, separate `data` clone, then commit and push the addition. Keep its original folder name and do not replace current caches with older copies. Rerunning collection creates a new observation; it cannot recover an earlier timestamp.

Scheduled runs can be delayed or missed. Runner termination can prevent archival. Check missing or canceled runs as well as failures, and monitor repository storage and Actions usage. NHL endpoints and article layouts can change.

## Validate changes

After installing dependencies, run the offline checks from the repository root:

```powershell
Rscript --vanilla tests/test_collector.R
Rscript --vanilla tests/test_rosters.R
python -m unittest discover -s tests -p "test_*.py" -v
```

These checks use fixtures and temporary local Git repositories. They do not collect live projections or push to GitHub.

More detail: [roster schema and validation](docs/projected-rosters.md), [implementation changes](docs/changes.md), and [recorded validation results](docs/validation.md). The `reference/` folder contains the supplied originals for comparison; use `scripts/collect.R` to run this collector.
