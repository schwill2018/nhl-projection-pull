# Run from the repository root. No user library or startup file is required.
dir.create(".local/R-library", recursive = TRUE, showWarnings = FALSE)
.libPaths(c(normalizePath(".local/R-library"), .Library))
dependencies <- c("dplyr", "purrr", "tibble", "httr", "jsonlite", "xml2", "stringi")
missing <- dependencies[!vapply(dependencies, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing)) install.packages(missing, repos = "https://cloud.r-project.org")
stopifnot(all(vapply(dependencies, requireNamespace, logical(1), quietly = TRUE)),
          packageVersion("dplyr") >= "1.1.1")
