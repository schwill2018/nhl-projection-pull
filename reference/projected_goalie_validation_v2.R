# Offline V1/V2 equivalence: replay saved HTTP responses, never call the network.
.libPaths(c('C:/Users/schne/AppData/Local/R/win-library/4.4', .libPaths()))
fixture <- 'Data/projected_goalies/history/2026-10-06_170120_623c195144ff'
stopifnot(dir.exists(fixture))
original <- new.env(); revised <- new.env()
sys.source('projected_goalie_preprocessing.R', original)
sys.source('projected_goalie_preprocessing_v2.R', revised)
for (scenario in c('normal', 'late', 'stale', 'missing_article', 'season_fallback', 'prior_fallback', 'cached_fallback', 'missing_schedule')) {
  run_replay <- function(environment) {
    environment$Sys.time <- function() as.POSIXct('2026-10-06 17:01:20',tz='UTC')
    environment$pg_now <- function() {
      if (scenario == 'late') return('2026-10-07T02:20:00.000Z')
      '2026-10-06T17:01:20.000Z'
    }
    environment$GET <- function(url, ...) {
      label <- if (grepl('/schedule/',url)) 'schedule' else if (grepl('/standings/',url)) 'standings' else if (grepl('/team$',url)) 'teams' else if (grepl('/roster/',url)) paste0('roster_',strsplit(url,'/')[[1]][6]) else 'lineups'
      extension <- if (label=='lineups') '.html' else '.json'
      path <- file.path(fixture,paste0(label,extension))
      body <- readBin(path,'raw',n=file.info(path)$size)
      fail <- (scenario=='missing_article' && label=='lineups') || (scenario=='missing_schedule' && label=='schedule')
      if (grepl('/roster/',url)) {
        if (scenario %in% c('season_fallback','prior_fallback','cached_fallback') && grepl('/current$',url)) fail <- TRUE
        if (scenario %in% c('prior_fallback','cached_fallback') && grepl('/20262027$',url)) fail <- TRUE
        if (scenario=='cached_fallback') fail <- TRUE
      }
      if (scenario=='stale' && label=='lineups') body <- charToRaw(gsub('2026-10-06','2026-10-05',rawToChar(body),fixed=TRUE))
      structure(list(status_code=if(fail) 503L else 200L,content=body,headers=list(),url=url),class='response')
    }
    output <- tempfile('goalie_v2_replay_');dir.create(output)
    if(scenario=='cached_fallback') saveRDS(readRDS(file.path(fixture,'goalie_directory.rds')),file.path(output,'goalie_directory_history.rds'))
    result <- tryCatch(environment$run_projected_goalies(base_path=output),error=function(error)conditionMessage(error))
    if(is.character(result)) return(sub('goalie_v2_replay_.*','PATH',result))
    list(goalie_df=result$goalie_df,coverage=result$coverage)
  }
  first <- run_replay(original); second <- run_replay(revised)
  # Error paths include independently allocated temp directories.
  if(scenario=='missing_schedule') {
    stopifnot(is.character(first),is.character(second),grepl('Schedule unavailable',first),grepl('Schedule unavailable',second))
  } else {
    stopifnot(isTRUE(all.equal(first,second)))
  }
  cat('PASS:',scenario,'\n')
}
# Run existing name, malformed HTML, and historical cutoff checks against V2.
checks <- readLines('projected_goalie_validation.R')
checks[2] <- 'source("projected_goalie_preprocessing_v2.R")'
eval(parse(text=checks),envir=new.env())
cat('V2 offline equivalence and existing validation passed.\n')
