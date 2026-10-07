# Offline checks: Rscript projected_goalie_validation.R
source("projected_goalie_preprocessing.R")
candidates <- tibble(playerId = 1:3, first_name = c("Juuse", "Matt", "Mark"),
  last_name = c("Saros", "Murray", "Murray"),
  player_name = c("Juuse Saros", "Matt Murray", "Mark Murray"))
stopifnot(pg_match("Juuse A. Saros", candidates)$id == 1L,
          pg_match("J. Saros", candidates)$id == 1L,
          pg_match("Matt Murray", candidates)$id == 2L,
          pg_match("M. Murray", candidates)$method == "ambiguous",
          pg_match("Unknown Goalie", candidates)$method == "unmatched",
          pg_name("Jos\u00e9 D\u2019Amour") == pg_name("Jose D'Amour"))
html <- paste0('<html><script type="application/ld+json">',
  '{"datePublished":"2026-10-06T16:52:00Z"}</script>',
  '<h2>PREDATORS at MAPLE LEAFS</h2><p>Predators projected lineup</p>',
  '<p>A Forward -- Another Forward</p><p>Juuse Saros</p><p>Matt Murray</p>',
  '<p>Scratched: Someone Else</p><p>Injured: Justus Annunen</p></html>')
a <- pg_article(html)
stopifnot(a$article_date == "2026-10-06", a$blocks$projected_name == "Juuse Saros",
          a$blocks$backup_name == "Matt Murray")
bad <- pg_article(sub('<p>Matt Murray</p>', '', html, fixed = TRUE))
stopifnot(bad$blocks$parse_status == "unexpected_lineup_structure")

# A changed starter must replace the whole earlier team snapshot. No future rows.
scratch <- tempfile("pg_validation_"); dir.create(file.path(scratch, "history"), recursive = TRUE)
for (i in 1:2) {
  dir.create(file.path(scratch, "history", as.character(i)))
  x <- tibble(game_id = 2026020044L, teamId = 18L, playerId = 1:2,
    game_date = "2026-10-06", retrieved_at = sprintf("2026-10-06T%02d:00:00Z", 10+i),
    startTimeUTC = "2026-10-06T23:00:00Z", eligible_for_backtest = TRUE,
    projected_goalie = as.integer(1:2 == i))
  saveRDS(x, file.path(scratch, "history", as.character(i), "projected_goalie_df.rds"))
}
early <- read_projected_goalies_asof("2026-10-06", "2026-10-06T11:30:00Z", scratch)
late <- read_projected_goalies_asof("2026-10-06", "2026-10-06T12:30:00Z", scratch)
stopifnot(early$playerId[early$projected_goalie == 1] == 1L,
          late$playerId[late$projected_goalie == 1] == 2L, nrow(late) == 2L,
          nrow(read_projected_goalies_asof("2026-10-06", "2026-10-06T10:00:00Z", scratch)) == 0L)

# Validate saved real data when available, without any network calls.
latest <- file.path("Data", "projected_goalies", "projected_goalie_latest.rds")
if (file.exists(latest)) {
  x <- readRDS(latest)
  stopifnot(!anyDuplicated(x[c("game_id", "teamId", "playerId")]))
  matched <- filter(x, projection_status == "matched") %>%
    group_by(game_id, teamId) %>% summarise(n = sum(projected_goalie), .groups = "drop")
  stopifnot(all(matched$n == 1L),
    all(is.na(x$projected_goalie[x$projection_status != "matched"])))
}
cat("Projected goalie validation passed.\n")
