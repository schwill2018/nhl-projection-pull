# Self-contained synthetic fixtures. No HTTP request can leave this harness.
if (dir.exists(".local/R-library")) .libPaths(c(normalizePath(".local/R-library"), .libPaths()))
source("R/projected_goalies.R")
dir.create(".local/tests", recursive = TRUE, showWarnings = FALSE)
roster_fixture <- file.path("tests", "fixtures", "rosters")
fixture_html <- paste(readLines(file.path(roster_fixture, "lineups.html")), collapse = "\n")

roster_environment <- function(scenario = "normal", observed = "2026-10-06T17:00:00.000Z") {
  environment <- new.env()
  sys.source("R/projected_goalies.R", environment)
  environment$Sys.time <- function() as.POSIXct("2026-10-06 17:00:00", tz = "UTC")
  environment$pg_now <- function() observed
  environment$GET <- function(url, ...) {
    label <- if (grepl("/schedule/", url)) "schedule" else if (grepl("/standings/", url)) "standings" else if (grepl("/team$", url)) "teams" else if (grepl("/roster/", url)) paste0("roster_", strsplit(url, "/")[[1]][6]) else "lineups"
    root <- if (label %in% c("lineups", "roster_NSH", "roster_TOR")) roster_fixture else "tests/fixtures"
    path <- file.path(root, paste0(label, if (label == "lineups") ".html" else ".json"))
    body <- readBin(path, "raw", n = file.info(path)$size)
    status <- 200L
    if (label == "lineups") {
      text <- rawToChar(body)
      if (scenario == "stale") text <- gsub("2026-10-06", "2026-10-05", text, fixed = TRUE)
      if (scenario == "missing") status <- 404L
      if (scenario == "unresolved") text <- sub("Alex Alder", "Unknown Forward", text, fixed = TRUE)
      if (scenario == "duplicate") text <- sub("Blake Birch", "Alex Alder", text, fixed = TRUE)
      if (scenario == "ambiguous") text <- sub("Alex Alder", "A. Alder", text, fixed = TRUE)
      if (scenario == "unicode") {
        text <- sub("Alex Alder", "Jos\u00e9 D\u2019Amour", text, fixed = TRUE)
        text <- sub("Victor Beech", "Victor D\u2019Beech", text, fixed = TRUE)
      }
      if (scenario == "missing_line") text <- sub("<p>Alex Alder -- Blake Birch -- Casey Cedar</p>", "", text, fixed = TRUE)
      if (scenario == "no_absences") text <- gsub("<p>(Scratched|Injured):[^<]*</p>", "", text)
      if (scenario == "unresolved_injury") text <- sub("Victor Beech", "Unknown Player", text, fixed = TRUE)
      if (scenario == "conflict") text <- sub("Scratched: Uma Ash", "Scratched: Alex Alder", text, fixed = TRUE)
      if (scenario == "none") text <- gsub("<p>(Scratched|Injured):[^<]*</p>", "<p>\\1: None</p>", text)
      body <- charToRaw(text)
    }
    if (label == "schedule" && scenario == "no_games") body <- charToRaw('{"gameWeek":[{"date":"2026-10-06","games":[]}]}')
    if (scenario == "cache_only" && grepl("/roster/", url)) status <- 404L
    if (scenario == "current_miss" && grepl("/current$", url)) status <- 404L
    if (scenario == "roster_503" && label == "roster_NSH" && grepl("/current$", url)) status <- 503L
    if (scenario == "removed_injury" && label == "roster_NSH") {
      roster <- fromJSON(rawToChar(body), simplifyVector = FALSE)
      roster$defensemen <- Filter(function(x) x$lastName$default != "Beech", roster$defensemen)
      body <- charToRaw(toJSON(roster, auto_unbox = TRUE))
    }
    if (scenario %in% c("wrong_position", "ambiguous") && label == "roster_NSH") {
      roster <- fromJSON(rawToChar(body), simplifyVector = FALSE)
      if (scenario == "wrong_position") {
        roster$defensemen <- c(roster$defensemen, roster$forwards[1])
        roster$forwards <- roster$forwards[-1]
      } else roster$forwards <- c(roster$forwards, list(list(id = 9000500L,
        firstName = list(default = "Adam"), lastName = list(default = "Alder"))))
      body <- charToRaw(toJSON(roster, auto_unbox = TRUE))
    }
    if (scenario == "unicode" && label == "roster_NSH") {
      roster <- fromJSON(rawToChar(body), simplifyVector = FALSE)
      roster$forwards[[1]]$firstName$default <- "Jos\u00e9"
      roster$forwards[[1]]$lastName$default <- "D'Amour"
      roster$defensemen[[7]]$lastName$default <- "D'Beech"
      body <- charToRaw(toJSON(roster, auto_unbox = TRUE))
    }
    structure(list(status_code = status, content = body, headers = list(), url = url), class = "response")
  }
  environment
}
roster_replay <- function(scenario = "normal", base = tempfile("roster_", tmpdir = ".local/tests"),
                          observed = "2026-10-06T17:00:00.000Z") {
  result <- roster_environment(scenario, observed)$run_projected_goalies(base_path = base)
  result
}

normal <- roster_replay()
players <- normal$roster_df
nsh <- filter(players, team_abbrev == "NSH")
tor <- filter(players, team_abbrev == "TOR")
stopifnot(all(normal$roster_coverage$eligible_for_backtest),
  sum(nsh$in_projected_lineup) == 20L, sum(tor$in_projected_lineup) == 20L,
  sum(nsh$in_projected_lineup == 0L) == 3L,
  nsh$in_projected_lineup[nsh$player_name == "Taylor Willow"] == 0L,
  nsh$scratched[nsh$player_name == "Taylor Willow"] == 0L,
  nsh$scratched[nsh$player_name == "Uma Ash"] == 1L,
  nsh$injured[nsh$player_name == "Victor Beech"] == 1L,
  nsh$injury_detail[nsh$player_name == "Victor Beech"] == "upper body, day to day",
  identical(nsh$forward_line[nsh$position == "F" & nsh$in_projected_lineup == 1L], rep(1:4, each = 3)),
  tor$forward_line[tor$player_name == "TorKai Kauri"] == 4L,
  tor$defense_pairs[tor$player_name == "TorSam Sycamore"] == 4L,
  all(nsh$in_projected_lineup[nsh$position == "G"] == 1L),
  identical(nsh$goalie_role[nsh$position == "G"], c("starter", "backup")),
  all(is.na(players$in_projected_lineup[players$team_abbrev == "BOS"])),
  !anyDuplicated(select(players, observation_id, game_id, teamId, playerId)),
  nrow(readRDS(file.path(normal$run_dir, "requests.rds"))) == 7L)
notes <- readRDS(file.path(normal$run_dir, "roster_notes.rds"))
stopifnot(nrow(notes) == 2L, all(notes$scope == "matchup"), all(grepl("Both teams", notes$status_notes)))
cat("PASS 12F/6D and 11F/7D, line/pair order, both goalies, exclusions, explicit absences, comma injury details, shared notes, idle teams, unique keys, no added HTTP requests\n")
unicode <- roster_replay("unicode")
stopifnot(all(unicode$roster_coverage$eligible_for_backtest),
  all(unicode$roster_coverage$injured_complete),
  filter(unicode$roster_df, playerId == 9000001L)$forward_line == 1L)
cat("PASS accented names and typographic apostrophes in lineup and injury sections\n")

expected <- c(stale = "stale_or_undated_article", missing = "article_unavailable",
  unresolved = "participant_unresolved", duplicate = "duplicate_participant",
  ambiguous = "participant_unresolved", wrong_position = "unexpected_position_structure", missing_line = "unexpected_position_structure",
  conflict = "conflicting_lineup_status")
for (scenario in names(expected)) {
  result <- roster_replay(scenario)
  stopifnot(result$roster_coverage$projection_status[1] == expected[[scenario]],
    all(is.na(filter(result$roster_df, team_abbrev == "NSH")$in_projected_lineup)))
  if (!scenario %in% c("stale", "missing")) stopifnot(result$roster_coverage$projection_status[2] == "matched")
}
diagnostic <- roster_replay("unresolved")
diagnostics <- readRDS(file.path(diagnostic$run_dir, "roster_diagnostics.rds"))
stopifnot(any(diagnostics$raw_name == "Unknown Forward" & diagnostics$issue == "unmatched", na.rm = TRUE))
for (scenario in c("no_absences", "unresolved_injury")) {
  result <- roster_replay(scenario)
  team <- filter(result$roster_df, team_abbrev == "NSH")
  stopifnot(all(team$eligible_for_backtest), all(is.na(team$injured)), sum(team$in_projected_lineup) == 20L)
}
none <- roster_replay("none")
stopifnot(all(filter(none$roster_df, !is.na(game_id))$scratched == 0L),
  all(filter(none$roster_df, !is.na(game_id))$injured == 0L))
cat("PASS stale/missing/partial/duplicate/conflicting coverage, unresolved-name diagnostics, missing sections versus explicit None\n")

base <- tempfile("roster_history_", tmpdir = ".local/tests")
first <- roster_replay(base = base)
before <- tools::md5sum(file.path(first$run_dir, c("projected_roster_df.rds", "lineups.html")))
removed <- roster_replay("removed_injury", base)
retained <- filter(removed$roster_df, player_name == "Victor Beech")
stopifnot(retained$injured == 1L, retained$roster_source == "cached_fallback", !retained$is_current_roster)
cached <- roster_replay("cache_only", base)
stopifnot(all(cached$roster_coverage$eligible_for_backtest), all(!cached$roster_df$is_current_roster))
invisible(roster_replay("stale", base))
invisible(roster_replay("unresolved", base))
at_start <- roster_replay(base = base, observed = "2026-10-06T23:00:00.000Z")
stopifnot(all(at_start$roster_coverage$projection_status == "not_pregame"),
  nrow(readRDS(file.path(at_start$run_dir, "roster_eligible_pregame.rds"))) == 0L,
  nrow(readRDS(file.path(at_start$run_dir, "roster_post_start_observations.rds"))) > 0L,
  identical(before, tools::md5sum(names(before))))
asof <- read_projected_rosters_asof("2026-10-06", "2026-10-06T22:00:00Z", base)
stopifnot(sum(asof$in_projected_lineup) == 40L,
  nrow(read_projected_rosters_asof("2026-10-06", "2026-10-06T16:00:00Z", base)) == 0L,
  all(count(asof, game_id, teamId)$n >= 20L),
  !anyDuplicated(select(asof, game_id, teamId, playerId)))
empty <- roster_replay("no_games")
stopifnot(nrow(empty$roster_coverage) == 0L, all(is.na(empty$roster_df$in_projected_lineup)))
season <- roster_replay("current_miss")
stopifnot(all(season$roster_coverage$eligible_for_backtest), all(!season$roster_df$is_current_roster))
cat("PASS durable identity reuse, article-only cached identities, labeled season fallback, exact cutoff, later invalid observations preserve earlier snapshots, no games\n")

# Whole-team selection after lineup changes, equal timestamps and failed attempts.
snapshot_base <- tempfile("roster_asof_", tmpdir = ".local/tests")
for (i in 1:4) {
  folder <- file.path(snapshot_base, "history", as.character(i)); dir.create(folder, recursive = TRUE)
  rows <- filter(players, team_abbrev == "NSH")
  rows$observation_id <- as.character(i)
  rows$retrieved_at <- if (i == 1L) "2026-10-06T17:00:00Z" else "2026-10-06T18:00:00Z"
  if (i %in% c(2L, 4L)) {
    rows$in_projected_lineup[rows$player_name == "Alex Alder"] <- 0L
    rows$forward_line[rows$player_name == "Alex Alder"] <- NA_integer_
    rows$in_projected_lineup[rows$player_name == "Taylor Willow"] <- 1L
    rows$forward_line[rows$player_name == "Taylor Willow"] <- 1L
  }
  saveRDS(rows, file.path(folder, "projected_roster_df.rds"))
  writeLines(if (i == 4L) '{"state":"failure"}' else '{"state":"success"}', file.path(folder, "run.json"))
}
selected <- read_projected_rosters_asof("2026-10-06", "2026-10-06T19:00:00Z", snapshot_base)
stopifnot(all(selected$observation_id == "3"), sum(selected$in_projected_lineup) == 20L,
  selected$in_projected_lineup[selected$player_name == "Alex Alder"] == 1L)
writeLines('{"state":"success"}', file.path(snapshot_base, "history", "4", "run.json"))
selected <- read_projected_rosters_asof("2026-10-06", "2026-10-06T19:00:00Z", snapshot_base)
stopifnot(all(selected$observation_id == "4"), sum(selected$in_projected_lineup) == 20L,
  selected$in_projected_lineup[selected$player_name == "Alex Alder"] == 0L)
cat("PASS whole-team lineup replacement, equal-time ties, failed receipt exclusion\n")

# Exercise the CLI summary with full-roster fixtures, while isolating Actions env.
cli <- roster_environment()
cli$Sys.getenv <- function(x, unset = "", ...) {
  values <- base::Sys.getenv(x, unset = unset, ...)
  values[x %in% c("PG_RUN_DIR", "GITHUB_STEP_SUMMARY")] <- unset
  values
}
cli_base <- tempfile("roster_cli_", tmpdir = ".local/tests")
cli$commandArgs <- function(...) cli_base
cli$source <- function(...) invisible(NULL)
sys.source("scripts/collect.R", cli)
folder <- list.dirs(file.path(cli_base, "history"), recursive = FALSE)
summary <- paste(readLines(file.path(folder, "summary.md")), collapse = "\n")
stopifnot(grepl("complete projected rosters: **2 / 2**", summary, fixed = TRUE),
  grepl("20 / 20", summary, fixed = TRUE), grepl("11 / 7", summary, fixed = TRUE))
cat("PASS full-roster CLI summary reports matching and unusual player grouping\n")

# A recoverable HTTP failure can still produce matched rows, but the attempt fails.
failure_base <- tempfile("roster_failed_local_", tmpdir = ".local/tests")
error <- tryCatch({ roster_replay("roster_503", failure_base); NULL }, error = conditionMessage)
folder <- list.dirs(file.path(failure_base, "history"), recursive = FALSE)
stopifnot(!is.null(error), readLines(file.path(folder, "collection_status.txt"))[1] == "failure",
  nrow(read_projected_rosters_asof("2026-10-06", "2026-10-06T22:00:00Z", failure_base)) == 0L,
  nrow(read_projected_goalies_asof("2026-10-06", "2026-10-06T22:00:00Z", failure_base)) == 0L)
cat("PASS direct local failure is visible and excluded from both model readers despite successful identity fallback\n")
