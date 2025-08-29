# Migrate Immich assets between users

[Description](#description) | [How to use](#how-to-use) | [Assumptions](#assumptions) | [Caveats](#caveats) | [Refs](#refs)

## Description

This is a proof of concept for SQL-based migration of assets between Immich users.

The script changes asset ownership from one user (source) to another user (destination).
- It modifies database records directly
- It moves files on disk

Why do that? Discussed on Reddit: [Is there a way to move assets from one user to another user in the same instance?](https://www.reddit.com/r/immich/comments/1n1ewfa/is_there_a_way_to_move_assets_from_one_user_to/)

So I wrote these (ugly) SQL+shell scripts as a response to the Reddit post - out of curiosity and to illustrate Immich's asset storage internals.

## How to use

1. Clone the repo or download two files: [migrate.sh](https://raw.githubusercontent.com/skatsubo/immich-migrate-assets-between-users/refs/heads/main/migrate.sh) and [migrate.sql](https://raw.githubusercontent.com/skatsubo/immich-migrate-assets-between-users/refs/heads/main/migrate.sql).

2. Go to the Immich docker compose directory and run the script. Provide source user and destination user emails as `--from` and `--to` arguments:

```sh
bash /path/to/migrate.sh --from source_user --to destination_user
```

3. It will analyze the records in the database and create a migration plan. This is essentially a dry-run part.
Then it will wait for user confirmation before actually applying changes to the database and moving files.

### Examples

Migrate all assets from Alice to Bob.
```sh
bash /path/to/migrate.sh --from alice@immich.internal --to bob@immich.internal
```

Migrate assets from Alice to Bob with filtering: only migrate assets uploaded since 2025-08-27.
```sh
bash /path/to/migrate.sh --from alice@immich.internal --to bob@immich.internal \
  --filter "asset.\"createdAt\" >= '2025-08-27'"
```

To avoid shell quoting headaches when passing a complex filter use "heredoc" syntax. Place the filter between the EOF's below:
```sh
asset_filter=$(cat <<'EOF'
asset."createdAt" >= '2025-08-27' AND "originalFileName" ILIKE '%screenshot%'
EOF
)

bash /path/to/migrate.sh --from alice@immich.internal --to bob@immich.internal --filter "$asset_filter"
```

### Getting help

Check the usage instructions by providing `--help / -h` or simply run it without arguments:

```
./migrate.sh --help

Immich asset migration tool

Migrates internal assets from one user to another user.
It directly modifies database records and moves files on disk.
For more details see https://github.com/skatsubo/immich-migrate-assets-between-users

Usage:
  ./migrate.sh --from <from_user> --to <to_user>              # Migrate all assets from from_user to to_user specified by their emails
  ./migrate.sh --from <from_user> --to <to_user> [--args...]  # Migrate with extra args: asset filter, batch size (see optinal arguments below)
  ./migrate.sh --help                                         # Show this help

Required arguments:
  --from <source_user>     Source user (account email)
  --to <destination_user>  Destination user (account email)

Optional arguments:
  --filter <condition>     SQL "where" condition defining which assets to migrate.
                           It is passed verbatim to the where clause when selecting assets for migration: WHERE ... AND <condition>
                           Default: 1=1 (no filtering, everything is migrated)
  --batch <number>         Batch size. Limits migration to this number of assets during a single script run.
                           Default: 2

Examples:
  ./migrate.sh --from alice@immich.internal --to bob@immich.internal
  ./migrate.sh --from alice@immich.internal --to bob@immich.internal --filter "asset.\"createdAt\" >= '2025-08-27'" --batch 10
```

## Assumptions

- The tool's purpose is to move/migrate assets from SRC_USER to DEST_USER, effectively changing their ownership.
- Storage Template can be disabled or enabled; the script handles both cases.
  - When Storage Template is **disabled** `originalPath` of an asset looks like `/data/upload/73e98b55-e6bc-4e1b-9c73-6cddd3da30d9/95/68/9568bfea-0358-4f10-89e1-229b6d76db47.heic`
  - When Storage Template is **enabled** `originalPath` of an asset looks like `/data/library/admin/2025/2025-08/image.heic`
- External Library is excluded from processing.
- The tool can migrate all assets or only a subset defined by SQL condition.
- Each run only migrates a chunk (batch) of assets. Batch size is controlled by `--batch` argument. Suggested workflow: begin with small chunk size, check results, then increase chunk size.
- Media location inside the container is assumed to be default: `/data`.
- Supported Immich versions: v1.137+.

## Caveats

> [!WARNING]
> This is a quick PoC and work-in-progress. It is not secure against SQL injections, shell injections and other irregularities in data. Try it on a throwaway Immich instance first.
>
> Direct altering of the Immich database as in this PoC is not recommended nor supported. Consider using Immich API or do full re-upload.

- The script does not handle people/faces currently. So auto-recognized people/faces are not migrated and will be left in inconsistent state. Remove them manually.
- The script does not check for duplicates. It will error out if a migrated asset is already present in the target user's library.

## Refs

The script updates the following tables/columns in the database (see `migrate.sql` for implementation)
- `asset` table
  - `originalPath`
  - `encodedVideoPath`
  - `sidecarPath`
- `asset_file` table
  - path

<details><summary>Structure of `asset` and `asset_file` tables.</summary>

```sh
immich=# \d asset
                                          Table "public.asset"
      Column      |           Type           | Collation | Nullable |              Default
------------------+--------------------------+-----------+----------+-----------------------------------
 id               | uuid                     |           | not null | uuid_generate_v4()
 deviceAssetId    | character varying        |           | not null |
 ownerId          | uuid                     |           | not null |
 deviceId         | character varying        |           | not null |
 type             | character varying        |           | not null |
 originalPath     | character varying        |           | not null |
 fileCreatedAt    | timestamp with time zone |           | not null |
 fileModifiedAt   | timestamp with time zone |           | not null |
 isFavorite       | boolean                  |           | not null | false
 duration         | character varying        |           |          |
 encodedVideoPath | character varying        |           |          | ''::character varying
 checksum         | bytea                    |           | not null |
 livePhotoVideoId | uuid                     |           |          |
 updatedAt        | timestamp with time zone |           | not null | now()
 createdAt        | timestamp with time zone |           | not null | now()
 originalFileName | character varying        |           | not null |
 sidecarPath      | character varying        |           |          |
 thumbhash        | bytea                    |           |          |
 isOffline        | boolean                  |           | not null | false
 libraryId        | uuid                     |           |          |
 isExternal       | boolean                  |           | not null | false
 deletedAt        | timestamp with time zone |           |          |
 localDateTime    | timestamp with time zone |           | not null |
 stackId          | uuid                     |           |          |
 duplicateId      | uuid                     |           |          |
 status           | assets_status_enum       |           | not null | 'active'::assets_status_enum
 updateId         | uuid                     |           | not null | immich_uuid_v7()
 visibility       | asset_visibility_enum    |           | not null | 'timeline'::asset_visibility_enum

immich=# \d asset_file
                            Table "public.asset_file"
  Column   |           Type           | Collation | Nullable |      Default
-----------+--------------------------+-----------+----------+--------------------
 id        | uuid                     |           | not null | uuid_generate_v4()
 assetId   | uuid                     |           | not null |
 createdAt | timestamp with time zone |           | not null | now()
 updatedAt | timestamp with time zone |           | not null | now()
 type      | character varying        |           | not null |
 path      | character varying        |           | not null |
 updateId  | uuid                     |           | not null | immich_uuid_v7()
Foreign-key constraints:
    "asset_file_assetId_fkey" FOREIGN KEY ("assetId") REFERENCES asset(id) ON UPDATE CASCADE ON DELETE CASCADE
```
</details>

The script _does not_ handle `person` table, this is out of scope currently:
- `person` table
  - `thumbnailPath`
