#!/usr/bin/env bash
set -euo pipefail

#############################################
# CONFIGURATION (edit these defaults)
#############################################

# Cardano network (choose ONE)
NETWORK="--mainnet"
# NETWORK="--testnet-magic 1"

# Cardano node socket (used if env var not set)
DEFAULT_SOCKET_PATH="/opt/cardano/cnode/sockets/node.socket"

# Default asset (NIGHT)
DEFAULT_POLICY_ID="0691b2fecca1ac4f53cb6dfb00b7013e561d1f34403b957cbb5af1fa"
DEFAULT_ASSET_NAME_HEX="4e49474854"   # "NIGHT" in hex

#############################################
# END CONFIGURATION
#############################################

# Runtime defaults (can be overridden by CLI args below)
SOCKET_PATH="${CARDANO_NODE_SOCKET_PATH:-$DEFAULT_SOCKET_PATH}"
POLICY_ID="$DEFAULT_POLICY_ID"
ASSET_NAME_HEX="$DEFAULT_ASSET_NAME_HEX"

ADDR_FILE=""
SKEY_FILE=""
DEST_ADDR=""

DRY_RUN=0
MODE="move"  # move | check | required

die() { echo "ERROR: $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

usage() {
  cat <<'H'
move_night.sh - Move ADA + NIGHT from a night-miner address to a destination address.

Modes:
  --check       Show UTxOs + totals only (no build/sign/submit)
  --required    Show min-ADA, fee, required balance, and shortfall (no sign/submit)
  (default)     Build+sign+submit (use --dry-run to avoid submit)

Required for --check:
  --addr-file addr-X.addr

Required for --required:
  --addr-file addr-X.addr
  --dest-addr addr1...

Required for move (default):
  --addr-file addr-X.addr
  --skey-file addr-X.skey
  --dest-addr addr1...

Optional overrides:
  --policy-id <policy_hex>         (default from config)
  --asset-name-hex <asset_hex>     (default NIGHT)
  --socket <path_to_node.socket>   (default from config / env)
  --dry-run                        (build+sign but do not submit)

Examples:
  ./move_night.sh --addr-file addr-7.addr --check
  ./move_night.sh --addr-file addr-7.addr --dest-addr addr1... --required
  ./move_night.sh --addr-file addr-7.addr --skey-file addr-7.skey --dest-addr addr1... --dry-run
  ./move_night.sh --addr-file addr-7.addr --skey-file addr-7.skey --dest-addr addr1...
H
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --addr-file) ADDR_FILE="$2"; shift 2;;
    --skey-file) SKEY_FILE="$2"; shift 2;;
    --dest-addr) DEST_ADDR="$2"; shift 2;;
    --policy-id) POLICY_ID="$2"; shift 2;;
    --asset-name-hex) ASSET_NAME_HEX="$2"; shift 2;;
    --socket) SOCKET_PATH="$2"; shift 2;;
    --dry-run) DRY_RUN=1; shift 1;;
    --check) MODE="check"; shift 1;;
    --required) MODE="required"; shift 1;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1";;
  esac
done

need_cmd cardano-cli
need_cmd jq

[[ -f "$ADDR_FILE" ]] || die "addr file not found: $ADDR_FILE"
[[ -n "$POLICY_ID" ]] || die "POLICY_ID is empty (set DEFAULT_POLICY_ID or pass --policy-id)"
[[ -n "$ASSET_NAME_HEX" ]] || die "ASSET_NAME_HEX is empty (set DEFAULT_ASSET_NAME_HEX or pass --asset-name-hex)"
[[ -S "$SOCKET_PATH" ]] || die "socket path not found or not a socket: $SOCKET_PATH"

export CARDANO_NODE_SOCKET_PATH="$SOCKET_PATH"

SRC_ADDR="$(tr -d '\r\n' < "$ADDR_FILE")"
[[ "$SRC_ADDR" == addr1* ]] || die "Source address doesn't look right: $SRC_ADDR"

ASSET="${POLICY_ID}.${ASSET_NAME_HEX}"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

UTXO_JSON="$TMPDIR/utxo.json"
cardano-cli query utxo --address "$SRC_ADDR" $NETWORK --out-file "$UTXO_JSON"

UTXO_COUNT="$(jq 'length' "$UTXO_JSON")"
[[ "$UTXO_COUNT" -gt 0 ]] || die "No UTxOs found at source address."

echo "Source address : $SRC_ADDR"
echo "Dest address   : ${DEST_ADDR:-<not set>}"
echo "Asset          : $ASSET"
echo "Network        : $NETWORK"
echo "Socket         : $CARDANO_NODE_SOCKET_PATH"
echo "Mode           : $MODE"
echo "Dry-run        : $DRY_RUN"
echo

echo "UTxOs (text):"
cardano-cli query utxo --address "$SRC_ADDR" $NETWORK
echo

# Gather tx-ins and totals (lovelace + NIGHT)
TX_INS=()
TOTAL_LOVELACE=0
TOTAL_ASSET_QTY=0

while IFS= read -r key; do
  txhash="${key%#*}"
  txix="${key#*#}"
  TX_INS+=("--tx-in" "${txhash}#${txix}")

  lovelace="$(jq -r --arg k "$key" '.[$k].value.lovelace // 0' "$UTXO_JSON")"
  TOTAL_LOVELACE=$((TOTAL_LOVELACE + lovelace))

  qty="$(jq -r --arg k "$key" --arg pid "$POLICY_ID" --arg an "$ASSET_NAME_HEX" '
    (.[$k].value[$pid][$an] // 0)
  ' "$UTXO_JSON")"
  TOTAL_ASSET_QTY=$((TOTAL_ASSET_QTY + qty))
done < <(jq -r 'keys[]' "$UTXO_JSON")

echo "Found UTxOs     : $UTXO_COUNT"
echo "Total lovelace  : $TOTAL_LOVELACE"
echo "Total asset qty : $TOTAL_ASSET_QTY"
echo

if [[ "$MODE" == "check" ]]; then
  exit 0
fi

[[ -n "$DEST_ADDR" ]] || die "--dest-addr is required for --required or move"
[[ "$DEST_ADDR" == addr1* ]] || die "Destination address doesn't look right: $DEST_ADDR"

# Protocol parameters
PROTOCOL_JSON="$TMPDIR/protocol.json"
cardano-cli query protocol-parameters $NETWORK --out-file "$PROTOCOL_JSON"

# Min ADA required for an output holding this token qty
MIN_UTXO_OUT="$TMPDIR/minutxo.txt"
cardano-cli latest transaction calculate-min-required-utxo \
  --protocol-params-file "$PROTOCOL_JSON" \
  --tx-out "$DEST_ADDR+0 lovelace+${TOTAL_ASSET_QTY} ${ASSET}" \
  > "$MIN_UTXO_OUT"

MIN_UTXO="$(awk '{print $2}' "$MIN_UTXO_OUT")"
[[ "$MIN_UTXO" =~ ^[0-9]+$ ]] || die "Could not parse min-UTxO output: $(cat "$MIN_UTXO_OUT")"

# Draft tx for fee calc (fee 0)
DRAFT_TX="$TMPDIR/tx.raw"
cardano-cli latest transaction build-raw \
  "${TX_INS[@]}" \
  --tx-out "$DEST_ADDR+${MIN_UTXO} lovelace+${TOTAL_ASSET_QTY} ${ASSET}" \
  --fee 0 \
  --out-file "$DRAFT_TX"

INPUT_COUNT=$(( ${#TX_INS[@]} / 2 ))

FEE_OUT="$TMPDIR/fee.txt"
cardano-cli latest transaction calculate-min-fee \
  --tx-body-file "$DRAFT_TX" \
  --tx-in-count "$INPUT_COUNT" \
  --tx-out-count 1 \
  --witness-count 1 \
  $NETWORK \
  --protocol-params-file "$PROTOCOL_JSON" \
  > "$FEE_OUT"

FEE="$(awk '{print $1}' "$FEE_OUT")"
[[ "$FEE" =~ ^[0-9]+$ ]] || die "Could not parse fee output: $(cat "$FEE_OUT")"

REQUIRED_ADA=$((MIN_UTXO + FEE))
SHORTFALL=0
if (( TOTAL_LOVELACE < REQUIRED_ADA )); then
  SHORTFALL=$((REQUIRED_ADA - TOTAL_LOVELACE))
fi

echo "Min ADA for token output : $MIN_UTXO lovelace"
echo "Calculated fee           : $FEE lovelace"
echo "Minimum required balance : $REQUIRED_ADA lovelace"
if (( SHORTFALL > 0 )); then
  echo "Shortfall                : $SHORTFALL lovelace"
fi
echo

if [[ "$MODE" == "required" ]]; then
  exit 0
fi

# Move mode requires skey and token presence
[[ -f "$SKEY_FILE" ]] || die "--skey-file is required for move"
[[ "$TOTAL_ASSET_QTY" -gt 0 ]] || die "No $ASSET found at source address UTxOs. Nothing to move."
(( SHORTFALL == 0 )) || die "Insufficient ADA. Fund source address with at least $SHORTFALL lovelace, then rerun."

SEND_ADA=$((TOTAL_LOVELACE - FEE))

FINAL_TX="$TMPDIR/tx.final"
cardano-cli latest transaction build-raw \
  "${TX_INS[@]}" \
  --tx-out "$DEST_ADDR+${SEND_ADA} lovelace+${TOTAL_ASSET_QTY} ${ASSET}" \
  --fee "$FEE" \
  --out-file "$FINAL_TX"

SIGNED_TX="$TMPDIR/tx.signed"
cardano-cli latest transaction sign \
  --tx-body-file "$FINAL_TX" \
  --signing-key-file "$SKEY_FILE" \
  $NETWORK \
  --out-file "$SIGNED_TX"

echo "Signed tx created: $SIGNED_TX"
echo

if (( DRY_RUN == 1 )); then
  echo "DRY RUN: Not submitting."
  exit 0
fi

echo "Submitting..."
cardano-cli latest transaction submit --tx-file "$SIGNED_TX" $NETWORK
echo "Submitted."