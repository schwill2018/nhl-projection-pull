# Full projected rosters, alongside the unchanged V2 goalie outputs.
# Loaded by projected_goalies.R; uses its libraries, matching and UTC helpers.

# 1. Build an all-position identity directory from responses already archived.
pg_player_directory <- function(game_teams, goalie_directory, season, previous,
                                base_path, run_dir) {
  empty <- tibble(season = integer(), roster_season = integer(), teamId = integer(),
    team_abbrev = character(), playerId = integer(), first_name = character(),
    last_name = character(), player_name = character(), position = character(),
    roster_source = character(), is_current_roster = logical(), directory_observed_at = character())
  cache_path <- file.path(base_path, "player_directory_history.rds")
  saved <- if (file.exists(cache_path)) readRDS(cache_path) else empty
  if (!all(names(empty) %in% names(saved))) stop("Invalid player identity cache.")
  teams <- distinct(select(goalie_directory, teamId, team_abbrev))
  api_teams <- fromJSON(file.path(run_dir, "teams.json"), simplifyVector = FALSE)
  standings <- fromJSON(file.path(run_dir, "standings.json"), simplifyVector = FALSE)
  active <- map_chr(standings$standings, ~ .x$teamAbbrev$default)
  teams <- bind_rows(teams, map_dfr(api_teams$data, ~ tibble(teamId = as.integer(.x$id), team_abbrev = .x$triCode)) %>%
    filter(team_abbrev %in% active)) %>% distinct()
  if (nrow(game_teams)) teams <- distinct(bind_rows(teams, select(game_teams, teamId, team_abbrev)))
  requests <- readRDS(file.path(run_dir, "requests.rds"))
  fresh <- map_dfr(seq_len(nrow(teams)), function(i) {
    team <- teams[i, ]
    labels <- paste0(c("roster_", "season_roster_", "prior_roster_"), team$team_abbrev)
    available <- labels[labels %in% requests$label[requests$http_status %in% 200L & is.na(requests$error)]]
    if (!length(available)) return(empty)
    label <- available[1]
    roster <- fromJSON(file.path(run_dir, paste0(label, ".json")), simplifyVector = FALSE)
    source <- c("current_roster", "season_roster", "prior_season_fallback")[match(label, labels)]
    map_dfr(c(forwards = "F", defensemen = "D", goalies = "G"), function(position) {
      category <- c(F = "forwards", D = "defensemen", G = "goalies")[[position]]
      map_dfr(roster[[category]], function(player) tibble(
        season = season, roster_season = if (source == "prior_season_fallback") previous else season,
        teamId = team$teamId, team_abbrev = team$team_abbrev, playerId = as.integer(player$id),
        first_name = player$firstName$default, last_name = player$lastName$default,
        player_name = paste(player$firstName$default, player$lastName$default), position = position,
        roster_source = source, is_current_roster = source == "current_roster", directory_observed_at = pg_now()))
    })
  })
  # Preserve goalie cache fallbacks on the first deployment of the skater cache.
  goalie_fallback <- mutate(goalie_directory, position = "G") %>% select(all_of(names(empty)))
  historical <- saved %>% filter(season %in% c(.env$season, .env$previous)) %>%
    arrange(desc(directory_observed_at)) %>%
    mutate(roster_source = "cached_fallback", is_current_roster = FALSE)
  directory <- bind_rows(empty, fresh, goalie_fallback, historical) %>%
    distinct(teamId, playerId, .keep_all = TRUE)
  saveRDS(bind_rows(saved, directory) %>% distinct(), cache_path)
  saveRDS(directory, file.path(run_dir, "player_directory.rds"))
  directory
}

pg_empty_entries <- function() tibble(raw_name = character(), section = character(),
  group = integer(), slot = integer(), injury_detail = character())

# NHL prose uses typographic apostrophes as well as ASCII punctuation.
pg_valid_player_name <- function(value) nzchar(value) &
  grepl("^[\\p{L} .'\u2019\u2018\u02bc-]+$", value, perl = TRUE)

# Split lists on commas outside parentheses, preserving injury descriptions.
pg_status_names <- function(text, section) {
  value <- trimws(sub("^[^:]+:\\s*", "", text, perl = TRUE))
  if (tolower(value) %in% c("none", "none.", "none reported", "none reported."))
    return(list(entries = pg_empty_entries(), valid = TRUE))
  characters <- strsplit(value, "", fixed = TRUE)[[1]]
  depth <- 0L; start <- 1L; parts <- character(); valid <- nzchar(value)
  for (i in seq_along(characters)) {
    if (characters[i] == "(") depth <- depth + 1L
    if (characters[i] == ")") depth <- depth - 1L
    if (depth < 0L) valid <- FALSE
    if (characters[i] %in% c(",", ";") && depth == 0L) {
      parts <- c(parts, paste(characters[seq.int(start, i - 1L)], collapse = ""))
      start <- i + 1L
    }
  }
  if (length(characters) && start <= length(characters))
    parts <- c(parts, paste(characters[seq.int(start, length(characters))], collapse = ""))
  else valid <- FALSE
  valid <- valid && depth == 0L
  entries <- map_dfr(trimws(parts), function(part) {
    name <- trimws(sub("\\s*\\(.*$", "", part))
    detail <- if (grepl("\\(", part)) sub("^[^(]*\\((.*)\\)\\s*$", "\\1", part) else NA_character_
    if (!pg_valid_player_name(name)) valid <<- FALSE
    tibble(raw_name = name, section = section, group = NA_integer_, slot = NA_integer_, injury_detail = detail)
  })
  list(entries = bind_rows(pg_empty_entries(), entries), valid = valid)
}

# 2. Retain every listed name, grouping and explicit absence section.
# A status report belongs to the matchup; its prose is never assigned to players.
pg_roster_article <- function(html) {
  if (is.null(html)) return(NULL)
  legacy <- pg_article(html)
  nodes <- xml_find_all(read_html(html), "//p | //h2 | //h3")
  text <- trimws(gsub("[[:space:]\u00a0]+", " ", xml_text(nodes)))
  headings <- which(grepl("^[A-Za-z .'-]+ projected lineup$", text, ignore.case = TRUE))
  blocks <- lapply(seq_along(headings), function(i) {
    index <- headings[i]
    next_rows <- if (index < length(text)) seq.int(index + 1L, length(text)) else integer()
    boundaries <- next_rows[grepl("projected lineup$|^Status report", text[next_rows], ignore.case = TRUE) |
      xml_name(nodes[next_rows]) %in% c("h2", "h3")]
    end <- if (length(boundaries)) boundaries[1] - 1L else length(text)
    body <- if (end > index) text[seq.int(index + 1L, end)] else character()
    body <- body[nzchar(body)]
    absence <- grepl("^(Scratched|Injured):", body, ignore.case = TRUE)
    active <- if (any(absence)) body[seq_len(which(absence)[1] - 1L)] else body
    entries <- pg_empty_entries()
    valid <- length(active) >= 3L
    if (valid) {
      goalies <- tail(active, 2)
      valid <- all(pg_valid_player_name(goalies))
      groups <- head(active, -2)
      entries <- map_dfr(seq_along(groups), function(group) {
        names <- trimws(strsplit(groups[group], "\\s*(?:--|\u2013|\u2014)\\s*", perl = TRUE)[[1]])
        if (!length(names) || any(!pg_valid_player_name(names))) valid <<- FALSE
        tibble(raw_name = names, section = "skater", group = as.integer(group),
          slot = seq_along(names), injury_detail = NA_character_)
      })
      entries <- bind_rows(entries, tibble(raw_name = goalies, section = c("starter", "backup"),
        group = NA_integer_, slot = NA_integer_, injury_detail = NA_character_))
    }
    sections <- list()
    for (section in c("scratched", "injured")) {
      rows <- body[grepl(paste0("^", section, ":"), body, ignore.case = TRUE)]
      section_result <- if (length(rows) == 1L) pg_status_names(rows, section)
        else list(entries = pg_empty_entries(), valid = FALSE)
      entries <- bind_rows(entries, section_result$entries)
      sections[[section]] <- list(valid = section_result$valid, raw = paste(rows, collapse = "\n"))
    }
    # Unexpected text between absence sections is retained as a structural gap.
    if (any(absence) && any(!absence[seq.int(which(absence)[1], length(body))])) valid <- FALSE
    matchup_rows <- which(seq_along(text) < index & xml_name(nodes) == "h2")
    matchup_index <- if (length(matchup_rows)) max(matchup_rows) else NA_integer_
    notes <- character()
    if (!is.na(matchup_index)) {
      later_matchups <- which(seq_along(text) > matchup_index & xml_name(nodes) == "h2")
      matchup_end <- if (length(later_matchups)) later_matchups[1] - 1L else length(text)
      reports <- which(seq_along(text) > index & seq_along(text) <= matchup_end &
        grepl("^Status report", text, ignore.case = TRUE))
      if (length(reports) && reports[1] < matchup_end)
        notes <- text[seq.int(reports[1] + 1L, matchup_end)]
    }
    list(team_label = sub(" projected lineup$", "", text[index], ignore.case = TRUE),
      matchup = if (!is.na(matchup_index)) text[matchup_index] else NA_character_,
      parse_status = if (valid) "parsed" else "unexpected_lineup_structure", entries = entries,
      scratched = sections$scratched, injured = sections$injured, status_notes = paste(notes, collapse = "\n"))
  })
  list(article_date = legacy$article_date, blocks = blocks)
}

# 3. Match names within a team, validate groups against player positions.
pg_resolve_roster_block <- function(block, candidates) {
  entries <- block$entries
  matches <- lapply(entries$raw_name, pg_match, candidates = candidates)
  entries$playerId <- vapply(matches, function(x) x$id, integer(1))
  entries$match_method <- vapply(matches, function(x) x$method, character(1))
  entries$position <- candidates$position[match(entries$playerId, candidates$playerId)]
  entries$forward_line <- NA_integer_; entries$defense_pairs <- NA_integer_
  entries$issue <- ifelse(is.na(entries$playerId), entries$match_method, NA_character_)
  participants <- entries$section %in% c("skater", "starter", "backup")
  status <- block$parse_status
  if (status == "parsed" && any(is.na(entries$playerId[participants]))) status <- "participant_unresolved"
  if (status == "parsed" && anyDuplicated(entries$playerId[participants])) status <- "duplicate_participant"
  if (status == "parsed") {
    skaters <- which(entries$section == "skater")
    groups <- split(skaters, entries$group[skaters])
    group_positions <- vapply(groups, function(rows) {
      positions <- unique(entries$position[rows])
      if (length(positions) == 1L && !is.na(positions) && positions %in% c("F", "D")) positions else "invalid"
    }, character(1))
    forward_groups <- names(groups)[group_positions == "F"]
    defense_groups <- names(groups)[group_positions == "D"]
    counts <- lengths(groups)
    valid_groups <- length(forward_groups) == 4L && length(defense_groups) %in% 3:4 &&
      identical(unname(group_positions), c(rep("F", length(forward_groups)), rep("D", length(defense_groups)))) &&
      all(counts[group_positions == "F"] %in% 1:3) && all(counts[group_positions == "D"] %in% 1:2) &&
      all(entries$position[entries$section %in% c("starter", "backup")] == "G")
    if (!valid_groups) status <- "unexpected_position_structure"
    else {
      for (i in seq_along(forward_groups)) entries$forward_line[groups[[forward_groups[i]]]] <- as.integer(i)
      for (i in seq_along(defense_groups)) entries$defense_pairs[groups[[defense_groups[i]]]] <- as.integer(i)
    }
  }
  absent_ids <- entries$playerId[entries$section %in% c("scratched", "injured") & !is.na(entries$playerId)]
  if (status == "parsed" && any(entries$playerId[participants] %in% absent_ids)) status <- "conflicting_lineup_status"
  if (status == "parsed") status <- "matched"
  sections <- lapply(c("scratched", "injured"), function(section) {
    rows <- entries$section == section
    block[[section]]$valid && all(!is.na(entries$playerId[rows])) && !anyDuplicated(entries$playerId[rows])
  })
  list(entries = entries, status = status, scratched_complete = sections[[1]], injured_complete = sections[[2]])
}

pg_empty_roster <- function() tibble(season = integer(), roster_season = integer(),
  teamId = integer(), team_abbrev = character(), playerId = integer(), first_name = character(),
  last_name = character(), player_name = character(), position = character(), roster_source = character(),
  is_current_roster = logical(), directory_observed_at = character(), observation_id = character(),
  game_id = integer(), game_date = character(), startTimeUTC = character(), gameState = character(),
  opponent_label = character(), retrieved_at = character(), source_url = character(), article_date = character(),
  schema_version = integer(), projection_status = character(), eligible_for_backtest = logical(),
  in_projected_lineup = integer(), forward_line = integer(), defense_pairs = integer(),
  goalie_role = character(), scratched = integer(), injured = integer(), injury_detail = character())

pg_empty_roster_metadata <- function() tibble(observation_id = character(), game_id = integer(),
  teamId = integer(), team_abbrev = character(), game_date = character(), retrieved_at = character(),
  startTimeUTC = character(), article_date = character(), source_url = character(),
  projection_status = character(), eligible_for_backtest = logical())

# 4. Produce whole-team snapshots: incomplete teams never acquire false zeros.
pg_roster_projections <- function(game_teams, directory, parsed, target_date,
                                  observed_at, source_url, observation_id) {
  players <- list(); coverage <- list(); notes <- list(); diagnostics <- list()
  article_date <- if (is.null(parsed)) NA_character_ else parsed$article_date
  for (i in seq_len(nrow(game_teams))) {
    team <- game_teams[i, ]; candidates <- filter(directory, teamId == team$teamId)
    status <- if (is.null(parsed)) "article_unavailable" else if (is.na(article_date) || article_date != format(target_date))
      "stale_or_undated_article" else "ready"
    block <- NULL; resolved <- NULL
    if (!is.null(parsed)) {
      blocks <- Filter(function(x) pg_name(x$team_label) == pg_name(team$team_label), parsed$blocks)
      if (length(blocks) == 1L) {
        block <- blocks[[1]]; resolved <- pg_resolve_roster_block(block, candidates)
      }
      if (status == "ready") {
        status <- if (length(blocks) != 1L) "missing_or_duplicate_team_block" else resolved$status
        if (!is.null(block) && (is.na(block$matchup) || !grepl(pg_name(team$opponent_label), pg_name(block$matchup), fixed = TRUE)))
          status <- "opponent_mismatch"
      }
    }
    pregame <- team$gameState %in% c("FUT", "PRE") && pg_time(observed_at) < pg_time(team$startTimeUTC)
    if (!isTRUE(pregame)) status <- "not_pregame"
    eligible <- status == "matched" && isTRUE(pregame)
    entries <- if (is.null(resolved)) mutate(pg_empty_entries(), playerId = integer(), match_method = character(),
      position = character(), forward_line = integer(), defense_pairs = integer(), issue = character()) else resolved$entries
    participants <- entries$section %in% c("skater", "starter", "backup")
    participant_ids <- entries$playerId[participants]
    # Cached/prior-season identities are lookup evidence, not a current roster.
    universe <- candidates %>% filter(roster_source %in% c("current_roster", "season_roster") |
      playerId %in% entries$playerId) %>% distinct(playerId, .keep_all = TRUE)
    rows <- universe %>% mutate(observation_id = observation_id, game_id = team$game_id,
      game_date = format(target_date), startTimeUTC = team$startTimeUTC, gameState = team$gameState,
      opponent_label = team$opponent_label, retrieved_at = observed_at, source_url = source_url,
      article_date = article_date, schema_version = 1L, projection_status = status, eligible_for_backtest = eligible,
      in_projected_lineup = if (eligible) as.integer(playerId %in% participant_ids) else NA_integer_,
      forward_line = NA_integer_, defense_pairs = NA_integer_, goalie_role = NA_character_,
      scratched = NA_integer_, injured = NA_integer_, injury_detail = NA_character_)
    if (eligible) {
      active <- entries[participants, ]; index <- match(rows$playerId, active$playerId)
      rows$forward_line <- active$forward_line[index]; rows$defense_pairs <- active$defense_pairs[index]
      roles <- active$section[index]; rows$goalie_role <- ifelse(roles %in% c("starter", "backup"), roles, NA_character_)
      for (section in c("scratched", "injured")) {
        absent <- entries[entries$section == section, ]
        rows[[section]] <- if (resolved[[paste0(section, "_complete")]]) as.integer(rows$playerId %in% absent$playerId) else NA_integer_
        if (section == "injured") rows$injury_detail <- absent$injury_detail[match(rows$playerId, absent$playerId)]
      }
    }
    players[[i]] <- rows
    metadata <- tibble(observation_id = observation_id, game_id = team$game_id, teamId = team$teamId,
      team_abbrev = team$team_abbrev, game_date = format(target_date), retrieved_at = observed_at,
      startTimeUTC = team$startTimeUTC, article_date = article_date, source_url = source_url,
      projection_status = status, eligible_for_backtest = eligible)
    coverage[[i]] <- mutate(metadata, participants_listed = sum(participants),
      participants_resolved = sum(participants & !is.na(entries$playerId)),
      forwards = sum(entries$position[participants] == "F", na.rm = TRUE),
      defensemen = sum(entries$position[participants] == "D", na.rm = TRUE),
      scratched_complete = !is.null(resolved) && resolved$scratched_complete,
      injured_complete = !is.null(resolved) && resolved$injured_complete,
      absence_unresolved = sum(entries$section %in% c("scratched", "injured") & is.na(entries$playerId)))
    notes[[i]] <- mutate(metadata, scope = "matchup", matchup = if (is.null(block)) NA_character_ else block$matchup,
      status_notes = if (is.null(block)) NA_character_ else block$status_notes,
      scratched_text = if (is.null(block)) NA_character_ else block$scratched$raw,
      injured_text = if (is.null(block)) NA_character_ else block$injured$raw)
    diagnostics[[i]] <- bind_cols(metadata[rep(1L, nrow(entries)), ], entries)
  }
  # Retain idle current roster identities with unknown game membership.
  idle <- if (nrow(game_teams)) filter(directory, !teamId %in% game_teams$teamId) else directory
  idle <- filter(idle, roster_source %in% c("current_roster", "season_roster")) %>%
    mutate(observation_id = observation_id, game_id = NA_integer_, game_date = format(target_date),
      startTimeUTC = NA_character_, gameState = NA_character_, opponent_label = NA_character_,
      retrieved_at = observed_at, source_url = source_url, article_date = article_date,
      schema_version = 1L, projection_status = if (nrow(game_teams)) "no_game_today" else "no_games",
      eligible_for_backtest = FALSE, in_projected_lineup = NA_integer_, forward_line = NA_integer_,
      defense_pairs = NA_integer_, goalie_role = NA_character_, scratched = NA_integer_, injured = NA_integer_, injury_detail = NA_character_)
  empty_coverage <- mutate(pg_empty_roster_metadata(), participants_listed = integer(), participants_resolved = integer(),
    forwards = integer(), defensemen = integer(), scratched_complete = logical(), injured_complete = logical(), absence_unresolved = integer())
  empty_notes <- mutate(pg_empty_roster_metadata(), scope = character(), matchup = character(),
    status_notes = character(), scratched_text = character(), injured_text = character())
  empty_diagnostics <- bind_cols(pg_empty_roster_metadata(), mutate(pg_empty_entries(), playerId = integer(),
    match_method = character(), position = character(), forward_line = integer(), defense_pairs = integer(), issue = character()))
  list(players = bind_rows(pg_empty_roster(), bind_rows(players), idle),
    coverage = bind_rows(empty_coverage, bind_rows(coverage)), notes = bind_rows(empty_notes, bind_rows(notes)),
    diagnostics = bind_rows(empty_diagnostics, bind_rows(diagnostics)))
}

# 5. Archive new files in the existing immutable run directory/data branch.
pg_collect_rosters <- function(game_teams, goalie_directory, season, previous, target_date,
                               observed_at, source_url, base_path, run_dir) {
  directory <- pg_player_directory(game_teams, goalie_directory, season, previous, base_path, run_dir)
  requests <- readRDS(file.path(run_dir, "requests.rds"))
  valid_html <- any(requests$label == "lineups" & requests$http_status %in% 200L & is.na(requests$error))
  html <- if (valid_html) rawToChar(readBin(file.path(run_dir, "lineups.html"), "raw",
    n = file.info(file.path(run_dir, "lineups.html"))$size)) else NULL
  if (!is.null(html)) Encoding(html) <- "UTF-8"
  parsed <- pg_roster_article(html)
  saveRDS(parsed, file.path(run_dir, "parsed_rosters.rds"))
  result <- pg_roster_projections(game_teams, directory, parsed, target_date, observed_at, source_url, basename(run_dir))
  outputs <- list(projected_roster_df = result$players, roster_coverage = result$coverage,
    roster_notes = result$notes, roster_diagnostics = result$diagnostics,
    roster_eligible_pregame = filter(result$players, eligible_for_backtest %in% TRUE),
    roster_post_start_observations = filter(result$players, projection_status == "not_pregame"))
  for (name in names(outputs)) {
    saveRDS(outputs[[name]], file.path(run_dir, paste0(name, ".rds")))
    write.csv(outputs[[name]], file.path(run_dir, paste0(name, ".csv")), row.names = FALSE)
  }
  saveRDS(result$players, file.path(base_path, "projected_roster_latest.rds"))
  result
}

# Model reads select one entire eligible team snapshot, never mix observations.
read_projected_rosters_asof <- function(game_date, cutoff_utc,
    base_path = file.path(getwd(), "Data", "projected_goalies")) {
  cutoff <- pg_time(cutoff_utc)
  if (length(cutoff) != 1L || is.na(cutoff)) stop("Use a UTC ISO timestamp for cutoff_utc.")
  paths <- list.files(file.path(base_path, "history"), pattern = "^projected_roster_df\\.rds$",
    recursive = TRUE, full.names = TRUE)
  snapshots <- map_dfr(sort(paths), function(path) {
    receipt <- file.path(dirname(path), "run.json")
    status_file <- file.path(dirname(path), "collection_status.txt")
    if (file.exists(receipt) && !identical(fromJSON(receipt)$state, "success")) return(tibble())
    if (!file.exists(receipt) && (!file.exists(status_file) || readLines(status_file, n = 1L) != "success")) return(tibble())
    mutate(readRDS(path), .snapshot_path = path)
  })
  if (!nrow(snapshots)) return(pg_empty_roster())
  snapshots <- snapshots %>% filter(.data$game_date == format(as.Date(.env$game_date)),
    eligible_for_backtest %in% TRUE, pg_time(retrieved_at) <= cutoff,
    pg_time(retrieved_at) < pg_time(startTimeUTC))
  latest <- snapshots %>% distinct(game_id, teamId, retrieved_at, .snapshot_path) %>%
    arrange(retrieved_at, .snapshot_path) %>% group_by(game_id, teamId) %>% slice_tail(n = 1L) %>% ungroup()
  inner_join(snapshots, latest, by = c("game_id", "teamId", "retrieved_at", ".snapshot_path")) %>% select(-.snapshot_path)
}
