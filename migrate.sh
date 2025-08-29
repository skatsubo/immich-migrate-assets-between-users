#!/usr/bin/env bash

set -e
set -u
set -o pipefail

# source user (from)
# src_user='alice@immich'

# destination user (to)
# dest_user='bob@immich'

# the "where" condition (filter) to specify which assets to migrate
# it will be put verbatim into the where clause when selecting assets for migration: WHERE ... AND $asset_filter
# example: selecting assets uploaded on 2025-08-27 (e.g. if bulk import on this date went into wrong account by mistake)
#   asset."createdAt" = '2025-08-27'
# you should edit the line between EOFs
asset_filter=$(cat <<'EOF'
1=1
EOF
)

# batch size
batch_size=2

#
# internal vars
#
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
stor_proc_file="$script_dir/migrate.sql"
postgres_container=immich_postgres
postgres_user=postgres
postgres_db=immich

plan_asset="plan-db-asset.txt"
plan_asset_file="plan-db-asset-file.txt"
plan_move="plan-move.txt"

#
# auxiliary functions
#
log() {
    printf '%s\n' "$@" >&2
}

err() {
    echo "ERROR: $*" >&2
}

debug() {
    if [[ -n "${DEBUG:-}" ]] ; then
        echo "debug:" "${FUNCNAME[1]}:" "$@" >&2
    fi
}

#
# migration functions
#
exec_query() {
    local query="$1"
    local psql_args=""
    if [[ ${2:-} == "quiet" ]]; then
        psql_args="-Atq -Pexpanded=off"
    fi
    # print only first line of the query
    debug "Execute SQL query: ${query%%$'\n'*} <...>"
    if ! docker exec "$postgres_container" psql -Ppager=no -Pexpanded=on $psql_args -U "$postgres_user" -d "$postgres_db" -c "$query" ; then
        err "SQL query failed"
        return 1
    fi
}

migrate_db() {
    local op="${1:-plan}"

    # wrap `asset_filter` using PostgreSQL $$...$$ quoting because it contains single quotes
    MIGRATE_SQL="SELECT * FROM migrate_assets_between_users(
        '$src_user',
        '$dest_user',
        \$\$${asset_filter}\$\$,
        $batch_size,
        '$op'
    );"

    if ! exec_query "$MIGRATE_SQL" quiet > "$plan_move" ; then
        err "SQL function migrate_assets_between_users failed."
        exit 1
    fi

    if [[ ! -s $plan_move ]] ; then
        log "WARN: No move commands returned from migration function. DB records migration may have failed or matched no assets."
    fi
}

move_files() {
    if docker exec -i immich_server bash <"$plan_move" ; then
        # TODO set is_file_moved in DB
        log "Moved files"
    else
        log "WARN: errors encountered while executing move commands on immich_server"
    fi
}

get_plan_stats() {
    stats_sql='SELECT
        (SELECT COUNT(*) FROM migrate_between_users_asset WHERE is_db_migrated) AS asset_migrated,
        (SELECT COUNT(*) FROM migrate_between_users_asset WHERE NOT is_db_migrated) AS asset_pending,
        (SELECT COUNT(*) FROM migrate_between_users_asset_file WHERE is_db_migrated) AS asset_file_migrated,
        (SELECT COUNT(*) FROM migrate_between_users_asset_file WHERE NOT is_db_migrated) AS asset_file_pending'
    exec_query "$stats_sql"
}

preview_plan() {
    plan_asset_sql='SELECT * FROM migrate_between_users_asset WHERE NOT is_db_migrated'
    plan_asset_file_sql='SELECT * FROM migrate_between_users_asset_file WHERE NOT is_db_migrated'

    exec_query "$plan_asset_sql" > "$plan_asset"
    exec_query "$plan_asset_file_sql" > "$plan_asset_file"

    asset_count=$(grep -c ' RECORD ' "$plan_asset" 2>/dev/null || echo 0)
    asset_file_count=$(grep -c ' RECORD ' "$plan_asset_file" 2>/dev/null || echo 0)
    move_count=$(grep -c '^mkdir' "$plan_move" 2>/dev/null || echo 0)
}

#
# command line functions
#
cli_print_help() {
    echo
    echo "Immich asset migration tool"
    echo
    echo "Migrates internal assets from one user to another user."
    echo "It directly modifies database records and moves files on disk."
    echo "For more details see https://github.com/skatsubo/immich-migrate-assets-between-users"
    echo
    echo "Usage:"
    echo "  $0 --from <from_user> --to <to_user>              # Migrate all assets from from_user to to_user specified by their emails"
    echo "  $0 --from <from_user> --to <to_user> [--args...]  # Migrate with extra args: asset filter, batch size (see optinal arguments below)"
    echo "  $0 --help                                         # Show this help"
    echo
    echo "Required arguments:"
    echo "  --from <source_user>     Source user (account email)"
    echo "  --to <destination_user>  Destination user (account email)"
    echo
    echo "Optional arguments:"
    echo "  --filter <condition>     SQL \"where\" condition defining which assets to migrate."
    echo "                           It is passed verbatim to the where clause when selecting assets for migration: WHERE ... AND <condition>"
    echo "                           Default: 1=1 (no filtering, everything is migrated)"
    echo "  --batch <number>         Batch size. Limits migration to this number of assets during a single script run."
    echo "                           Default: 2"
    echo
    echo "Examples:"
    echo "  $0 --from alice@immich.internal --to bob@immich.internal"
    echo "  $0 --from alice@immich.internal --to bob@immich.internal --filter "'"asset.\"createdAt\" >= '"'2025-08-27'"'" --batch 10'
    echo
}

parse_args() {
    debug "args:" "$@" "| num args: $#"

    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --from)          src_user="$2"; shift 2 ;;
            --to)            dest_user="$2" ; shift 2 ;;
            --filter)        asset_filter="$2"; shift 2 ;;
            --batch)         batch_size="$2"; shift 2 ;;
            --help|-h)       cli_print_help; exit 0 ;;
            *)               cli_print_help; exit 0 ;;
        esac
    done

    if [[ -z "${src_user:-}" || -z "${dest_user:-}" ]]; then
        echo "Both source user (--from) and destination user (--to) are required."
        cli_print_help
        exit 1
    fi
}

#
# main
#
parse_args "$@"

log "Migrate assets: $src_user -> $dest_user with filter: $asset_filter"

log "1. Create stored procedure: migrate_assets_between_users()"
exec_query "$(<"$stor_proc_file")"

log "2. Get migration overview: total assets to migrate"
SQL_STAT="SELECT u.email as src_user, COUNT(*) num_assets FROM asset JOIN \"user\" u ON asset.\"ownerId\" = u.id WHERE u.email = '$src_user' AND ($asset_filter) GROUP BY src_user"
exec_query "$SQL_STAT"

log "3. Migrate assets in the database: plan"
migrate_db plan

log "4a. Check stats for the current planned DB migration"
get_plan_stats

preview_plan

log "4b. Review the DB migration plans for: $asset_count asset records in $plan_asset, $asset_file_count asset_file records in $plan_asset_file"
debug "Plan for asset table: $(< $plan_asset)"
debug "Plan for asset_file table: $(< $plan_asset_file)"

log "4c. Review the file moving plan: $move_count move commands in $plan_move"
debug "Plan for file moves: $(< $plan_move)"

read -p "Press Enter to continue after reviewing..."

log "5. Migrate assets in the database: apply the DB plan"
migrate_db apply

log "6. Move files on disk"
move_files

log "Migration of the current batch done!
From source user: $src_user
To target user: $dest_user
Files moved (supposedly): $move_count"
