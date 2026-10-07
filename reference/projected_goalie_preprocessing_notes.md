Daily projected goalie preprocessing
===================================

Run from `C:/Users/schne/Hockey_Model/model`:

```r
source("projected_goalie_preprocessing.R")
result <- run_projected_goalies()
```

Or run `Rscript projected_goalie_preprocessing.R` in an existing morning scheduler.
No scheduler has been installed. The script requests the season's rolling NHL
lineup article once per run, checks its publication date against today's Chicago
date, and checks each team/opponent against the exact day's schedule. A morning
run cannot guarantee publication; stale, absent, partial, or unmatchable lineups
are recorded explicitly. Rerunning later creates another snapshot.

Outputs are under `Data/projected_goalies`:

- `projected_goalie_latest.rds`: compact goalie dataframe for all teams;
  `game_id`, `teamId`, `playerId`, full name, roster source, projected name,
  match method, observation timestamp, and `projected_goalie`.
- `goalie_directory_history.rds`: retained identities and team memberships with
  observation times. Current and season API rosters work even with zero games
  played. Prior-season/cached fallback is explicitly labeled, not called current.
- `history/<date_time_run>/`: immutable-by-convention RDS/CSV projections,
  team coverage, roster directory, raw API/article responses, and request log.
  Runs never overwrite earlier snapshot directories. Do not run two writers
  simultaneously (latest/directory files use a single-writer workflow).

Flags: 1 = first listed goalie successfully matched; 0 = other goalies for that
resolved team/game; NA = unavailable/uncertain projection or idle team. The two
trailing names must both resolve to distinct goalies on that team's candidate
roster. No fuzzy nearest-name guesses. Exact normalized names take priority;
unique first/last names or first initials can accommodate middle-name variation.
Unmatched or ambiguous names remain in coverage.csv for review.

No boxscore or player-preprocessing dependency is used. This is a goalie identity
and projection table, not a table of saves/GSAx/player performance statistics.
Goalie performance features continue to come from the existing preprocessing.

Historical joins must use the prediction timestamp, not today's latest file:

```r
projected <- read_projected_goalies_asof(
  game_date = "2026-10-06", cutoff_utc = "2026-10-06T18:00:00Z")
projection_keys <- projected %>%
  select(game_id, teamId, playerId, projected_goalie, retrieved_at)
# left_join(all_boxscore_df, projection_keys,
#           by = c("game_id", "teamId", "playerId"), relationship = "many-to-one")
```

The helper selects the latest successfully resolved team snapshot observed by
the cutoff and before scheduled puck drop. No earlier snapshots means no
historical prediction; scraping today cannot reconstruct past morning knowledge.
Actual `starter` is an outcome, not a substitute for a missing historical forecast.
The script's season is an eight-digit NHL ID; the suite converts season to a
four-digit year at line 1531. Join on the three identity keys, not raw season.

Integration outline (suite remains unmodified)
---------------------------------------------

1. Around line 1530, after combining played/future player rows: load and join
   projection keys by game_id + teamId + playerId, before player rolling metrics.
   Check that projected IDs actually exist in future roster rows; a missing
   called-up goalie needs a properly constructed roster row, not an inner join.
2. Around lines 2864–3098, inside/before calculate_team_rost_metrics: use existing
   lagged goalie metrics and select projected_goalie == 1 for projected-goalie
   aggregates. Keep actual starter separately. Existing starter filters are at
   lines 2934 and 2985. Preserve unknown metrics as NA; the function currently
   replaces missing numeric values with zero, which needs special handling here.
3. Around lines 3304–3328, when extracting/saving goalie_df: retain projection
   flags, source, status, and observation time for forecast-vs-actual evaluation.
   This is too late to affect roster metrics already calculated upstream.

Source inspection
-----------------

The supplied https://media.nhl.com/public/news/20064 is the October 6 Morning
Skate roundup, not the lineup article. Its public JSON is fetched by the site's
JavaScript via `/site/api/news/public?...&cayenneExp=id=20064`.
The lineup source is https://www.nhl.com/news/nhl-lineup-projections-2026-27-season
(season URL generated automatically). In inspected HTML, goalie names are plain
paragraph text, without player-ID attributes or player links. Its JSON-LD has
publication timestamps and article text, but no structured goalie identities.

Verified October 6: 10 team projections matched; 8 scheduled teams absent from
the article at collection time; goalie directory covered all 32 teams. Offline
checks: `Rscript projected_goalie_validation.R`.
