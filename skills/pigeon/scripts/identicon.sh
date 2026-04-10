#!/usr/bin/env bash
# Generate a symmetric pixel art identicon from a hash
# Usage: bash identicon.sh <path_or_string> [--compact]
#
# 11x11 pixel grid (mirrored from 6 columns), rendered with Unicode
# half-block characters for double vertical resolution. Each project
# gets a unique colored portrait derived from sha256 of its canonical path.

set -e

INPUT="${1:-$PWD}"
COMPACT=false
[[ "${2:-}" == "--compact" || "${1:-}" == "--compact" ]] && COMPACT=true
[[ "${1:-}" == "--compact" ]] && INPUT="$PWD"

# Identity: git root commit hash > canonical path hash
# This must match mail-db.sh project_hash() logic
if [ -d "$INPUT" ]; then
    CANONICAL=$(cd "$INPUT" && pwd -P)
    ROOT_COMMIT=$(git -C "$INPUT" rev-list --max-parents=0 HEAD 2>/dev/null | head -1)
    if [ -n "$ROOT_COMMIT" ]; then
        # Use full root commit for visual entropy, short ID from first 6
        HASH=$(printf '%s' "$ROOT_COMMIT" | shasum -a 256 | cut -c1-40)
        SHORT="${ROOT_COMMIT:0:6}"
    else
        HASH=$(printf '%s' "$CANONICAL" | shasum -a 256 | cut -c1-40)
        SHORT="${HASH:0:6}"
    fi
else
    CANONICAL="$INPUT"
    HASH=$(printf '%s' "$CANONICAL" | shasum -a 256 | cut -c1-40)
    SHORT="${HASH:0:6}"
fi
NAME=$(basename "$CANONICAL")

# --- Color palette ---
# Two colors per identicon: foreground + accent, from different hash regions
FG_IDX=$(( $(printf '%d' "0x${HASH:6:2}") % 7 ))
BG_IDX=$(( $(printf '%d' "0x${HASH:8:2}") % 4 ))

# Foreground: vivid ANSI colors
FG_CODES=(31 32 33 34 35 36 91)
FG="\033[${FG_CODES[$FG_IDX]}m"

# Shade characters: full, dark, medium, light
CHARS=("█" "▓" "▒" "░")

RESET="\033[0m"
DIM="\033[2m"

# --- Build 11x12 pixel grid ---
# 6 columns generated, mirrored to 11 (c0 c1 c2 c3 c4 c5 c4 c3 c2 c1 c0)
# 12 rows, rendered as 6 lines using half-block characters
# Each cell has 2 bits (4 shade levels): 6 cols * 12 rows = 72 cells = 144 bits
# We have 160 bits from 40 hex chars

declare -a GRID  # GRID[row*6+col] = shade level (0-3)

bit_pos=0
for row in $(seq 0 11); do
    for col in $(seq 0 5); do
        hex_pos=$((bit_pos / 4))
        bit_offset=$((bit_pos % 4))
        hex_char="${HASH:$hex_pos:1}"
        nibble=$(printf '%d' "0x${hex_char}")

        # Extract 2 bits for shade level
        if [ $bit_offset -le 2 ]; then
            shade=$(( (nibble >> bit_offset) & 3 ))
        else
            # Straddle nibble boundary
            next_char="${HASH:$((hex_pos+1)):1}"
            next_nibble=$(printf '%d' "0x${next_char}")
            shade=$(( ((nibble >> bit_offset) | (next_nibble << (4 - bit_offset))) & 3 ))
        fi

        GRID[$((row * 6 + col))]=$shade
        bit_pos=$((bit_pos + 2))
    done
done

# --- Render with half-blocks ---
# Each output line combines two pixel rows using ▀▄█ and space
# Top pixel = upper half, Bottom pixel = lower half
#
# Both filled  = █ (full block)
# Top only     = ▀ (upper half)
# Bottom only  = ▄ (lower half)
# Neither      = " " (space)

get_mirrored_col() {
    local col=$1
    # Mirror pattern: 0 1 2 3 4 5 4 3 2 1 0
    if [ $col -le 5 ]; then
        echo $col
    else
        echo $((10 - col))
    fi
}

render_cell() {
    local top_shade=$1
    local bot_shade=$2

    # Threshold: shades 0-1 = filled, 2-3 = empty (gives ~50% fill)
    local top_on=$(( top_shade <= 1 ? 1 : 0 ))
    local bot_on=$(( bot_shade <= 1 ? 1 : 0 ))

    if [ $top_on -eq 1 ] && [ $bot_on -eq 1 ]; then
        # Both filled - use shade of top for character choice
        printf '%s' "${CHARS[$top_shade]}"
    elif [ $top_on -eq 1 ]; then
        printf '▀'
    elif [ $bot_on -eq 1 ]; then
        printf '▄'
    else
        printf ' '
    fi
}

# Width: 11 columns, each 1 char wide = 11 chars inside frame
BORDER_TOP="${DIM}┌───────────┐${RESET}"
BORDER_BOT="${DIM}└───────────┘${RESET}"

if [ "$COMPACT" = true ]; then
    # Compact: no frame, just the icon + hash
    for line in $(seq 0 5); do
        top_row=$((line * 2))
        bot_row=$((line * 2 + 1))
        printf '%b' "${FG}"
        for col in $(seq 0 10); do
            src_col=$(get_mirrored_col $col)
            top_shade=${GRID[$((top_row * 6 + src_col))]}
            bot_shade=${GRID[$((bot_row * 6 + src_col))]}
            render_cell $top_shade $bot_shade
        done
        printf '%b\n' "${RESET}"
    done
    echo -e "${FG}${SHORT}${RESET}"
else
    # Framed display
    echo -e "$BORDER_TOP"
    for line in $(seq 0 5); do
        top_row=$((line * 2))
        bot_row=$((line * 2 + 1))
        printf '%b' "${DIM}│${RESET}${FG}"
        for col in $(seq 0 10); do
            src_col=$(get_mirrored_col $col)
            top_shade=${GRID[$((top_row * 6 + src_col))]}
            bot_shade=${GRID[$((bot_row * 6 + src_col))]}
            render_cell $top_shade $bot_shade
        done
        printf '%b\n' "${RESET}${DIM}│${RESET}"
    done
    echo -e "$BORDER_BOT"
    echo -e " ${FG}${NAME}${RESET} ${DIM}${SHORT}${RESET}"
fi
