-- garage-pro :: owned_vehicles
--
-- Import once into your server database (the fxmanifest runs it automatically
-- via oxmysql on first start, but importing by hand is fine too). Safe to run
-- repeatedly — it only creates the table if it does not already exist.
--
-- Column meaning:
--   stored           1 = in a garage, 0 = out in the world (or impounded)
--   garage_location  index into Config.Garages where it is stored
--   impound_location 'impound' when towed, NULL otherwise
--   impounded_at     timestamp of the tow (for future storage-fee curves)

CREATE TABLE IF NOT EXISTS owned_vehicles (
    id               INT AUTO_INCREMENT PRIMARY KEY,
    owner            VARCHAR(64)  NOT NULL,
    plate            VARCHAR(8)   NOT NULL UNIQUE,
    model            VARCHAR(64)  NOT NULL,
    vehtype          VARCHAR(16)  NOT NULL DEFAULT 'automobile',
    stored           TINYINT(1)   NOT NULL DEFAULT 1,
    garage_location  INT          DEFAULT NULL,
    impound_location VARCHAR(64)  DEFAULT NULL,
    impounded_at     DATETIME     DEFAULT NULL,
    created_at       DATETIME     DEFAULT CURRENT_TIMESTAMP,
    updated_at       DATETIME     DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    KEY owner (owner),
    KEY stored (stored),
    KEY impound_location (impound_location)
);
