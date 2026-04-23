#!/bin/bash
# Migrate legacy Docker volumes (pulp_*, park_*, devstack_*) into the
# freshmile-infra stack (freshmile-infra_*_data).
#
# Scope: mysql, redis, elasticsearch.
# Behavior:
#   - Detects which legacy source volumes exist per service
#   - Prompts user to pick a source when several are found
#   - Prompts before overwriting a non-empty target volume
#   - Never deletes legacy volumes (mounted read-only during copy)
#
# Flags:
#   --dry-run   Show what would happen without creating/copying anything
#   -h|--help   Show usage

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

ok()      { echo -e "${GREEN}[OK]${NC}   $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail()    { echo -e "${RED}[FAIL]${NC} $1"; }
info()    { echo -e "${BLUE}[..]${NC}   $1"; }
section() { echo -e "\n${BLUE}── $1${NC}"; }

SERVICES=("mysql" "redis" "elasticsearch")
SOURCE_PREFIXES=("park" "pulp" "devstack")
TARGET_PROJECT="freshmile-infra"

DRY_RUN=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [--dry-run]

Migrates legacy Docker volumes into the freshmile-infra stack:
  park_<svc>_data, pulp_<svc>_data, devstack_<svc>_data
      ─▶ freshmile-infra_<svc>_data

Services: ${SERVICES[*]}

Options:
  --dry-run    Show actions without creating/copying anything
  -h, --help   Show this help
EOF
}

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown argument: $arg"; usage; exit 1 ;;
    esac
done

# ─── Pre-checks ──────────────────────────────────────────────────────────────
section "Pre-checks"

if ! command -v docker &>/dev/null; then
    fail "Docker is not installed"
    exit 1
fi
ok "Docker CLI found"

if ! docker info &>/dev/null; then
    fail "Docker daemon is not running"
    exit 1
fi
ok "Docker daemon reachable"

RUNNING=$(docker ps --format '{{.Names}}' | grep -E '^freshmile-' || true)
if [ -n "$RUNNING" ]; then
    fail "Containers from the freshmile-infra stack are running:"
    echo "$RUNNING" | sed 's/^/       - /'
    echo -e "       ${YELLOW}→${NC} stop them first: make infra-down"
    exit 1
fi
ok "No freshmile-infra container is running"

if [ "$DRY_RUN" -eq 1 ]; then
    warn "Dry-run mode: no volume will be created or modified"
fi

# ─── Helpers ─────────────────────────────────────────────────────────────────

volume_exists() {
    docker volume inspect "$1" &>/dev/null
}

# Returns 0 if volume is empty (or does not exist), 1 otherwise.
volume_is_empty() {
    local vol="$1"
    if ! volume_exists "$vol"; then
        return 0
    fi
    local count
    count=$(docker run --rm -v "$vol":/vol busybox sh -c \
        'ls -A /vol 2>/dev/null | wc -l' | tr -d ' ')
    [ "$count" = "0" ]
}

volume_size() {
    local vol="$1"
    docker run --rm -v "$vol":/vol busybox sh -c 'du -sh /vol 2>/dev/null | cut -f1'
}

prompt_yes_no() {
    local prompt="$1"
    local answer
    read -r -p "$prompt [y/N] " answer </dev/tty
    [[ "$answer" =~ ^[yY]$ ]]
}

# Prints the chosen source on stdout, or empty string to skip.
pick_source() {
    local service="$1"; shift
    local -a sources=("$@")
    local n=${#sources[@]}

    if [ "$n" -eq 1 ]; then
        local src="${sources[0]}"
        local size; size=$(volume_size "$src")
        echo -e "       Only one source found: ${GREEN}${src}${NC} (${size})" >&2
        if prompt_yes_no "       Use ${src} as source for ${service}?" >&2; then
            echo "$src"
        else
            echo ""
        fi
        return
    fi

    echo "       Multiple sources found for ${service}:" >&2
    local i=1
    for s in "${sources[@]}"; do
        local size; size=$(volume_size "$s")
        printf "         %d) %-28s %s\n" "$i" "$s" "$size" >&2
        i=$((i + 1))
    done
    echo "         $i) skip" >&2

    local max=$i
    local choice
    while true; do
        read -r -p "       Pick a source [1-$max]: " choice </dev/tty
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$max" ]; then
            if [ "$choice" -eq "$max" ]; then
                echo ""
            else
                echo "${sources[$((choice - 1))]}"
            fi
            return
        fi
        echo "       Invalid choice" >&2
    done
}

# Copy /from → /to with a live progress bar rendered from inside busybox.
# Progress is computed from `du -sb` on the target volume; bar and ETA-free
# percentage are printed to stderr on a single self-refreshing line.
copy_with_progress() {
    local src="$1" dst="$2"
    docker run --rm \
        -v "$src":/from:ro \
        -v "$dst":/to \
        busybox sh -c '
            total=$(du -sb /from 2>/dev/null | cut -f1)
            [ -z "$total" ] && total=0
            total_h=$(du -sh /from 2>/dev/null | cut -f1)
            [ -z "$total_h" ] && total_h="?"

            cp -a /from/. /to/ &
            cp_pid=$!

            bar=40
            while kill -0 "$cp_pid" 2>/dev/null; do
                cur=$(du -sb /to 2>/dev/null | cut -f1)
                [ -z "$cur" ] && cur=0
                cur_h=$(du -sh /to 2>/dev/null | cut -f1)
                [ -z "$cur_h" ] && cur_h="0"

                if [ "$total" -gt 0 ]; then
                    pct=$(( cur * 100 / total ))
                else
                    pct=0
                fi
                [ "$pct" -gt 100 ] && pct=100

                filled=$(( pct * bar / 100 ))
                empty=$(( bar - filled ))
                fbar=$(printf "%${filled}s" | tr " " "#")
                ebar=$(printf "%${empty}s" | tr " " "-")
                printf "\r       [%s%s] %3d%%  %s / %s      " \
                    "$fbar" "$ebar" "$pct" "$cur_h" "$total_h" >&2
                sleep 1
            done

            wait "$cp_pid"
            rc=$?

            final_h=$(du -sh /to 2>/dev/null | cut -f1)
            full=$(printf "%40s" | tr " " "#")
            if [ "$rc" -eq 0 ]; then
                printf "\r       [%s] 100%%  %s / %s      \n" \
                    "$full" "$final_h" "$total_h" >&2
            else
                printf "\r\n" >&2
            fi
            exit $rc
        '
}

human_duration() {
    local s="$1"
    if [ "$s" -lt 60 ]; then
        printf "%ds" "$s"
    elif [ "$s" -lt 3600 ]; then
        printf "%dm%02ds" "$((s / 60))" "$((s % 60))"
    else
        printf "%dh%02dm" "$((s / 3600))" "$(((s % 3600) / 60))"
    fi
}

# Require the exact literal string "yes" (not y/Y). Used for destructive ops.
prompt_literal_yes() {
    local prompt="$1"
    local answer
    read -r -p "$prompt " answer </dev/tty
    [ "$answer" = "yes" ]
}

# Parse a multi-select input against a max N. Supports:
#   "all" / "none" / empty / "1,3,2" / "1 3 2" (with dedup and bounds).
# On success: prints space-separated 1-based indices on stdout, returns 0.
# On "none"/empty: prints nothing, returns 0.
# On invalid input: prints error on stderr, returns 1.
parse_selection() {
    local input="$1" max="$2"
    input="${input//,/ }"
    input="$(echo "$input" | tr -s ' ' | sed 's/^ //;s/ $//')"

    if [ -z "$input" ] || [ "$input" = "none" ]; then
        return 0
    fi

    if [ "$input" = "all" ]; then
        local i
        local out=""
        for ((i = 1; i <= max; i++)); do
            out+="$i "
        done
        echo "${out% }"
        return 0
    fi

    local tok
    local -a seen=()
    local -a out=()
    for tok in $input; do
        if ! [[ "$tok" =~ ^[0-9]+$ ]]; then
            echo "       Invalid token: '$tok'" >&2
            return 1
        fi
        if [ "$tok" -lt 1 ] || [ "$tok" -gt "$max" ]; then
            echo "       Out of range: $tok (valid: 1-$max)" >&2
            return 1
        fi
        local dup=0
        local s
        for s in "${seen[@]:-}"; do
            [ "$s" = "$tok" ] && { dup=1; break; }
        done
        if [ "$dup" -eq 0 ]; then
            seen+=("$tok")
            out+=("$tok")
        fi
    done
    echo "${out[*]}"
}

# ─── Migration loop ──────────────────────────────────────────────────────────

declare -a REPORT=()
TOTAL_START=$(date +%s)

for svc in "${SERVICES[@]}"; do
    section "Service: $svc"
    target="${TARGET_PROJECT}_${svc}_data"

    # Detect existing sources
    declare -a sources=()
    for prefix in "${SOURCE_PREFIXES[@]}"; do
        candidate="${prefix}_${svc}_data"
        if volume_exists "$candidate"; then
            sources+=("$candidate")
        fi
    done

    if [ "${#sources[@]}" -eq 0 ]; then
        warn "No legacy source volume found for ${svc}"
        REPORT+=("$svc|-|$target|skipped (no source)")
        continue
    fi

    info "Candidate sources: ${sources[*]}"
    src=$(pick_source "$svc" "${sources[@]}")

    if [ -z "$src" ]; then
        warn "Skipped by user"
        REPORT+=("$svc|-|$target|skipped (user)")
        continue
    fi

    info "Source: $src    Target: $target"

    # Handle target state
    if volume_exists "$target" && ! volume_is_empty "$target"; then
        size=$(volume_size "$target")
        warn "Target ${target} already contains data (${size})"
        if ! prompt_yes_no "       Overwrite ${target}?"; then
            REPORT+=("$svc|$src|$target|skipped (target not empty)")
            continue
        fi
    fi

    # Create target if needed
    if ! volume_exists "$target"; then
        if [ "$DRY_RUN" -eq 1 ]; then
            info "[dry-run] docker volume create $target"
        else
            docker volume create "$target" >/dev/null
            ok "Created volume $target"
        fi
    fi

    # Copy
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[dry-run] docker run --rm -v $src:/from:ro -v $target:/to busybox sh -c 'cp -a /from/. /to/'"
        REPORT+=("$svc|$src|$target|dry-run")
        continue
    fi

    info "Copying data from $src to $target ..."
    # Wipe target first when overwriting to avoid stale files mixing in.
    docker run --rm -v "$target":/to busybox sh -c \
        'find /to -mindepth 1 -delete 2>/dev/null || true'

    started=$(date +%s)
    copy_with_progress "$src" "$target"
    elapsed=$(( $(date +%s) - started ))
    duration=$(human_duration "$elapsed")

    size=$(volume_size "$target")
    ok "Migrated ${svc}: ${src} → ${target} (${size}, ${duration})"
    REPORT+=("$svc|$src|$target|migrated (${size}, ${duration})")
done

# ─── Summary ─────────────────────────────────────────────────────────────────
section "Summary"

printf "%-15s %-28s %-32s %s\n" "SERVICE" "SOURCE" "TARGET" "STATUS"
printf "%-15s %-28s %-32s %s\n" "-------" "------" "------" "------"
for row in "${REPORT[@]}"; do
    IFS='|' read -r svc src tgt status <<<"$row"
    printf "%-15s %-28s %-32s %s\n" "$svc" "$src" "$tgt" "$status"
done

if [ -n "${TOTAL_START:-}" ]; then
    total_elapsed=$(( $(date +%s) - TOTAL_START ))
    echo
    info "Total time: $(human_duration "$total_elapsed")"
fi

# ─── Cleanup ─────────────────────────────────────────────────────────────────
section "Cleanup"

declare -a CLEAN_SRC=()
declare -a CLEAN_TGT=()
declare -a CLEAN_SIZE=()

for row in "${REPORT[@]}"; do
    IFS='|' read -r svc src tgt status <<<"$row"
    [[ "$status" == migrated* ]] || continue
    size="${status#migrated (}"
    size="${size%)}"
    CLEAN_SRC+=("$src")
    CLEAN_TGT+=("$tgt")
    CLEAN_SIZE+=("$size")
done

if [ "${#CLEAN_SRC[@]}" -eq 0 ]; then
    info "Nothing to clean up (no successful migrations in this run)."
elif [ "$DRY_RUN" -eq 1 ]; then
    info "Dry-run: skipping cleanup step."
else
    echo "The following legacy volumes were migrated successfully and can be removed:"
    echo
    for i in "${!CLEAN_SRC[@]}"; do
        idx=$((i + 1))
        printf "  %d) %-34s %-10s →  %s\n" \
            "$idx" "${CLEAN_SRC[$i]}" "${CLEAN_SIZE[$i]}" "${CLEAN_TGT[$i]}"
    done
    echo
    echo "Select volumes to delete:"
    echo "  - numbers separated by commas (e.g. \"1,3\")"
    echo "  - \"all\" to delete every volume listed"
    echo "  - \"none\" or empty to skip cleanup"

    selection=""
    while true; do
        read -r -p "> " input </dev/tty || input=""
        if selection=$(parse_selection "$input" "${#CLEAN_SRC[@]}"); then
            break
        fi
    done

    if [ -z "$selection" ]; then
        info "Cleanup skipped."
    else
        declare -a TO_DELETE=()
        for idx in $selection; do
            TO_DELETE+=("${CLEAN_SRC[$((idx - 1))]}")
        done

        echo
        echo -e "${RED}The following volumes will be PERMANENTLY DELETED:${NC}"
        for vol in "${TO_DELETE[@]}"; do
            echo "  - $vol"
        done
        echo

        if ! prompt_literal_yes "Type \"yes\" to confirm:"; then
            info "Confirmation not given; cleanup skipped."
        else
            deleted=0
            failed=0
            for vol in "${TO_DELETE[@]}"; do
                if docker volume rm "$vol" >/dev/null 2>&1; then
                    ok "Deleted $vol"
                    deleted=$((deleted + 1))
                else
                    fail "Could not delete $vol (still in use?)"
                    failed=$((failed + 1))
                fi
            done
            echo
            info "Cleanup: deleted=$deleted  failed=$failed  skipped=$(( ${#CLEAN_SRC[@]} - deleted - failed ))"
        fi
    fi
fi

echo
ok "Done."
