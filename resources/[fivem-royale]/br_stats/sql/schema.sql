-- FiveM Royale -- persistent stats schema.
--
-- Apply with:
--   sudo mariadb -u root -p fivem_royale < br_stats/sql/schema.sql
--
-- Safe to re-run: every statement is IF NOT EXISTS.
--
-- Design notes:
--   * `license` is the Rockstar license identifier, which is stable across name
--     changes and reconnects. Names are stored for display only and are expected
--     to change.
--   * Writes happen on join and at match end, nowhere else. There is no
--     per-tick persistence, so the DB is never in the gameplay hot path.
--   * Aggregates on br_players are denormalised counters rather than being
--     derived from br_match_players. Leaderboards read one indexed table
--     instead of aggregating match history on every request.

SET NAMES utf8mb4;

-- ---------------------------------------------------------------------------
-- Players
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `br_players` (
  `license`       VARCHAR(64)  NOT NULL,
  `name`          VARCHAR(64)  NOT NULL DEFAULT 'Unknown',

  `xp`            BIGINT UNSIGNED NOT NULL DEFAULT 0,
  `level`         INT UNSIGNED    NOT NULL DEFAULT 1,

  `matches`       INT UNSIGNED NOT NULL DEFAULT 0,
  `wins`          INT UNSIGNED NOT NULL DEFAULT 0,
  `top10s`        INT UNSIGNED NOT NULL DEFAULT 0,
  `kills`         INT UNSIGNED NOT NULL DEFAULT 0,
  `deaths`        INT UNSIGNED NOT NULL DEFAULT 0,
  `downs`         INT UNSIGNED NOT NULL DEFAULT 0,
  `revives`       INT UNSIGNED NOT NULL DEFAULT 0,
  `damage_dealt`  BIGINT UNSIGNED NOT NULL DEFAULT 0,
  `playtime_sec`  BIGINT UNSIGNED NOT NULL DEFAULT 0,

  `created_at`    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `last_seen`     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
                               ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (`license`),
  -- Leaderboards sort on these; without the indexes every board is a full scan.
  KEY `idx_wins`   (`wins` DESC),
  KEY `idx_kills`  (`kills` DESC),
  KEY `idx_xp`     (`xp` DESC)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- Matches
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `br_matches` (
  `id`            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `mode`          VARCHAR(16)  NOT NULL DEFAULT 'solo',
  `started_at`    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `ended_at`      TIMESTAMP    NULL DEFAULT NULL,
  `player_count`  INT UNSIGNED NOT NULL DEFAULT 0,
  `winning_squad` VARCHAR(32)  NULL DEFAULT NULL,
  `duration_sec`  INT UNSIGNED NOT NULL DEFAULT 0,

  PRIMARY KEY (`id`),
  KEY `idx_started` (`started_at` DESC)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- Per-player match results
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `br_match_players` (
  `match_id`      BIGINT UNSIGNED NOT NULL,
  `license`       VARCHAR(64)  NOT NULL,
  `name`          VARCHAR(64)  NOT NULL DEFAULT 'Unknown',

  `placement`     INT UNSIGNED NOT NULL DEFAULT 0,
  `squad_id`      VARCHAR(32)  NULL DEFAULT NULL,
  `kills`         INT UNSIGNED NOT NULL DEFAULT 0,
  `downs`         INT UNSIGNED NOT NULL DEFAULT 0,
  `revives`       INT UNSIGNED NOT NULL DEFAULT 0,
  `damage`        INT UNSIGNED NOT NULL DEFAULT 0,
  `survived_ms`   INT UNSIGNED NOT NULL DEFAULT 0,
  `xp_earned`     INT UNSIGNED NOT NULL DEFAULT 0,

  PRIMARY KEY (`match_id`, `license`),
  KEY `idx_license` (`license`),
  -- Deleting a match cleans up its rows; a player row surviving its match would
  -- corrupt any later per-match reporting.
  CONSTRAINT `fk_mp_match`
    FOREIGN KEY (`match_id`) REFERENCES `br_matches` (`id`)
    ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
