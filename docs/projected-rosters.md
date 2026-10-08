# Projected roster data contract

The collector downloads the article and supporting NHL roster responses once.
The roster extension reads those same archived bytes; it adds no HTTP requests.
Source `R/projected_goalies.R` to load both the goalie and roster readers.
The original Hockey_Model and files under `reference/` are not modified.

## Rows and keys

`projected_roster_df.rds` and `.csv` contain one player/team/game row per
observation. The universe contains the fetched current/season roster and any
additional resolved names listed in the article, including scratches/injuries.
Cached/prior-season players enter the output only when explicitly named; they
are identity evidence, not claims of current roster membership. Idle current/
season-roster teams have `game_id = NA` and unknown lineup membership.

- Identity join: `teamId + playerId` (team matters for trades/history).
- Model join: `game_id + teamId + playerId`.
- Archived row key: `observation_id + game_id + teamId + playerId`.

NHL IDs remain integer columns. No synthetic player IDs are invented. Unresolved
article names remain in `roster_diagnostics`, with raw names and match reasons;
they are not fabricated into model-ready player rows.

## Player columns

| Column | Meaning |
|---|---|
| `season`, `roster_season` | Target season and identity-source season |
| `teamId`, `team_abbrev`, `playerId`, `player_name`, `first_name`, `last_name` | Team/player identity |
| `position` | `F`, `D`, or `G`, from the API roster category |
| `roster_source`, `is_current_roster`, `directory_observed_at` | Identity provenance; fallback evidence is labeled |
| `observation_id` | Unique run-folder name, also on coverage/notes/diagnostics |
| `game_id`, `game_date`, `startTimeUTC`, `gameState`, `opponent_label` | Scheduled game and opponent |
| `retrieved_at` | Article response completion UTC; the actual observation cutoff |
| `article_date`, `source_url`, `schema_version` | Article provenance and roster schema version (1) |
| `projection_status`, `eligible_for_backtest` | Whole-team validation and strict pregame eligibility |
| `in_projected_lineup` | Integer 1 for every listed participant, including both goalies; 0 for other output players on a complete eligible team; otherwise NA |
| `forward_line` | Forward group number in published order, normally 1-4; otherwise NA |
| `defense_pairs` | Defense group number in published order, normally 1-3; an explicitly listed extra defense group can be 4; otherwise NA |
| `goalie_role` | `starter`, `backup`, or NA; first-listed goalie is starter |
| `scratched`, `injured` | Explicit section flags, independent of membership; unavailable/malformed/unresolved sections are NA |
| `injury_detail` | Original parenthetical description, including embedded commas |

Numeric placement and status flags are published only for eligible complete
teams. Post-start names/grouping remain in raw files and diagnostics. A zero
membership flag alone never implies injury or scratch status. Missing absence
sections differ from an explicit `None` section: the former produces NA, the
latter produces zeros. An unmatched absence name invalidates that section's
flags, but does not invalidate a fully resolved participant lineup.

## Validation

Every participant must resolve uniquely within the correct team's identity
directory using the existing normalized-name/unique-initial matching rules.
Duplicate participant IDs, position conflicts, contradictory active/absence
lists, duplicate team blocks, or a wrong opponent make the team unknown.
API roster order does not determine line numbers or goalie roles.

Supported structure is four forward groups followed by three or four defense
groups and two individual goalie rows. A forward group can contain 1-3 listed
forwards; a defense group can contain 1-2 listed defensemen. Classification uses
resolved positions, not a fixed count of the first 12 names. Thus 11F/7D and a
single extra defenseman can be parsed; total participant counts are reported
explicitly rather than silently padded to 20. Other structures are retained
with `unexpected_position_structure`/`unexpected_lineup_structure` coverage.
These are published projected groupings, not promises of actual ice-time roles.

Article date must equal the target Chicago date. Game state must be FUT/PRE and
article completion must be strictly before scheduled start, including when a
delayed game still says PRE. Stale/missing articles and incomplete coverage are
expected conditions. Execution/HTTP/decoding/persistence failures fail the run.
Goalie and full-roster coverage are independent: goalie resolution can succeed
while a skater is unresolved, without changing the existing goalie schema.

## Files and model reads

All new files share the existing immutable `Data/projected_goalies/history/`
run folder, preserved on the durable data branch. `player_directory_history.rds`
is restored automatically with Data and accumulates all-position identities.
The existing goalie identity cache is preserved separately.

- `projected_roster_df`: all output players, including idle/unknown rows.
- `roster_coverage`: status, participant resolution/counts, absence-section coverage.
- `roster_diagnostics`: every listed name, resolved ID/position, group/slot,
  matching method, and unmatched/ambiguous issue; inspect alongside coverage.
- `roster_notes`: team/game/observation references, raw absence sections,
  matchup label, and status-report prose with `scope = matchup`. Shared prose
  is repeated for each involved team with that explicit scope; no NLP assigns
  it to individual players or invents availability flags.
- `roster_eligible_pregame`, `roster_post_start_observations`: separate subsets.
- `player_directory.rds`, `parsed_rosters.rds`: identity/parsing evidence.

`read_projected_rosters_asof(game_date, cutoff_utc, base_path)` returns the latest
eligible **whole-team** snapshot observed by the requested cutoff. Equal-time
ties choose one archive path deterministically. Failed/interrupted receipts are
excluded; direct local runs must have a successful `collection_status.txt`.
Later missing/stale/partial/post-start pulls do not erase earlier valid snapshots.
`projected_roster_latest.rds` is only a convenience view of the latest pull.

Archives from before this extension remain byte-for-byte unchanged. The reader
does not fabricate or re-fetch historical rosters. Future backfill should create
separate derived files using the original raw bytes/timestamps, never overwrite
the original observations. Player-performance aggregation and integration into
the separate roster model are subsequent steps; this collector fetches no stats.
