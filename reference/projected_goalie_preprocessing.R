# Daily projected goalies. Run from the model directory:
# Rscript projected_goalie_preprocessing.R
# Or source this file and call run_projected_goalies(). No boxscore file required.
# One article request per run; no publication polling. Schedule this script once
# each morning in your existing scheduler. Missing coverage remains NA, not 0.
# Each run is retained under Data/projected_goalies/history for as-of backtests.

library(dplyr)
library(purrr)
library(tibble)
library(httr)
library(jsonlite)
library(xml2)
library(stringi)

pg_now <- function() format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC")
pg_time <- function(x) as.POSIXct(x, format = "%Y-%m-%dT%H:%M:%OSZ", tz = "UTC")
pg_name <- function(x) {
  x <- stringi::stri_trans_general(x, "Latin-ASCII")
  trimws(gsub(" +", " ", gsub("[^a-z0-9 ]", "", tolower(x))))
}

# Restrict candidates to one team before calling. Never guess ambiguous names.
pg_match <- function(name, candidates) {
  if (!nrow(candidates)) return(list(id = NA_integer_, method = "unmatched"))
  candidates <- distinct(candidates, playerId, .keep_all = TRUE)
  key <- pg_name(name)
  full <- pg_name(candidates$player_name)
  hits <- which(full == key)
  method <- "exact_normalized"
  if (!length(hits)) {
    parts <- strsplit(key, " +")[[1]]
    first <- pg_name(candidates$first_name)
    last <- pg_name(candidates$last_name)
    # Retain full API last names (including compound surnames). Ignore only
    # intervening middle tokens; an initial is accepted only if unique on team.
    hits <- which(vapply(seq_along(last), function(i) {
      length(parts) >= 2L && endsWith(key, paste0(" ", last[i])) &&
        (parts[1] == strsplit(first[i], " +")[[1]][1] ||
         (nchar(parts[1]) == 1L && startsWith(first[i], parts[1])))
    }, logical(1)))
    method <- "first_last_or_initial"
  }
  if (length(hits) != 1L) return(list(id = NA_integer_,
    method = if (length(hits)) "ambiguous" else "unmatched"))
  list(id = candidates$playerId[hits], method = method)
}

# Parse the server-rendered article, preserving team blocks and goalie order.
# Requiring the trailing two individual-name rows prevents a forward line or
# the scratched/injured lists from being mistaken for the projected starter.
pg_article <- function(html) {
  doc <- read_html(html)
  metadata <- xml_find_all(doc, "//script[@type='application/ld+json']")
  dates <- character()
  walk_json <- function(x) {
    if (!is.list(x)) return(invisible(NULL))
    if (!is.null(x$datePublished)) dates <<- c(dates, x$datePublished)
    lapply(x, walk_json)
    invisible(NULL)
  }
  for (node in metadata) tryCatch(walk_json(fromJSON(xml_text(node),
    simplifyVector = FALSE)), error = function(e) NULL)
  dates <- unique(substr(dates, 1, 10))
  nodes <- xml_find_all(doc, "//p | //h2 | //h3")
  txt <- trimws(gsub("[[:space:]\u00a0]+", " ", xml_text(nodes)))
  headings <- which(grepl("^[A-Za-z .'-]+ projected lineup$", txt,
                          ignore.case = TRUE))
  blocks <- map_dfr(headings, function(i) {
    after <- if (i < length(txt)) seq.int(i + 1L, length(txt)) else integer()
    stop_at <- after[grepl("^(Scratched:|Injured:|Status report)|projected lineup$",
                          txt[after], ignore.case = TRUE) |
                      xml_name(nodes[after]) %in% c("h2", "h3")]
    end <- if (length(stop_at)) stop_at[1] - 1L else length(txt)
    rows <- if (end > i) txt[seq.int(i + 1L, end)] else character()
    rows <- rows[nzchar(rows)]
    tail_rows <- tail(rows, 2)
    valid <- length(rows) >= 3L && length(tail_rows) == 2L &&
      all(grepl("^[\\p{L} .'-]+$", tail_rows, perl = TRUE)) &&
      !any(grepl("--|\u2013|\u2014|:", tail_rows))
    preceding <- which(seq_along(txt) < i & xml_name(nodes) == "h2")
    tibble(team_label = sub(" projected lineup$", "", txt[i], ignore.case = TRUE),
      matchup = if (length(preceding)) txt[max(preceding)] else NA_character_,
      projected_name = if (valid) tail_rows[1] else NA_character_,
      backup_name = if (valid) tail_rows[2] else NA_character_,
      parse_status = if (valid) "parsed" else "unexpected_lineup_structure")
  })
  list(article_date = if (length(dates) == 1L) dates else NA_character_,
       blocks = blocks)
}

run_projected_goalies <- function(
    target_date = as.Date(format(Sys.time(), tz = "America/Chicago", format = "%Y-%m-%d")),
    base_path = file.path(getwd(), "Data", "projected_goalies"),
    article_url = NULL) {
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
  run_dir <- tempfile(paste0(format(target_date), "_",
    format(Sys.time(), "%H%M%S", tz = "UTC"), "_"),
    tmpdir = file.path(base_path, "history"))
  dir.create(run_dir)
  requests <- list()
  # Archive all responses, including errors, so a missed/partial morning is visible.
  fetch <- function(url, label, json = TRUE) {
    observed <- pg_now()
    response <- tryCatch(GET(url, timeout(40),
      user_agent("NHL-projected-goalie-preprocessing/1.0")), error = identity)
    ok <- !inherits(response, "error") && status_code(response) == 200L
    body <- if (inherits(response, "error")) raw() else content(response, as = "raw")
    writeBin(body, file.path(run_dir, paste0(label, if (json) ".json" else ".html")))
    requests[[length(requests) + 1L]] <<- tibble(url = url,
      retrieved_at = observed, completed_at = pg_now(),
      http_status = if (inherits(response, "error")) NA_integer_ else status_code(response),
      error = if (inherits(response, "error")) conditionMessage(response) else NA_character_)
    saveRDS(bind_rows(requests), file.path(run_dir, "requests.rds"))
    if (!ok) return(NULL)
    value <- rawToChar(body); Encoding(value) <- "UTF-8"
    if (!json) return(value)
    tryCatch(fromJSON(value, simplifyVector = FALSE), error = function(e) NULL)
  }

  ## --- SCHEDULE AND COMPACT CURRENT GOALIE DIRECTORY ----------------------
  schedule <- fetch(paste0("https://api-web.nhle.com/v1/schedule/", target_date), "schedule")
  if (is.null(schedule)) stop("Schedule unavailable; request log retained in ", run_dir)
  day <- keep(schedule$gameWeek, ~ identical(.x$date, format(target_date)))
  if (length(day) != 1L) stop("Requested date absent from schedule; no output published.")
  games <- day[[1]]$games
  game_teams <- map_dfr(games, function(g) map_dfr(c("awayTeam", "homeTeam"), function(side) {
    t <- g[[side]]
    tibble(game_id = as.integer(g$id), season = as.integer(g$season),
      game_date = format(target_date), startTimeUTC = g$startTimeUTC,
      gameState = g$gameState, teamId = as.integer(t$id), team_abbrev = t$abbrev,
      team_label = t$commonName$default,
      opponent_label = g[[if (side == "awayTeam") "homeTeam" else "awayTeam"]]$commonName$default)
  }))
  standings <- fetch("https://api-web.nhle.com/v1/standings/now", "standings")
  teams <- fetch("https://api.nhle.com/stats/rest/en/team", "teams")
  if (is.null(standings) || is.null(teams)) stop("Team directory unavailable; run retained.")
  active <- map_chr(standings$standings, ~ .x$teamAbbrev$default)
  directory <- map_dfr(teams$data, ~ tibble(teamId = as.integer(.x$id),
    team_abbrev = .x$triCode)) %>% filter(team_abbrev %in% active) %>% distinct()
  if (nrow(game_teams)) directory <- bind_rows(directory,
    select(game_teams, teamId, team_abbrev)) %>% distinct()
  cache_file <- file.path(base_path, "goalie_directory_history.rds")
  old <- if (file.exists(cache_file)) readRDS(cache_file) else tibble()
  goalie_directory <- map_dfr(seq_len(nrow(directory)), function(i) {
    t <- directory[i, ]
    roster <- fetch(paste0("https://api-web.nhle.com/v1/roster/", t$team_abbrev,
                           "/current"), paste0("roster_", t$team_abbrev))
    source <- "current_roster"; roster_season <- season
    if (is.null(roster) || !length(roster$goalies)) {
      roster <- fetch(paste0("https://api-web.nhle.com/v1/roster/", t$team_abbrev,
                             "/", season), paste0("season_roster_", t$team_abbrev))
      source <- "season_roster"
    }
    if (is.null(roster) || !length(roster$goalies)) {
      # Identity fallback only: never claim last year's roster is current.
      roster <- fetch(paste0("https://api-web.nhle.com/v1/roster/", t$team_abbrev,
                             "/", previous), paste0("prior_roster_", t$team_abbrev))
      source <- "prior_season_fallback"; roster_season <- previous
    }
    if (is.null(roster) || !length(roster$goalies)) {
      if (!nrow(old)) return(tibble())
      return(old %>% filter(teamId == t$teamId, season %in% c(.env$season, .env$previous)) %>%
        arrange(desc(directory_observed_at)) %>% distinct(playerId, .keep_all = TRUE) %>%
        mutate(roster_source = "cached_fallback", is_current_roster = FALSE))
    }
    map_dfr(roster$goalies, function(p) tibble(season = season,
      roster_season = roster_season, teamId = t$teamId, team_abbrev = t$team_abbrev,
      playerId = as.integer(p$id), first_name = p$firstName$default,
      last_name = p$lastName$default,
      player_name = paste(p$firstName$default, p$lastName$default),
      roster_source = source, is_current_roster = source == "current_roster",
      directory_observed_at = pg_now()))
  })
  if (!nrow(goalie_directory)) stop("No goalie identities available; run retained.")
  saveRDS(bind_rows(old, goalie_directory) %>% distinct(), cache_file)
  saveRDS(goalie_directory, file.path(run_dir, "goalie_directory.rds"))

  ## --- TODAY'S ARTICLE: ONE REQUEST, DATE CHECK, TEAM-SCOPED MATCH ---------
  html <- fetch(article_url, "lineups", json = FALSE)
  article_observed_at <- tail(requests, 1)[[1]]$completed_at
  parsed <- tryCatch(if (is.null(html)) NULL else pg_article(html), error = function(e) NULL)
  status <- "article_unavailable"
  if (!is.null(parsed)) status <- if (is.na(parsed$article_date) ||
      parsed$article_date != format(target_date)) "stale_or_undated_article" else "ready"
  coverage <- if (!nrow(game_teams)) tibble() else map_dfr(seq_len(nrow(game_teams)), function(i) {
    t <- game_teams[i, ]; candidates <- filter(goalie_directory, teamId == t$teamId)
    state <- status; name <- NA_character_; backup <- NA_character_
    id <- NA_integer_; method <- NA_character_
    if (status == "ready") {
      b <- filter(parsed$blocks, pg_name(team_label) == pg_name(t$team_label))
      if (nrow(b) != 1L) state <- "missing_or_duplicate_team_block" else {
        name <- b$projected_name; backup <- b$backup_name; state <- b$parse_status
        if (is.na(b$matchup) || !grepl(pg_name(t$opponent_label), pg_name(b$matchup), fixed = TRUE))
          state <- "opponent_mismatch"
        if (state == "parsed") {
          m <- pg_match(name, candidates); m2 <- pg_match(backup, candidates)
          id <- m$id; method <- m$method
          state <- if (is.na(id)) m$method else if (is.na(m2$id) || m2$id == id)
            "backup_unresolved" else "matched"
        }
      }
    }
    pregame <- t$gameState %in% c("FUT", "PRE") &&
      pg_time(article_observed_at) < pg_time(t$startTimeUTC)
    if (!isTRUE(pregame)) state <- "not_pregame"
    mutate(t, projected_name = name, backup_name = backup,
      projected_playerId = if (state == "matched") id else NA_integer_,
      match_method = method, projection_status = state,
      retrieved_at = article_observed_at, source_url = article_url,
      article_date = if (is.null(parsed)) NA_character_ else parsed$article_date,
      eligible_for_backtest = state == "matched" && isTRUE(pregame))
  })
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
  saveRDS(coverage, file.path(run_dir, "coverage.rds"))
  saveRDS(goalie_df, file.path(run_dir, "projected_goalie_df.rds"))
  write.csv(coverage, file.path(run_dir, "coverage.csv"), row.names = FALSE)
  write.csv(goalie_df, file.path(run_dir, "projected_goalie_df.csv"), row.names = FALSE)
  # Latest is a convenience snapshot. Backtests must use the timestamped history.
  saveRDS(goalie_df, file.path(base_path, "projected_goalie_latest.rds"))
  cat("Saved:", run_dir, "\n")
  if (nrow(coverage)) print(count(coverage, projection_status))
  invisible(list(goalie_df = goalie_df, coverage = coverage, run_dir = run_dir))
}

# Read projections that were actually observed by a model's prediction cutoff.
# Select the latest successful TEAM snapshot, not each player's latest row;
# otherwise two different goalies could both retain a 1 after a lineup change.
read_projected_goalies_asof <- function(game_date, cutoff_utc,
    base_path = file.path(getwd(), "Data", "projected_goalies")) {
  cutoff <- pg_time(cutoff_utc)
  if (length(cutoff) != 1L || is.na(cutoff)) stop("Use a UTC ISO timestamp for cutoff_utc.")
  paths <- list.files(file.path(base_path, "history"),
    pattern = "^projected_goalie_df\\.rds$", recursive = TRUE, full.names = TRUE)
  if (!length(paths)) return(tibble())
  x <- map_dfr(paths, readRDS)
  if (!"eligible_for_backtest" %in% names(x)) return(tibble())
  x <- x %>% filter(.data$game_date == format(as.Date(.env$game_date)),
    eligible_for_backtest %in% TRUE, pg_time(retrieved_at) <= cutoff,
    pg_time(retrieved_at) < pg_time(startTimeUTC))
  if (!nrow(x)) return(x)
  latest <- x %>% group_by(game_id, teamId) %>%
    summarise(retrieved_at = max(retrieved_at), .groups = "drop")
  inner_join(x, latest, by = c("game_id", "teamId", "retrieved_at")) %>%
    distinct(game_id, teamId, playerId, .keep_all = TRUE)
}

if (sys.nframe() == 0L) run_projected_goalies()
