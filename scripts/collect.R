# Rscript --vanilla scripts/collect.R [isolated-output-directory]
# Actions provides PG_RUN_DIR; local runs always allocate a fresh directory.
if (dir.exists(".local/R-library")) .libPaths(c(normalizePath(".local/R-library"), .libPaths()))
args <- commandArgs(trailingOnly = TRUE)
base_path <- if (length(args)) args[1] else file.path("Data", "projected_goalies")
dir.create(file.path(base_path, "history"), recursive = TRUE, showWarnings = FALSE)
run_dir <- Sys.getenv("PG_RUN_DIR", "")
if (!nzchar(run_dir)) run_dir <- tempfile(paste0(
  format(Sys.time(), "%Y-%m-%d_%H%M%S_", tz = "UTC")), tmpdir = file.path(base_path, "history"))
dir.create(run_dir, recursive = TRUE, showWarnings = FALSE)
writeLines("running", file.path(run_dir, "collection_status.txt"))
error_message <- NULL
result <- tryCatch({
  source("R/projected_goalies.R")
  run_projected_goalies(base_path = base_path, run_dir = run_dir)
}, error = function(e) {
  error_message <<- conditionMessage(e)
  NULL
})
coverage_file <- file.path(run_dir, "coverage.rds")
coverage <- if (file.exists(coverage_file)) readRDS(coverage_file) else NULL
lines <- c("# NHL projected-goalie collection", "", paste("Observation:", basename(run_dir)), "",
  if (is.null(error_message)) "Collection completed." else paste("**FAILED:**", error_message), "")
if (!is.null(coverage) && nrow(coverage)) {
  matched <- sum(coverage$projection_status == "matched")
  lines <- c(lines, paste("Article date:", paste(unique(ifelse(is.na(coverage$article_date), "unknown", coverage$article_date)), collapse = ", ")), "",
    sprintf("Eligible matched teams: **%d / %d**. Other teams: **%d**.",
    matched, nrow(coverage), nrow(coverage) - matched), "",
    "| Team | Opponent | Projected name | NHL ID | Status | Observed UTC |", "|---|---|---|---|---|---|")
  clean <- function(x) {
    x <- as.character(x); x[is.na(x)] <- "unknown"
    gsub("[|\r\n]", " ", x)
  }
  for (i in seq_len(nrow(coverage))) lines <- c(lines, paste0("| ", paste(clean(c(
    coverage$team_abbrev[i], coverage$opponent_label[i], coverage$projected_name[i],
    coverage$projected_playerId[i], coverage$projection_status[i], coverage$retrieved_at[i])), collapse = " | "), " |"))
} else lines <- c(lines, if (is.null(error_message)) "No games scheduled today." else "Coverage was not produced.")
requests_file <- file.path(run_dir, "requests.rds")
if (file.exists(requests_file)) {
  requests <- readRDS(requests_file)
  failed <- is.na(requests$http_status) | requests$http_status != 200L | !is.na(requests$error)
  lines <- c(lines, "", paste("Archived requests:", nrow(requests), "; unsuccessful requests:", sum(failed)),
    "Roster fallbacks are labeled in goalie_directory.rds; inspect requests.csv for request errors.")
}
lines <- c(lines, "", "Pregame eligibility requires FUT/PRE and observation strictly before scheduled puck drop.",
  "Use timestamped history/as-of reads for modeling. A later incomplete pull does not erase earlier observations.")
writeLines(lines, file.path(run_dir, "summary.md"))
writeLines(if (is.null(error_message)) "success" else c("failure", error_message),
  file.path(run_dir, "collection_status.txt"))
cat(paste(lines, collapse = "\n"), "\n")
summary_path <- Sys.getenv("GITHUB_STEP_SUMMARY", "")
if (nzchar(summary_path)) cat(paste(lines, collapse = "\n"), "\n", file = summary_path, append = TRUE)
if (!is.null(error_message)) quit(status = 1L)
