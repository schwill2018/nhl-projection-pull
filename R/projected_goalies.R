# Standalone adaptation of V2; originals retained under reference/.
# source("R/projected_goalies.R")
# result <- run_projected_goalies()
# Default outputs are the same Data/projected_goalies files as V1.
# Each run retains its own history. Source this file without fetching anything.

library(dplyr)
library(purrr)
library(tibble)
library(httr)
library(jsonlite)
library(xml2)
library(stringi)
sys.source("R/projected_rosters.R", envir = environment())

# START HERE. Supporting functions below follow the same step order.
run_projected_goalies <- function(
    target_date = as.Date(format(Sys.time(), tz = "America/Chicago", format = "%Y-%m-%d")),
    base_path = file.path(getwd(), "Data", "projected_goalies"),
    article_url = NULL, run_dir = NULL) {
  target_date <- as.Date(target_date)
  today <- as.Date(format(Sys.time(), tz = "America/Chicago", format = "%Y-%m-%d"))
  if (length(target_date) != 1L || is.na(target_date) || target_date != today)
    stop("Collect only today's projections. Use saved snapshots for past dates.")
  season_start <- as.integer(format(target_date, "%Y")) -
    as.integer(as.integer(format(target_date, "%m")) < 7L)
  season <- as.integer(paste0(season_start, season_start + 1L))
  previous <- as.integer(paste0(season_start - 1L, season_start))
  if (is.null(article_url)) article_url <- sprintf(
    "https://www.nhl.com/news/nhl-lineup-projections-%d-%02d-season",
    season_start, (season_start + 1L) %% 100L)
  dir.create(file.path(base_path, "history"), recursive = TRUE, showWarnings = FALSE)
  if (is.null(run_dir)) run_dir <- tempfile(paste0(format(target_date), "_",
    format(Sys.time(), "%H%M%S", tz = "UTC"), "_"),
    tmpdir = file.path(base_path, "history"))
  dir.create(run_dir, recursive = TRUE, showWarnings = FALSE)
  if (length(list.files(run_dir, pattern = "\\.(rds|csv|html)$")))
    stop("Refusing to overwrite an existing observation directory.")
  # Direct local calls need the same failure/success evidence as the CLI.
  completed <- FALSE
  writeLines("running", file.path(run_dir, "collection_status.txt"))
  on.exit(if (!completed) writeLines("failure", file.path(run_dir, "collection_status.txt")), add = TRUE)

  collector <- pg_create_collector(run_dir)
  fetch <- collector$fetch

  # 1. Get today's games and opponents.
  game_teams <- pg_get_game_teams(target_date, fetch, run_dir)

  # 2. Build the lookup of goalie names and NHL player IDs.
  goalie_directory <- pg_get_goalie_directory(
    game_teams, season, previous, base_path, run_dir, fetch
  )

  # 3. Read the article's projected starter and backup for each team.
  parsed <- pg_read_lineups(article_url, fetch)
  article_observed_at <- collector$last_completed_at()
  saveRDS(parsed, file.path(run_dir, "parsed_lineups.rds"))

  # 4. Match both goalie names to team-specific IDs.
  # 5. Check the date, opponent, matching results, and pregame cutoff.
  # Matching and validation share a function so invalid matches stay unknown.
  coverage <- pg_check_team_projections(
    game_teams, goalie_directory, parsed, target_date,
    article_observed_at, article_url
  )

  # 6. Assign 1 / 0 / NA and save this run's results.
  goalie_df <- pg_build_projection_flags(goalie_directory, coverage, target_date)
  pg_save_outputs(goalie_df, coverage, base_path, run_dir)
  # Reuse the archived responses: full rosters require no additional HTTP pulls.
  roster <- pg_collect_rosters(game_teams, goalie_directory, season, previous,
    target_date, article_observed_at, article_url, base_path, run_dir)
  # Coverage is retained even when an article request fails. Such a failure
  # must fail the run; 404 (not yet published) is the sole expected HTTP miss.
  requests <- readRDS(file.path(run_dir, "requests.rds"))
  failed <- is.na(requests$http_status) | !requests$http_status %in% c(200L, 404L) |
    !is.na(requests$error)
  if (any(failed)) stop("HTTP/decoding failure in ",
    paste(requests$label[failed], collapse = ", "), "; observations retained. See requests.csv.")
  writeLines("success", file.path(run_dir, "collection_status.txt"))
  completed <- TRUE
  invisible(list(goalie_df = goalie_df, coverage = coverage, run_dir = run_dir,
    roster_df = roster$players, roster_coverage = roster$coverage))
}

# STEP 1: schedule ----------------------------------------------------------
pg_get_game_teams <- function(target_date, fetch, run_dir) {
  schedule <- fetch(paste0("https://api-web.nhle.com/v1/schedule/", target_date), "schedule")
  if (is.null(schedule)) stop("Schedule unavailable; request log retained in ", run_dir)
  day <- keep(schedule$gameWeek, ~ identical(.x$date, format(target_date)))
  if (length(day) != 1L) stop("Requested date absent from schedule; no output published.")
  games <- day[[1]]$games
  team_rows <- list()
  for (game in games) {
    for (side in c("awayTeam", "homeTeam")) {
      team <- game[[side]]
      opponent_side <- "awayTeam"
      if (side == "awayTeam") {
        opponent_side <- "homeTeam"
      }
      opponent <- game[[opponent_side]]
      team_rows[[length(team_rows) + 1L]] <- tibble(
        game_id = as.integer(game$id), season = as.integer(game$season),
        game_date = format(target_date), startTimeUTC = game$startTimeUTC,
        gameState = game$gameState, teamId = as.integer(team$id),
        team_abbrev = team$abbrev, team_label = team$commonName$default,
        opponent_label = opponent$commonName$default
      )
    }
  }
  game_teams <- bind_rows(team_rows)
  game_teams
}

# STEP 2: roster lookup and labeled identity fallbacks -----------------------
pg_get_goalie_directory <- function(game_teams, season, previous_season,
                                   base_path, run_dir, fetch) {
  standings <- fetch("https://api-web.nhle.com/v1/standings/now", "standings")
  teams <- fetch("https://api.nhle.com/stats/rest/en/team", "teams")
  if (is.null(standings) || is.null(teams)) stop("Team directory unavailable; run retained.")
  active_abbreviations <- map_chr(standings$standings, ~ .x$teamAbbrev$default)
  directory <- map_dfr(teams$data, ~ tibble(teamId = as.integer(.x$id),
    team_abbrev = .x$triCode)) %>% filter(team_abbrev %in% active_abbreviations) %>% distinct()
  if (nrow(game_teams)) directory <- bind_rows(directory,
    select(game_teams, teamId, team_abbrev)) %>% distinct()
  cache_file <- file.path(base_path, "goalie_directory_history.rds")
  saved_directory <- if (file.exists(cache_file)) readRDS(cache_file) else tibble()
  goalie_directory <- map_dfr(seq_len(nrow(directory)), function(team_index) {
    team <- directory[team_index, ]
    roster <- fetch(paste0("https://api-web.nhle.com/v1/roster/", team$team_abbrev,
                           "/current"), paste0("roster_", team$team_abbrev))
    roster_source_label <- "current_roster"
    roster_season <- season
    if (is.null(roster) || !length(roster$goalies)) {
      roster <- fetch(paste0("https://api-web.nhle.com/v1/roster/", team$team_abbrev,
                             "/", season), paste0("season_roster_", team$team_abbrev))
      roster_source_label <- "season_roster"
    }
    if (is.null(roster) || !length(roster$goalies)) {
      # Identity fallback only: never claim last year's roster is current.
      roster <- fetch(paste0("https://api-web.nhle.com/v1/roster/", team$team_abbrev,
                             "/", previous_season), paste0("prior_roster_", team$team_abbrev))
      roster_source_label <- "prior_season_fallback"
      roster_season <- previous_season
    }
    if (is.null(roster) || !length(roster$goalies)) {
      if (!nrow(saved_directory)) return(tibble())
      return(saved_directory %>% filter(teamId == team$teamId, season %in% c(.env$season, .env$previous_season)) %>%
        arrange(desc(directory_observed_at)) %>% distinct(playerId, .keep_all = TRUE) %>%
        mutate(roster_source = "cached_fallback", is_current_roster = FALSE))
    }
    map_dfr(roster$goalies, function(goalie) tibble(season = season,
      roster_season = roster_season, teamId = team$teamId, team_abbrev = team$team_abbrev,
      playerId = as.integer(goalie$id), first_name = goalie$firstName$default,
      last_name = goalie$lastName$default,
      player_name = paste(goalie$firstName$default, goalie$lastName$default),
      roster_source = roster_source_label, is_current_roster = roster_source_label == "current_roster",
      directory_observed_at = pg_now()))
  })
  if (!nrow(goalie_directory)) stop("No goalie identities available; run retained.")
  saveRDS(bind_rows(saved_directory, goalie_directory) %>% distinct(), cache_file)
  saveRDS(goalie_directory, file.path(run_dir, "goalie_directory.rds"))

  goalie_directory
}

# STEP 3: webpage -----------------------------------------------------------
pg_read_lineups <- function(article_url, fetch) {
  html <- fetch(article_url, "lineups", json = FALSE)
  if (is.null(html)) {
    return(NULL)
  }
  pg_article(html)
}

# STEPS 4 AND 5: resolve the two names and validate the projection ------------
pg_check_team_projections <- function(game_teams, goalie_directory, parsed,
                                      target_date, article_observed_at, article_url) {
  article_status <- "article_unavailable"
  article_date <- NA_character_
  if (!is.null(parsed)) {
    article_date <- parsed$article_date
    if (is.na(article_date) || article_date != format(target_date)) {
      article_status <- "stale_or_undated_article"
    } else {
      article_status <- "ready"
    }
  }

  team_results <- list()
  for (team_index in seq_len(nrow(game_teams))) {
    team <- game_teams[team_index, ]
    candidates <- filter(goalie_directory, teamId == team$teamId)
    status <- article_status
    projected_name_value <- NA_character_
    backup_name_value <- NA_character_
    projected_id <- NA_integer_
    matching_method <- NA_character_

    if (article_status == "ready") {
      team_block <- filter(parsed$blocks, pg_name(team_label) == pg_name(team$team_label))
      if (nrow(team_block) != 1L) {
        status <- "missing_or_duplicate_team_block"
      } else {
        projected_name_value <- team_block$projected_name
        backup_name_value <- team_block$backup_name
        status <- team_block$parse_status
        opponent_matches <- !is.na(team_block$matchup) &&
          grepl(pg_name(team$opponent_label), pg_name(team_block$matchup), fixed = TRUE)
        if (!opponent_matches) {
          status <- "opponent_mismatch"
        }
        if (status == "parsed") {
          starter_match <- pg_match(projected_name_value, candidates)
          backup_match <- pg_match(backup_name_value, candidates)
          projected_id <- starter_match$id
          matching_method <- starter_match$method
          if (is.na(projected_id)) {
            status <- starter_match$method
          } else if (is.na(backup_match$id) || backup_match$id == projected_id) {
            status <- "backup_unresolved"
          } else {
            status <- "matched"
          }
        }
      }
    }

    # Keep the strict V1 cutoff, even if a delayed game still says PRE.
    is_pregame <- team$gameState %in% c("FUT", "PRE") &&
      pg_time(article_observed_at) < pg_time(team$startTimeUTC)
    if (!isTRUE(is_pregame)) {
      status <- "not_pregame"
    }
    if (status != "matched") {
      projected_id <- NA_integer_
    }
    team_results[[team_index]] <- mutate(
      team, projected_name = projected_name_value, backup_name = backup_name_value,
      projected_playerId = projected_id, match_method = matching_method,
      projection_status = status, retrieved_at = article_observed_at,
      source_url = article_url, article_date = .env$article_date,
      eligible_for_backtest = status == "matched" && isTRUE(is_pregame)
    )
  }
  bind_rows(team_results)
}

# STEP 6: output flags and files --------------------------------------------
pg_build_projection_flags <- function(goalie_directory, coverage, target_date) {
  # All currently listed team goalies, including teams idle today (game_id = NA).
  # 1/0 only for a successfully resolved team projection; unknown = NA.
  goalie_df <- if (!nrow(coverage)) mutate(goalie_directory, game_id = NA_integer_,
      game_date = format(target_date), projected_goalie = NA_integer_,
      projection_status = "no_games") else goalie_directory %>%
    left_join(select(coverage, -team_abbrev, -season), by = "teamId",
              relationship = "many-to-many") %>%
    mutate(projected_goalie = if_else(projection_status == "matched",
      as.integer(playerId == projected_playerId), NA_integer_),
      projection_status = coalesce(projection_status, "no_game_today"))
  goalie_df
}

pg_save_outputs <- function(goalie_df, coverage, base_path, run_dir) {
  saveRDS(coverage, file.path(run_dir, "coverage.rds"))
  saveRDS(goalie_df, file.path(run_dir, "projected_goalie_df.rds"))
  write.csv(coverage, file.path(run_dir, "coverage.csv"), row.names = FALSE)
  write.csv(goalie_df, file.path(run_dir, "projected_goalie_df.csv"), row.names = FALSE)
  # Explicit subsets; original V2 files/columns retain their meanings.
  eligible <- if ("eligible_for_backtest" %in% names(goalie_df))
    filter(goalie_df, eligible_for_backtest %in% TRUE) else goalie_df[0, ]
  post_start <- if ("projection_status" %in% names(goalie_df))
    filter(goalie_df, projection_status == "not_pregame") else goalie_df[0, ]
  saveRDS(eligible, file.path(run_dir, "eligible_pregame.rds"))
  write.csv(eligible, file.path(run_dir, "eligible_pregame.csv"), row.names = FALSE)
  saveRDS(post_start, file.path(run_dir, "post_start_observations.rds"))
  write.csv(post_start, file.path(run_dir, "post_start_observations.csv"), row.names = FALSE)
  # Latest is a convenience snapshot. Backtests must use the timestamped history.
  saveRDS(goalie_df, file.path(base_path, "projected_goalie_latest.rds"))
  cat("Saved:", run_dir, "\n")
  if (nrow(coverage)) print(count(coverage, projection_status))
}

# SUPPORT: request archiving ------------------------------------------------
pg_create_collector <- function(run_dir) {
  requests <- list()
  # Archive all responses, including errors, so a missed/partial morning is visible.
  fetch <- function(url, label, json = TRUE) {
    observed <- pg_now()
    response <- tryCatch(GET(url, timeout(40),
      user_agent("NHL-projected-goalie-preprocessing/1.0")), error = identity)
    ok <- !inherits(response, "error") && status_code(response) == 200L
    body <- if (inherits(response, "error")) raw() else content(response, as = "raw")
    writeBin(body, file.path(run_dir, paste0(label, if (json) ".json" else ".html")))
    value <- NULL
    request_error <- if (inherits(response, "error")) conditionMessage(response) else NA_character_
    if (ok) {
      value <- tryCatch({
        text <- rawToChar(body)
        Encoding(text) <- "UTF-8"
        if (json) fromJSON(text, simplifyVector = FALSE) else text
      }, error = function(e) {
        request_error <<- paste("Response decoding failed:", conditionMessage(e))
        NULL
      })
    }
    requests[[length(requests) + 1L]] <<- tibble(url = url, label = label,
      retrieved_at = observed, completed_at = pg_now(),
      http_status = if (inherits(response, "error")) NA_integer_ else status_code(response),
      error = request_error)
    saveRDS(bind_rows(requests), file.path(run_dir, "requests.rds"))
    write.csv(bind_rows(requests), file.path(run_dir, "requests.csv"), row.names = FALSE)
    if (!ok) return(NULL)
    value
  }

  list(fetch = fetch, last_completed_at = function() tail(requests, 1)[[1]]$completed_at)
}

# SUPPORT: name matching and extracting the article's two goalie rows --------
pg_now <- function() format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC")
pg_time <- function(value) as.POSIXct(value, format = "%Y-%m-%dT%H:%M:%OSZ", tz = "UTC")
pg_name <- function(value) {
  value <- stringi::stri_trans_general(value, "Latin-ASCII")
  trimws(gsub(" +", " ", gsub("[^a-z0-9 ]", "", tolower(value))))
}

# Restrict candidates to one team before calling. Never guess ambiguous names.
pg_match <- function(name, candidates) {
  if (!nrow(candidates)) return(list(id = NA_integer_, method = "unmatched"))
  candidates <- distinct(candidates, playerId, .keep_all = TRUE)
  normalized_name <- pg_name(name)
  candidate_names <- pg_name(candidates$player_name)
  matching_rows <- which(candidate_names == normalized_name)
  method <- "exact_normalized"
  if (!length(matching_rows)) {
    name_parts <- strsplit(normalized_name, " +")[[1]]
    first_names <- pg_name(candidates$first_name)
    last_names <- pg_name(candidates$last_name)
    # Retain full API last names (including compound surnames). Ignore only
    # intervening middle tokens; an initial is accepted only if unique on team.
    matching_rows <- which(vapply(seq_along(last_names), function(row_index) {
      length(name_parts) >= 2L && endsWith(normalized_name, paste0(" ", last_names[row_index])) &&
        (name_parts[1] == strsplit(first_names[row_index], " +")[[1]][1] ||
         (nchar(name_parts[1]) == 1L && startsWith(first_names[row_index], name_parts[1])))
    }, logical(1)))
    method <- "first_last_or_initial"
  }
  if (length(matching_rows) != 1L) return(list(id = NA_integer_,
    method = if (length(matching_rows)) "ambiguous" else "unmatched"))
  list(id = candidates$playerId[matching_rows], method = method)
}

# Parse the server-rendered article, preserving team blocks and goalie order.
# Requiring the trailing two individual-name rows prevents a forward line or
# the scratched/injured lists from being mistaken for the projected starter.
pg_article <- function(html) {
  document <- read_html(html)
  metadata <- xml_find_all(document, "//script[@type='application/ld+json']")
  dates <- character()
  walk_json <- function(value) {
    if (!is.list(value)) return(invisible(NULL))
    if (!is.null(value$datePublished)) dates <<- c(dates, value$datePublished)
    lapply(value, walk_json)
    invisible(NULL)
  }
  for (node in metadata) tryCatch(walk_json(fromJSON(xml_text(node),
    simplifyVector = FALSE)), error = function(e) NULL)
  dates <- unique(substr(dates, 1, 10))
  nodes <- xml_find_all(document, "//p | //h2 | //h3")
  paragraph_text <- trimws(gsub("[[:space:]\u00a0]+", " ", xml_text(nodes)))
  headings <- which(grepl("^[A-Za-z .'-]+ projected lineup$", paragraph_text,
                          ignore.case = TRUE))
  blocks <- map_dfr(headings, function(row_index) {
    following_rows <- if (row_index < length(paragraph_text)) seq.int(row_index + 1L, length(paragraph_text)) else integer()
    section_boundaries <- following_rows[grepl("^(Scratched:|Injured:|Status report)|projected lineup$",
                          paragraph_text[following_rows], ignore.case = TRUE) |
                      xml_name(nodes[following_rows]) %in% c("h2", "h3")]
    section_end <- if (length(section_boundaries)) section_boundaries[1] - 1L else length(paragraph_text)
    lineup_rows <- if (section_end > row_index) paragraph_text[seq.int(row_index + 1L, section_end)] else character()
    lineup_rows <- lineup_rows[nzchar(lineup_rows)]
    goalie_rows <- tail(lineup_rows, 2)
    valid_goalie_rows <- length(lineup_rows) >= 3L && length(goalie_rows) == 2L &&
      all(grepl("^[\\p{L} .'-]+$", goalie_rows, perl = TRUE)) &&
      !any(grepl("--|\u2013|\u2014|:", goalie_rows))
    matchup_headings <- which(seq_along(paragraph_text) < row_index & xml_name(nodes) == "h2")
    tibble(team_label = sub(" projected lineup$", "", paragraph_text[row_index], ignore.case = TRUE),
      matchup = if (length(matchup_headings)) paragraph_text[max(matchup_headings)] else NA_character_,
      projected_name = if (valid_goalie_rows) goalie_rows[1] else NA_character_,
      backup_name = if (valid_goalie_rows) goalie_rows[2] else NA_character_,
      parse_status = if (valid_goalie_rows) "parsed" else "unexpected_lineup_structure")
  })
  # A dated article may exist before any team blocks have been published.
  if (!nrow(blocks)) blocks <- tibble(team_label = character(), matchup = character(),
    projected_name = character(), backup_name = character(), parse_status = character())
  list(article_date = if (length(dates) == 1L) dates else NA_character_,
       blocks = blocks)
}


# Read projections that were actually observed by a model's prediction cutoff.
# Select the latest successful TEAM snapshot, not each player's latest row;
# otherwise two different goalies could both retain a 1 after a lineup change.
read_projected_goalies_asof <- function(game_date, cutoff_utc,
    base_path = file.path(getwd(), "Data", "projected_goalies")) {
  cutoff <- pg_time(cutoff_utc)
  if (length(cutoff) != 1L || is.na(cutoff)) stop("Use a UTC ISO timestamp for cutoff_utc.")
  snapshot_paths <- list.files(file.path(base_path, "history"),
    pattern = "^projected_goalie_df\\.rds$", recursive = TRUE, full.names = TRUE)
  if (!length(snapshot_paths)) return(tibble())
  # Select a whole run, even when two observations share a millisecond.
  snapshots <- map_dfr(sort(snapshot_paths), function(path) {
    # Receipts distinguish a completed live pull from an interrupted/failed
    # attempt, including fixture-contaminated attempts from the initial harness.
    receipt <- file.path(dirname(path), "run.json")
    if (file.exists(receipt)) {
      metadata <- fromJSON(receipt)
      if (!identical(metadata$state, "success")) return(tibble())
    }
    completion <- file.path(dirname(path), "collection_status.txt")
    if (file.exists(completion) && readLines(completion, n = 1L) != "success") return(tibble())
    mutate(readRDS(path), .snapshot_path = path)
  })
  if (!"eligible_for_backtest" %in% names(snapshots)) return(tibble())
  snapshots <- snapshots %>% filter(.data$game_date == format(as.Date(.env$game_date)),
    eligible_for_backtest %in% TRUE, pg_time(retrieved_at) <= cutoff,
    pg_time(retrieved_at) < pg_time(startTimeUTC))
  if (!nrow(snapshots)) return(select(snapshots, -.snapshot_path))
  latest_team_times <- snapshots %>% distinct(game_id, teamId, retrieved_at, .snapshot_path) %>%
    arrange(retrieved_at, .snapshot_path) %>% group_by(game_id, teamId) %>%
    slice_tail(n = 1L) %>% ungroup()
  inner_join(snapshots, latest_team_times,
    by = c("game_id", "teamId", "retrieved_at", ".snapshot_path")) %>%
    distinct(game_id, teamId, playerId, .keep_all = TRUE) %>% select(-.snapshot_path)
}


if (sys.nframe() == 0L) {
  run_projected_goalies()
}
