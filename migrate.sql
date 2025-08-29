-- migration: stored proc
-- CALL migrate_assets_between_users(src_user, dest_user, asset_filter, batch_size, op);

CREATE OR REPLACE FUNCTION migrate_assets_between_users(
  src_user TEXT,
  dest_user TEXT,
  asset_filter TEXT,
  batch_size INT DEFAULT 2,
  op TEXT DEFAULT 'plan'
)
RETURNS SETOF TEXT
LANGUAGE plpgsql
AS $$
DECLARE
  src_user_id UUID;
  dest_user_id UUID;
  src_user_storage_label TEXT;
  dest_user_storage_label TEXT;
  media_location TEXT := '/data';
  upload_dir TEXT;
  library_dir TEXT;
  thumbs_dir TEXT;
  encoded_dir TEXT;

  last_state RECORD;
  invocation_args_changed BOOLEAN := false;
BEGIN
  -- parse requested operation
  op := LOWER(TRIM(op));
  IF op NOT IN (
    'plan', 'apply'
  ) THEN
    RAISE EXCEPTION 'Invalid operation: "%". Valid ops: plan, apply', op;
  END IF;

  -- define base paths
  upload_dir := media_location || '/upload';
  library_dir := media_location || '/library';
  thumbs_dir := media_location || '/thumbs';
  encoded_dir := media_location || '/encoded-video';

  -- resolve user IDs
  SELECT id INTO src_user_id FROM "user" WHERE email = src_user;
  SELECT id INTO dest_user_id FROM "user" WHERE email = dest_user;
  IF src_user_id IS NULL THEN
    RAISE EXCEPTION 'Source user not found: %', src_user;
  END IF;
  IF dest_user_id IS NULL THEN
    RAISE EXCEPTION 'Destination user not found: %', dest_user;
  END IF;

  -- resolve user storage labels
  SELECT COALESCE("storageLabel", src_user_id::TEXT) INTO src_user_storage_label FROM "user" WHERE email = src_user;
  SELECT COALESCE("storageLabel", dest_user_id::TEXT) INTO dest_user_storage_label FROM "user" WHERE email = dest_user;

  -- create state tables if not exist
  SET LOCAL client_min_messages = warning;
  CREATE TABLE IF NOT EXISTS migrate_assets_between_users_state (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    src_user TEXT NOT NULL,
    dest_user TEXT NOT NULL,
    asset_filter TEXT NOT NULL,
    batch_size INT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
  );
  -- DROP TABLE IF EXISTS migrate_between_users_asset;
  CREATE TABLE IF NOT EXISTS migrate_between_users_asset (
    asset_id UUID PRIMARY KEY,
    old_ownerId UUID,
    new_ownerId UUID,
    old_originalPath TEXT NOT NULL,
    new_originalPath TEXT,
    old_encodedVideoPath TEXT,
    new_encodedVideoPath TEXT,
    old_sidecarPath TEXT,
    new_sidecarPath TEXT,
    is_skipped BOOLEAN NOT NULL DEFAULT false,
    skip_reason TEXT,
    is_db_migrated BOOLEAN NOT NULL DEFAULT false,
    is_file_moved BOOLEAN NOT NULL DEFAULT false,
    mv_command_original TEXT,
    mv_command_sidecar TEXT,
    mv_command_encoded TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
  );
  -- DROP TABLE IF EXISTS migrate_between_users_asset_file;
  CREATE TABLE IF NOT EXISTS migrate_between_users_asset_file (
    asset_file_id UUID PRIMARY KEY,
    asset_id UUID,
    old_path TEXT NOT NULL,
    new_path TEXT,
    is_skipped BOOLEAN NOT NULL DEFAULT false,
    skip_reason TEXT,
    is_db_migrated BOOLEAN NOT NULL DEFAULT false,
    is_file_moved BOOLEAN NOT NULL DEFAULT false,
    mv_command_thumb TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
  );

  -- persist state table between runs of the same migration
  -- truncate if new migration detected (based on the arguments change, e.g. if src/dest users or filter have changed)
  SELECT * INTO last_state
  FROM migrate_assets_between_users_state
  ORDER BY created_at DESC
  LIMIT 1;

  IF last_state IS NOT NULL THEN
    IF (last_state.src_user, last_state.dest_user, last_state.asset_filter)
       IS DISTINCT FROM (src_user, dest_user, asset_filter) THEN
      invocation_args_changed := true;
    END IF;
  ELSE
    -- this is first run (no last_state)
    invocation_args_changed := true;
  END IF;

  IF invocation_args_changed THEN
    TRUNCATE TABLE migrate_between_users_asset;
    TRUNCATE TABLE migrate_between_users_asset_file;
  END IF;

  -- generate migration plans
  IF op = 'plan' THEN

    -- generate migration plan for `asset`
    EXECUTE format('
      INSERT INTO migrate_between_users_asset (
        asset_id,
        old_originalPath,
        new_originalPath,
        old_encodedVideoPath,
        new_encodedVideoPath,
        old_sidecarPath,
        new_sidecarPath,
        mv_command_original,
        mv_command_encoded,
        mv_command_sidecar,
        old_ownerId,
        new_ownerId
      )
      SELECT
        id,
        "originalPath",
        REPLACE(REPLACE("originalPath",
          $1, $2),
          $3, $4),
        "encodedVideoPath",
        REPLACE("encodedVideoPath",
          $5, $6),
        "sidecarPath",
        REPLACE("sidecarPath",
          $7, $8),
        -- mv_command_original
        ''mkdir -p "'' || dirname(REPLACE(REPLACE("originalPath", $1, $2), $3, $4)) || ''" && mv "'' || "originalPath" || ''" "'' || 
          REPLACE(REPLACE("originalPath", $1, $2), $3, $4) || ''"'',
        -- mv_command_encoded
        CASE WHEN ("encodedVideoPath" IS NOT NULL) AND ("encodedVideoPath" != '''') THEN
          ''mkdir -p "'' || dirname(REPLACE("encodedVideoPath", $5, $6)) || ''" && mv "'' || "encodedVideoPath" || ''" "'' || 
            REPLACE("encodedVideoPath", $5, $6) || ''"''
        END,
        -- mv_command_sidecar
        CASE WHEN "sidecarPath" IS NOT NULL THEN
          ''mkdir -p "'' || dirname(REPLACE("sidecarPath", $7, $8)) || ''" && mv "'' || "sidecarPath" || ''" "'' || 
            REPLACE("sidecarPath", $7, $8) || ''"''
        END,
        $9,
        $10
      FROM asset
      WHERE "ownerId" = $9
        AND (%s)
        AND NOT "isExternal"
        AND "originalPath" LIKE ($11 || ''/%%'')
        -- AND "originalPath" !~ ''[\\$''''\\x00-\\x1F]''
        -- AND ("encodedVideoPath" IS NULL OR "encodedVideoPath" !~ ''[\\$''''\\x00-\\x1F]'')
        -- AND ("sidecarPath" IS NULL OR "sidecarPath" !~ ''[\\$''''\\x00-\\x1F]'')
      ORDER BY id
      LIMIT %s
      ON CONFLICT (asset_id) DO NOTHING',
      asset_filter, batch_size)
    USING
      upload_dir || '/' || src_user_id,
      upload_dir || '/' || dest_user_id,
      library_dir || '/' || src_user_storage_label,
      library_dir || '/' || dest_user_storage_label,
      encoded_dir || '/' || src_user_id,
      encoded_dir || '/' || dest_user_id,
      upload_dir || '/' || src_user_id,
      upload_dir || '/' || dest_user_id,
      src_user_id,
      dest_user_id,
      media_location;

    -- generate migration plan for `asset_file`
    INSERT INTO migrate_between_users_asset_file (
      asset_file_id,
      asset_id,
      old_path,
      new_path,
      mv_command_thumb
    )
    SELECT
      af.id,
      af."assetId",
      af."path",
      REPLACE(af."path", thumbs_dir || '/' || src_user_id, thumbs_dir || '/' || dest_user_id),
      'mkdir -p "' || dirname(REPLACE(af."path", thumbs_dir || '/' || src_user_id, thumbs_dir || '/' || dest_user_id)) ||
      '" && mv "' || af."path" || '" "' ||
      REPLACE(af."path", thumbs_dir || '/' || src_user_id, thumbs_dir || '/' || dest_user_id) || '"'
    FROM asset_file af
    JOIN migrate_between_users_asset m ON af."assetId" = m.asset_id
    -- WHERE af."path" LIKE (thumbs_dir || '/' || src_user_id || '/%')
    ORDER BY af.id
    ON CONFLICT (asset_file_id) DO NOTHING;

    -- update state/metadata after successful insert
    DELETE FROM migrate_assets_between_users_state;
    INSERT INTO migrate_assets_between_users_state (src_user, dest_user, asset_filter, batch_size)
    VALUES (src_user, dest_user, asset_filter, batch_size);
  END IF;

  -- update asset records in the database
  IF op = 'apply' THEN

    -- update `asset` table
    UPDATE asset
    SET
      "ownerId" = dest_user_id,
      "originalPath" = mua.new_originalPath,
      "encodedVideoPath" = mua.new_encodedVideoPath,
      "sidecarPath" = mua.new_sidecarPath
    FROM migrate_between_users_asset mua
    WHERE asset.id = mua.asset_id
      AND NOT is_db_migrated;

    -- update `asset_file` table
    UPDATE asset_file
    SET "path" = mua.new_path
    FROM migrate_between_users_asset_file mua
    WHERE asset_file.id = mua.asset_file_id
      AND NOT is_db_migrated;

    -- mark as migrated in the state tables
    UPDATE migrate_between_users_asset SET is_db_migrated = true;
    UPDATE migrate_between_users_asset_file SET is_db_migrated = true;
  END IF;

  -- return move commands
  RETURN QUERY
  SELECT mv_command_original FROM migrate_between_users_asset WHERE mv_command_original IS NOT NULL AND NOT is_file_moved
  UNION ALL
  SELECT mv_command_sidecar FROM migrate_between_users_asset WHERE mv_command_sidecar IS NOT NULL AND NOT is_file_moved
  UNION ALL
  SELECT mv_command_encoded FROM migrate_between_users_asset WHERE mv_command_encoded IS NOT NULL AND NOT is_file_moved
  UNION ALL
  SELECT mv_command_thumb FROM migrate_between_users_asset_file WHERE mv_command_thumb IS NOT NULL AND NOT is_file_moved;

END;
$$;

-- helper: dirname function returns directory of a file
CREATE OR REPLACE FUNCTION dirname(path TEXT) RETURNS TEXT AS $$
  SELECT rtrim(regexp_replace($1, '[^/]+/?$', '', 'g'), '/');
$$ LANGUAGE SQL IMMUTABLE;
