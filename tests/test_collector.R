# Entirely offline: GET is replaced before any collector is invoked.
if (dir.exists(".local/R-library")) .libPaths(c(normalizePath(".local/R-library"), .libPaths()))
fixture <- file.path("tests", "fixtures")
fixed <- as.POSIXct("2026-10-06 17:01:20", tz = "UTC")
make_environment <- function(path, scenario = "normal") {
  environment <- new.env()
  sys.source(path, environment)
  environment$Sys.time <- function() fixed
  environment$pg_now <- function() if (scenario == "late") "2026-10-06T23:00:00.000Z" else "2026-10-06T17:01:20.000Z"
  environment$GET <- function(url, ...) {
    label <- if (grepl("/schedule/", url)) "schedule" else if (grepl("/standings/", url)) "standings" else if (grepl("/team$", url)) "teams" else if (grepl("/roster/", url)) paste0("roster_", strsplit(url, "/")[[1]][6]) else "lineups"
    path <- file.path(fixture, paste0(label, if (label == "lineups") ".html" else ".json"))
    body <- readBin(path, "raw", n = file.info(path)$size)
    fail <- (scenario == "missing_article" && label == "lineups") || (scenario == "missing_schedule" && label == "schedule")
    if (grepl("/roster/", url)) {
      if (scenario %in% c("season_fallback", "prior_fallback", "cached_fallback") && grepl("/current$", url)) fail <- TRUE
      if (scenario %in% c("prior_fallback", "cached_fallback") && grepl("/20262027$", url)) fail <- TRUE
      if (scenario == "cached_fallback") fail <- TRUE
    }
    if (scenario == "stale" && label == "lineups") body <- charToRaw(gsub("2026-10-06", "2026-10-05", rawToChar(body), fixed = TRUE))
    if (scenario == "no_games" && label == "schedule") body <- charToRaw('{"gameWeek":[{"date":"2026-10-06","games":[]}]}')
    if (scenario == "no_blocks" && label == "lineups") body <- charToRaw('<html><script type="application/ld+json">{"datePublished":"2026-10-06"}</script><p>Coming soon</p></html>')
    if (scenario == "malformed_schedule" && label == "schedule") body <- charToRaw('{broken')
    if (scenario == "article_503" && label == "lineups") fail <- TRUE
    if (scenario == "roster_503" && grepl("/current$", url) && label == "roster_NSH") fail <- TRUE
    expected_miss <- scenario %in% c("missing_article", "season_fallback", "prior_fallback", "cached_fallback")
    structure(list(status_code = if (fail) if (expected_miss) 404L else 503L else 200L,
      content = body, headers = list(), url = url), class = "response")
  }
  environment
}

dir.create(".local/tests", recursive = TRUE, showWarnings = FALSE)
replay <- function(environment, base = tempfile("replay_", tmpdir = ".local/tests"), cached = NULL) {
  dir.create(base, recursive = TRUE, showWarnings = FALSE)
  if (!is.null(cached)) saveRDS(cached, file.path(base, "goalie_directory_history.rds"))
  environment$run_projected_goalies(base_path = base)
}

normal <- replay(make_environment("R/projected_goalies.R"))
stopifnot(nrow(normal$coverage) == 2L, all(normal$coverage$projection_status == "matched"),
  all(normal$goalie_df$projected_goalie[normal$goalie_df$teamId == 6L] %in% NA),
  sum(normal$goalie_df$projected_goalie == 1L, na.rm = TRUE) == 2L,
  all(c("requests.csv", "lineups.html", "eligible_pregame.rds", "post_start_observations.rds") %in% list.files(normal$run_dir)))
cached <- readRDS(file.path(normal$run_dir, "goalie_directory.rds"))

# Preserve V2 schema, matching, flags and status for all unaffected scenarios.
for (scenario in c("normal", "late", "stale", "missing_article", "season_fallback", "prior_fallback", "cached_fallback", "no_games")) {
  old <- replay(make_environment("reference/projected_goalie_preprocessing_v2.R", scenario), cached = if (scenario == "cached_fallback") cached else NULL)
  new <- replay(make_environment("R/projected_goalies.R", scenario), cached = if (scenario == "cached_fallback") cached else NULL)
  stopifnot(isTRUE(all.equal(old$coverage, new$coverage)), isTRUE(all.equal(old$goalie_df, new$goalie_df)))
  if (scenario == "late") stopifnot(all(new$coverage$projection_status == "not_pregame"),
    nrow(readRDS(file.path(new$run_dir, "eligible_pregame.rds"))) == 0L,
    nrow(readRDS(file.path(new$run_dir, "post_start_observations.rds"))) == 4L)
  cat("PASS V2 equivalence:", scenario, "\n")
}
for (scenario in c("missing_schedule", "malformed_schedule", "article_503", "roster_503")) {
  environment <- make_environment("R/projected_goalies.R", scenario)
  base <- tempfile("failure_", tmpdir = ".local/tests")
  error <- tryCatch({ replay(environment, base); NULL }, error = conditionMessage)
  stopifnot(!is.null(error), length(list.files(base, pattern = "requests.rds", recursive = TRUE)) == 1L)
  if (scenario == "article_503") stopifnot(length(list.files(base, pattern = "coverage.csv", recursive = TRUE)) == 1L)
  cat("PASS visible failure:", scenario, "\n")
}
empty <- replay(make_environment("R/projected_goalies.R", "no_blocks"))
stopifnot(all(empty$coverage$projection_status == "missing_or_duplicate_team_block"))

# Port the supplied matching and malformed HTML assertions without model paths.
source("R/projected_goalies.R")
candidates <- tibble(playerId = 1:3, first_name = c("Juuse", "Matt", "Mark"),
  last_name = c("Saros", "Murray", "Murray"), player_name = c("Juuse Saros", "Matt Murray", "Mark Murray"))
stopifnot(pg_match("Juuse A. Saros", candidates)$id == 1L, pg_match("J. Saros", candidates)$id == 1L,
  pg_match("Matt Murray", candidates)$id == 2L, pg_match("M. Murray", candidates)$method == "ambiguous",
  pg_match("Unknown Goalie", candidates)$method == "unmatched",
  pg_name("Jos\u00e9 D\u2019Amour") == pg_name("Jose D'Amour"))
html <- paste(readLines(file.path(fixture, "lineups.html")), collapse = "\n")
bad <- pg_article(sub('<p>Justus Annunen</p>', '', html, fixed = TRUE))
stopifnot(bad$blocks$parse_status[1] == "unexpected_lineup_structure")
game_teams <- normal$coverage %>% select(game_id:opponent_label)
parsed <- pg_article(html)
check <- function(blocks) pg_check_team_projections(game_teams, cached,
  list(article_date = "2026-10-06", blocks = blocks), as.Date("2026-10-06"),
  "2026-10-06T17:00:00Z", "fixture")
duplicate <- check(bind_rows(parsed$blocks, parsed$blocks[1, ]))
stopifnot(duplicate$projection_status[1] == "missing_or_duplicate_team_block")
wrong <- parsed$blocks; wrong$matchup <- "Other teams"
stopifnot(all(check(wrong)$projection_status == "opponent_mismatch"))
wrong <- parsed$blocks; wrong$backup_name[1] <- "Juuse Saros"
stopifnot(check(wrong)$projection_status[1] == "backup_unresolved")
wrong <- parsed$blocks; wrong$projected_name[1] <- "Joseph Woll"
stopifnot(check(wrong)$projection_status[1] == "unmatched")

# Repeated same-day runs never overwrite; stale and late pulls retain history.
base <- tempfile("history_", tmpdir = ".local/tests")
first <- replay(make_environment("R/projected_goalies.R"), base)
before <- readRDS(file.path(first$run_dir, "projected_goalie_df.rds"))
replay(make_environment("R/projected_goalies.R", "stale"), base)
replay(make_environment("R/projected_goalies.R", "late"), base)
stopifnot(length(list.dirs(file.path(base, "history"), recursive = FALSE)) == 3L,
  identical(before, readRDS(file.path(first$run_dir, "projected_goalie_df.rds"))),
  sum(read_projected_goalies_asof("2026-10-06", "2026-10-06T22:00:00Z", base)$projected_goalie, na.rm = TRUE) == 2L,
  nrow(read_projected_goalies_asof("2026-10-06", "2026-10-06T16:00:00Z", base)) == 0L)

# A starter change replaces the entire team snapshot; equal-time runs cannot mix.
scratch <- tempfile("asof_", tmpdir = ".local/tests")
for (i in 1:3) {
  directory <- file.path(scratch, "history", as.character(i)); dir.create(directory, recursive = TRUE)
  x <- tibble(game_id = 2026020044L, teamId = 18L, playerId = 1:2,
    game_date = "2026-10-06", retrieved_at = if (i == 1L) "2026-10-06T11:00:00Z" else "2026-10-06T12:00:00Z",
    startTimeUTC = "2026-10-06T23:00:00Z", eligible_for_backtest = TRUE,
    projected_goalie = as.integer(1:2 == if (i == 2L) 2L else 1L))
  saveRDS(x, file.path(directory, "projected_goalie_df.rds"))
}
early <- read_projected_goalies_asof("2026-10-06", "2026-10-06T11:30:00Z", scratch)
late <- read_projected_goalies_asof("2026-10-06", "2026-10-06T12:30:00Z", scratch)
stopifnot(early$playerId[early$projected_goalie == 1L] == 1L,
  late$playerId[late$projected_goalie == 1L] == 1L, nrow(late) == 2L, sum(late$projected_goalie) == 1L)
# Failed/interrupted receipt-bearing archives cannot supply model predictions.
# Legacy V2 archives without a receipt retain their existing behavior.
failed_dir <- file.path(scratch, "history", "4")
dir.create(failed_dir)
failed <- mutate(x, retrieved_at = "2026-10-06T13:00:00Z", projected_goalie = as.integer(playerId == 2L))
saveRDS(failed, file.path(failed_dir, "projected_goalie_df.rds"))
writeLines('{"state":"failure"}', file.path(failed_dir, "run.json"))
after_failed <- read_projected_goalies_asof("2026-10-06", "2026-10-06T14:00:00Z", scratch)
stopifnot(after_failed$playerId[after_failed$projected_goalie == 1L] == 1L)
writeLines('{"state":"success"}', file.path(failed_dir, "run.json"))
after_success <- read_projected_goalies_asof("2026-10-06", "2026-10-06T14:00:00Z", scratch)
stopifnot(after_success$playerId[after_success$projected_goalie == 1L] == 2L)
cat("PASS failed receipt excluded and successful receipt included in as-of model reads\n")
cat("PASS matching, invalid structure, team scoping, duplicate/opponent/backup validation, repeated history, as-of cutoffs and equal-time team snapshots\n")

# Exercise the actual CLI receipt/summary/exit handling offline with injected GET.
# Actions supplies a live output directory and summary path. The fixture CLI
# must use neither, even when it is run inside the collection workflow.
protected_run <- tempfile("actions_receipt_", tmpdir = ".local/tests")
dir.create(protected_run)
writeLines("production receipt", file.path(protected_run, "run.json"))
protected_summary <- tempfile("actions_summary_", tmpdir = ".local/tests")
writeLines("production summary", protected_summary)
cli_environment <- function(scenario) {
  environment <- make_environment("R/projected_goalies.R", scenario)
  environment$Sys.getenv <- function(x, unset = "", ...) {
    values <- base::Sys.getenv(x, unset = unset, ...)
    values[x == "PG_RUN_DIR" | x == "GITHUB_STEP_SUMMARY"] <- unset
    values
  }
  environment
}
original_action_env <- Sys.getenv(c("PG_RUN_DIR", "GITHUB_STEP_SUMMARY"), unset = NA_character_)
run_cli_checks <- function() {
  on.exit({
    for (name in names(original_action_env)) {
      if (is.na(original_action_env[[name]])) Sys.unsetenv(name)
      else do.call(Sys.setenv, setNames(list(original_action_env[[name]]), name))
    }
  }, add = TRUE)
  Sys.setenv(PG_RUN_DIR = protected_run, GITHUB_STEP_SUMMARY = protected_summary)
  sentinel_hashes <- tools::md5sum(c(file.path(protected_run, "run.json"), protected_summary))
for (scenario in c("normal", "stale", "article_503", "missing_schedule")) {
  environment <- cli_environment(scenario)
  base <- tempfile("cli_", tmpdir = ".local/tests")
  environment$commandArgs <- function(...) base
  environment$source <- function(...) invisible(NULL) # Environment already holds collector
  environment$quit <- function(status, ...) stop(paste("EXIT", status))
  error <- tryCatch({ sys.source("scripts/collect.R", environment); NULL }, error = conditionMessage)
  expected <- if (scenario %in% c("article_503", "missing_schedule")) "failure" else "success"
  directories <- list.dirs(file.path(base, "history"), recursive = FALSE)
  stopifnot(length(directories) == 1L,
    readLines(file.path(directories[1], "collection_status.txt"))[1] == expected,
    file.exists(file.path(directories[1], "summary.md")),
    if (expected == "failure") identical(error, "EXIT 1") else is.null(error))
  cat("PASS CLI summary and exit:", scenario, "\n")
}
  stopifnot(identical(list.files(protected_run), "run.json"),
    identical(sentinel_hashes, tools::md5sum(names(sentinel_hashes))))
  cat("PASS Actions output directory and summary untouched by offline CLI fixtures\n")
}
run_cli_checks()
