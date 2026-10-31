#!/usr/bin/env bash
# LOCAL-ONLY end-to-end run of the REAL contracts/script/DeployMainnet.s.sol against throwaway anvil nodes.
# No real RPC URL, no private key (anvil's unlocked default accounts are used with --unlocked), no .env:
# forge runs from an empty cwd with a scrubbed environment.
# Prereq: `forge build` (stubs live in contracts/test-helpers/DeployMainnetStubs.sol).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RPC=http://127.0.0.1:8555      # chain id 5042 (Arc mainnet id, local node)
RPC_BAD=http://127.0.0.1:8556  # chain id 31337 (wrong-chain negative test)
SCRIPT="$ROOT/contracts/script/DeployMainnet.s.sol:DeployMainnet"
CWD=/tmp/dm_cwd; mkdir -p "$CWD"
OUT="$ROOT/contracts/out"
BCAST="$ROOT/broadcast/DeployMainnet.s.sol"
PASS=0; FAIL=0

A0=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 # deployer (anvil default #0, unlocked)
A1=0x70997970C51812dc3A010C7d01b50e0d17dc79C8 # charity wallet (EOA)
A2=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC # oracle operator (EOA)
A3=0x90F79bf6EB2c4f870365E785982E1f101E93b906 # EOA used for the EOA-governance negatives
A4=0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65
OWNER=0x5afe000000000000000000000000000000000001 # Safe-like (dummy code)
BOARD=0x5afe000000000000000000000000000000000002
USDC=0x3600000000000000000000000000000000000000
MSGR=0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d
XMIT=0x81D40F21F12A8F0E3252Bccb954D722d4c464B64
PAXG=0x00000000000000000000000000000000000a0001; PAXG_R=0x00000000000000000000000000000000000a0002
XAUT=0x00000000000000000000000000000000000a0003; XAUT_R=0x00000000000000000000000000000000000a0004
GORA=0x00000000000000000000000000000000000a0005
ZERO=0x0000000000000000000000000000000000000000

declare -A BASE=(
  [DEPLOYER_ADDRESS]=$A0 [OWNER_MULTISIG]=$OWNER [BOARD_MULTISIG]=$BOARD [CHARITY_WALLET]=$A1
  [ORACLE_OPERATOR]=$A2 [ADMIN_FEE_BPS]=100 [MUSHARAKAH_BPS]=2000 [HURDLE_BPS]=500
  [EXECUTOR_MAX_GAS_PRICE_GWEI]=20
)
declare -A EXTRA=()   # deployed addresses added as the run progresses (never GOLD_* variables)

ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }

code_of() { jq -r '.deployedBytecode.object' "$OUT/$1.sol/$2.json"; }
setcode() { cast rpc --rpc-url "$RPC" anvil_setCode "$1" "$2" >/dev/null; }
install_all() {
  setcode $USDC "$(code_of DeployMainnetStubs StubToken6)"
  setcode $MSGR "$(code_of DeployMainnetStubs StubCodeOnly)"
  setcode $XMIT "$(code_of DeployMainnetStubs StubTransmitter26)"
  setcode $OWNER 0x00; setcode $BOARD 0x00
  setcode $PAXG "$(code_of DeployMainnetStubs StubToken18)"; setcode $PAXG_R "$(code_of DeployMainnetStubs StubCodeOnly)"
  setcode $XAUT "$(code_of DeployMainnetStubs StubToken6)";  setcode $XAUT_R "$(code_of DeployMainnetStubs StubCodeOnly)"
  setcode $GORA "$(code_of DeployMainnetStubs StubOracle8)"
}

# fscript <rpc> <sender> <broadcast:0|1> <sig> [VAR=val | -VAR]...   (output in $LAST, status in $RC)
fscript() {
  local rpc=$1 sender=$2 bc=$3 sig=$4; shift 4
  declare -A E=(); local k
  for k in "${!BASE[@]}"; do E[$k]=${BASE[$k]}; done
  for k in "${!EXTRA[@]}"; do E[$k]=${EXTRA[$k]}; done
  local o
  for o in "$@"; do
    if [[ $o == -* ]]; then unset "E[${o#-}]"; else E[${o%%=*}]=${o#*=}; fi
  done
  local envs=(); for k in "${!E[@]}"; do envs+=("$k=${E[$k]}"); done
  local flags=(); [[ $bc == 1 ]] && flags+=(--broadcast)
  LAST=$(cd "$CWD" && env -i PATH="$PATH" HOME="$HOME" "${envs[@]}" \
    forge script "$SCRIPT" --root "$ROOT" --sig "$sig" --rpc-url "$rpc" --sender "$sender" --unlocked --no-storage-caching "${flags[@]}" 2>&1)
  RC=$?
}
expect_fail() { # label pattern rpc sender bc sig [overrides...]
  local label=$1 pat=$2; shift 2
  fscript "$@"
  if [[ $RC -ne 0 && $LAST == *"$pat"* ]]; then ok "NEG $label  (reverted: $pat)"
  else bad "NEG $label  (rc=$RC, wanted '$pat')"; echo "$LAST" | tail -8; fi
}
expect_ok() { # label rpc sender bc sig [overrides...]
  local label=$1; shift
  fscript "$@"
  if [[ $RC -eq 0 ]]; then ok "$label"; else bad "$label (rc=$RC)"; echo "$LAST" | tail -12; fi
}
grab() { echo "$LAST" | grep -E "^\s*$1" | grep -oE '0x[0-9a-fA-F]{40}' | head -1; }
call() { cast call --rpc-url "$RPC" "$@"; }
eq()   { # label got want
  if [[ "${2,,}" == "${3,,}" ]]; then ok "$1 = $3"; else bad "$1: got '$2' want '$3'"; fi
}
snap() { SNAP=$(cast rpc --rpc-url "$RPC" evm_snapshot | tr -d '"'); }
rev()  { eq "anvil evm_revert $1" "$(cast rpc --rpc-url "$RPC" evm_revert "$1")" true; }

# ---- ownership helpers -------------------------------------------------------------------------
OWNED=()
owned() { # contracts the deployer owns after deployCore/deployGold; gold adapters read from the vault's linked slots
  local sp al
  sp=$(call $V 'goldSpreadAdapter()(address)'); al=$(call $V 'goldAllocationAdapter()(address)')
  OWNED=($Z $T $V $C $E $G $X)
  [[ ${sp,,} != "$ZERO" ]] && OWNED+=("$sp")
  [[ ${al,,} != "$ZERO" ]] && OWNED+=("$al")
}
fund_owner() {
  cast rpc --rpc-url $RPC anvil_impersonateAccount $OWNER >/dev/null
  cast rpc --rpc-url $RPC anvil_setBalance $OWNER 0x56BC75E2D63100000 >/dev/null
}
accept() { # accept <addr>... as OWNER_MULTISIG (impersonated)
  fund_owner
  local a
  for a in "$@"; do cast send --rpc-url $RPC --from $OWNER --unlocked $a 'acceptOwnership()' >/dev/null 2>&1 || echo "    acceptOwnership failed on $a"; done
}
all_field() { # label field(owner|pendingOwner) want addr...   -> one PASS/FAIL for the whole list
  local label=$1 f=$2 want=$3; shift 3
  local a got badlist=""
  for a in "$@"; do got=$(call $a "$f()(address)"); [[ "${got,,}" == "${want,,}" ]] || badlist+=" $a($got)"; done
  if [[ -z $badlist ]]; then ok "$label ($# contracts)"; else bad "$label; mismatches:$badlist"; fi
}

# One full handoff procedure on the CURRENT chain state. extras=1 adds the gold-adapter ownership negatives.
cycle() { # label expectedContractCount extras
  local label=$1 expect=$2 extras=$3 a i
  owned
  eq "$label: Ownable2Step contracts to hand off" "${#OWNED[@]}" "$expect"
  all_field "$label: all owned by deployer pre-handoff" owner $A0 "${OWNED[@]}"
  expect_fail "$label: strict verify() before handoff"      "OWNER_MULTISIG has not accepted ownership" $RPC $A0 0 "verify()"
  expect_fail "$label: verifyPendingAcceptance() before handoff" "ownership not handed off"            $RPC $A0 0 "verifyPendingAcceptance()"

  if [[ $extras == 1 ]]; then   # deployer hands off everything EXCEPT the gold adapters (manual, not via the script)
    snap; local s=$SNAP
    fund_owner
    cast send --rpc-url $RPC --from $A0 --unlocked $R 'transferOwnership(address)' $OWNER >/dev/null
    for a in "${OWNED[@]:0:7}"; do
      cast send --rpc-url $RPC --from $A0 --unlocked $a 'transferOwnership(address)' $OWNER >/dev/null
    done
    accept "${OWNED[@]:0:7}"
    expect_fail "$label: strict verify() with gold adapters still deployer-owned" "OWNER_MULTISIG has not accepted ownership" $RPC $A0 0 "verify()"
    expect_fail "$label: verifyPendingAcceptance() with gold adapters not handed off" "ownership not handed off" $RPC $A0 0 "verifyPendingAcceptance()"
    rev "$s"
  fi

  expect_fail "$label: handoff wrong sender" "run with --sender" $RPC $A1 1 "handoff()"
  # handoff runs with NO GOLD_* variables at all: the adapters must still be handed off (read from the vault).
  expect_ok "$label: handoff() succeeds without any GOLD_* env" $RPC $A0 1 "handoff()" \
    -GOLD_PAXG -GOLD_PAXG_ROUTER -GOLD_PAXG_POOL_FEE -GOLD_XAUT -GOLD_XAUT_ROUTER -GOLD_XAUT_POOL_FEE -GOLD_ORACLE -GOLD_MAX_STALENESS_SECONDS
  eq "$label: handoff lists acceptOwnership targets" "$(echo "$LAST" | grep -c 'acceptOwnership on 0x')" "$expect"
  for a in "${OWNED[@]}"; do
    echo "$LAST" | grep -qi "acceptOwnership on $a" || bad "$label: handoff output does not list $a"
  done
  for i in 7 8; do
    [[ -n "${OWNED[$i]:-}" ]] && ok "$label: gold adapter ${OWNED[$i]} listed in handoff output" || true
  done
  all_field "$label: pendingOwner == OWNER_MULTISIG" pendingOwner $OWNER "${OWNED[@]}"
  all_field "$label: owner still deployer before acceptance" owner $A0 "${OWNED[@]}"
  eq "$label: registry owner == OWNER_MULTISIG (immediate)" "$(call $R 'owner()(address)')" $OWNER

  expect_ok   "$label: verifyPendingAcceptance() passes after handoff" $RPC $A0 0 "verifyPendingAcceptance()"
  expect_fail "$label: strict verify() fails before acceptance" "OWNER_MULTISIG has not accepted ownership" $RPC $A0 0 "verify()"

  snap; local s2=$SNAP     # partial acceptance: multisig accepted only the first 3 contracts
  accept "${OWNED[@]:0:3}"
  expect_fail "$label: strict verify() fails when multisig accepted only 3 of $expect" "OWNER_MULTISIG has not accepted ownership" $RPC $A0 0 "verify()"
  expect_ok   "$label: verifyPendingAcceptance() passes with partial acceptance" $RPC $A0 0 "verifyPendingAcceptance()"
  rev "$s2"

  accept "${OWNED[@]}"
  all_field "$label: owner == OWNER_MULTISIG after acceptOwnership" owner $OWNER "${OWNED[@]}"
  expect_ok "$label: strict verify() passes" $RPC $A0 0 "verify()"
  echo "$LAST" | grep -E "verify\(\) OK" | sed 's/^/    /'
  expect_ok "$label: verifyPendingAcceptance() also passes after acceptance" $RPC $A0 0 "verifyPendingAcceptance()"
  expect_fail "$label: verify() tampered EXECUTOR" "vault manager" $RPC $A0 0 "verify()" EXECUTOR=$A3
  expect_fail "$label: verify() tampered ESCROW"   "vault escrow"  $RPC $A0 0 "verify()" ESCROW=$A3

  if [[ $extras == 1 ]]; then   # a gold adapter owned by the deployer again -> verify must fail
    for i in 7 8; do
      a=${OWNED[$i]:-}; [[ -z $a ]] && continue
      snap; local s3=$SNAP
      fund_owner
      cast send --rpc-url $RPC --from $OWNER --unlocked $a 'transferOwnership(address)' $A0 >/dev/null
      cast send --rpc-url $RPC --from $A0 --unlocked $a 'acceptOwnership()' >/dev/null
      eq "$label: gold adapter $a owner is deployer again" "$(call $a 'owner()(address)')" $A0
      expect_fail "$label: strict verify() with adapter $a owned by deployer" "OWNER_MULTISIG has not accepted ownership" $RPC $A0 0 "verify()"
      expect_fail "$label: verifyPendingAcceptance() with adapter $a owned by deployer" "ownership not handed off" $RPC $A0 0 "verifyPendingAcceptance()"
      rev "$s3"
    done
  fi
}

cleanup() { kill "${PID1:-0}" "${PID2:-0}" 2>/dev/null; }
trap cleanup EXIT
anvil --chain-id 5042 --port 8555 --silent & PID1=$!
anvil --chain-id 31337 --port 8556 --silent & PID2=$!
for _ in $(seq 1 40); do cast chain-id --rpc-url $RPC >/dev/null 2>&1 && cast chain-id --rpc-url $RPC_BAD >/dev/null 2>&1 && break; sleep 0.25; done
eq "local chain id" "$(cast chain-id --rpc-url $RPC)" 5042
install_all
[[ -n "${KEEP_BROADCAST:-}" ]] || rm -rf "$BCAST"

echo "== NEGATIVE: check() =="
expect_fail "wrong chain id"            "not Arc mainnet"            $RPC_BAD $A0 0 "check()"
expect_fail "wrong sender"              "run with --sender"          $RPC $A1 0 "check()"
for v in DEPLOYER_ADDRESS OWNER_MULTISIG BOARD_MULTISIG CHARITY_WALLET ORACLE_OPERATOR ADMIN_FEE_BPS MUSHARAKAH_BPS HURDLE_BPS EXECUTOR_MAX_GAS_PRICE_GWEI; do
  expect_fail "missing env $v"          "$v"                         $RPC $A0 0 "check()" "-$v"
done
expect_fail "zero OWNER_MULTISIG"       "OWNER_MULTISIG is unset or zero"   $RPC $A0 0 "check()" OWNER_MULTISIG=$ZERO
expect_fail "zero BOARD_MULTISIG"       "BOARD_MULTISIG is unset or zero"   $RPC $A0 0 "check()" BOARD_MULTISIG=$ZERO
expect_fail "zero CHARITY_WALLET"       "CHARITY_WALLET is unset or zero"   $RPC $A0 0 "check()" CHARITY_WALLET=$ZERO
expect_fail "zero ORACLE_OPERATOR"      "ORACLE_OPERATOR is unset or zero"  $RPC $A0 0 "check()" ORACLE_OPERATOR=$ZERO
expect_fail "0xdead OWNER_MULTISIG"     "burn/placeholder"           $RPC $A0 0 "check()" OWNER_MULTISIG=0x000000000000000000000000000000000000dEaD
expect_fail "owner == deployer"         "governance must differ"     $RPC $A0 0 "check()" OWNER_MULTISIG=$A0
expect_fail "board == deployer"         "governance must differ"     $RPC $A0 0 "check()" BOARD_MULTISIG=$A0
expect_fail "charity == deployer"       "CHARITY_WALLET must not be the deployer" $RPC $A0 0 "check()" CHARITY_WALLET=$A0
expect_fail "EOA owner, no ALLOW_EOA"   "OWNER_MULTISIG must be a contract" $RPC $A0 0 "check()" OWNER_MULTISIG=$A3
expect_fail "EOA board, no ALLOW_EOA"   "BOARD_MULTISIG must be a contract" $RPC $A0 0 "check()" BOARD_MULTISIG=$A4
expect_ok   "POS EOA governance WITH ALLOW_EOA_GOVERNANCE=true" $RPC $A0 0 "check()" OWNER_MULTISIG=$A3 BOARD_MULTISIG=$A4 ALLOW_EOA_GOVERNANCE=true
expect_fail "ADMIN_FEE_BPS 201"         "ADMIN_FEE_BPS > 2%"         $RPC $A0 0 "check()" ADMIN_FEE_BPS=201
expect_fail "MUSHARAKAH_BPS 3001"       "MUSHARAKAH_BPS > 30%"       $RPC $A0 0 "check()" MUSHARAKAH_BPS=3001
expect_fail "HURDLE_BPS 2001"           "HURDLE_BPS > 20%"           $RPC $A0 0 "check()" HURDLE_BPS=2001
expect_fail "gas gwei 19"               "EXECUTOR_MAX_GAS_PRICE_GWEI" $RPC $A0 0 "check()" EXECUTOR_MAX_GAS_PRICE_GWEI=19
expect_fail "gas gwei 1001"             "EXECUTOR_MAX_GAS_PRICE_GWEI" $RPC $A0 0 "check()" EXECUTOR_MAX_GAS_PRICE_GWEI=1001
for pair in "USDC:$USDC:USDC has no code" "TokenMessengerV2:$MSGR:TokenMessengerV2 has no code" "MessageTransmitterV2:$XMIT:MessageTransmitterV2 has no code"; do
  IFS=: read -r n a pat <<<"$pair"; setcode "$a" 0x
  expect_fail "missing stub $n" "$pat" $RPC $A0 0 "check()"
  install_all
done
setcode $XMIT "$(code_of DeployMainnetStubs StubTransmitter7)"
expect_fail "transmitter domain 7"      "transmitter domain != 26"   $RPC $A0 0 "check()"
install_all

echo "== POSITIVE: check() =="
expect_ok "check() passes with valid env" $RPC $A0 0 "check()"

echo "== NEGATIVE: deployCore() must broadcast nothing when validation fails =="
N0=$(cast nonce --rpc-url $RPC $A0)
expect_fail "deployCore bad fee (pre-broadcast)" "ADMIN_FEE_BPS > 2%" $RPC $A0 1 "deployCore()" ADMIN_FEE_BPS=201
expect_fail "deployCore wrong sender"            "run with --sender"   $RPC $A1 1 "deployCore()"
eq "deployer nonce unchanged after failed deployCore" "$(cast nonce --rpc-url $RPC $A0)" "$N0"

echo "== deployCore() =="
expect_ok "deployCore() succeeds" $RPC $A0 1 "deployCore()"
echo "$LAST" | grep -E "REGISTRY|ZAKAT|TREASURY|VAULT|CHARITY|ESCROW|AGGREGATOR|EXECUTOR|runtime" | sed 's/^/    /'
for n in REGISTRY ZAKAT TREASURY VAULT CHARITY ESCROW AGGREGATOR EXECUTOR; do EXTRA[$n]=$(grab "$n\s+="); done
V=${EXTRA[VAULT]}; T=${EXTRA[TREASURY]}; C=${EXTRA[CHARITY]}; E=${EXTRA[ESCROW]}; X=${EXTRA[EXECUTOR]}; G=${EXTRA[AGGREGATOR]}; R=${EXTRA[REGISTRY]}; Z=${EXTRA[ZAKAT]}

echo "== deployCore() state assertions =="
SZ=$(( ($(cast code --rpc-url $RPC $V | wc -c) - 3) / 2 )); echo "    vault runtime bytes: $SZ"
[[ $SZ -le 24576 && $SZ -gt 0 ]] && ok "vault runtime size $SZ <= 24576" || bad "vault runtime size $SZ"
eq "treasury.feeSource == vault"      "$(call $T 'feeSource()(address)')" $V
eq "charity.escrow == escrow"         "$(call $C 'escrow()(address)')" $E
eq "vault.purificationEscrow == escrow" "$(call $V 'purificationEscrow()(address)')" $E
eq "vault.manager == executor"        "$(call $V 'manager()(address)')" $X
eq "vault.registry == registry"       "$(call $V 'registry()(address)')" $R
eq "vault.asset == USDC"              "$(call $V 'asset()(address)')" $USDC
eq "vault.tokenMessenger"             "$(call $V 'tokenMessenger()(address)')" $MSGR
eq "vault.messageTransmitter"         "$(call $V 'messageTransmitter()(address)')" $XMIT
eq "vault.localDomain (from transmitter stub)" "$(call $V 'localDomain()(uint32)')" 26
eq "vault permits USDC"               "$(call $V 'permittedAssets(address)(bool)' $USDC)" true
eq "executor.maxGasPrice = 20 gwei"   "$(call $X 'maxGasPrice()(uint256)' | awk '{print $1}')" 20000000000
eq "aggregator.oracle"                "$(call $G 'oracle()(address)')" $A2
eq "executor.shariahAggregator"       "$(call $X 'shariahAggregator()(address)')" $G
eq "registry TIMELOCK_PERIOD = 30d"   "$(call $R 'TIMELOCK_PERIOD()(uint256)' | awk '{print $1}')" 2592000
eq "registry isBoard(BOARD_MULTISIG)" "$(call $R 'isBoard(address)(bool)' $BOARD)" true
eq "registry owner == deployer (pre-handoff)" "$(call $R 'owner()(address)')" $A0
eq "treasury admin fee bps"           "$(call $T 'adminFeeBps()(uint256)' 2>/dev/null | awk '{print $1}')" 100
eq "vault.goldSpreadAdapter unset after core"     "$(call $V 'goldSpreadAdapter()(address)')" $ZERO
eq "vault.goldAllocationAdapter unset after core" "$(call $V 'goldAllocationAdapter()(address)')" $ZERO
for i in 0 1 2 3 4 5; do
  eq "aggregator.strategyEnabled($i) disabled" "$(call $G 'strategyEnabled(uint8)(bool)' $i)" false
  cfg=$(call $X 'shariahStrategyConfigs(uint8)(address,bytes32,bool,uint256,uint256)' $i | tr '\n' ' ')
  eq "executor.shariahStrategyConfigs($i) unset" "$(echo "$cfg" | awk '{print $1,$3,$4,$5}')" "$ZERO false 0 0"
done
for i in 0 1 2 3 4 5 6; do
  cfg=$(call $X 'strategyConfigs(uint8)(address,bytes32,bool,uint256,uint256)' $i 2>/dev/null | tr '\n' ' ')
  [[ -z "$cfg" ]] && continue
  eq "executor.strategyConfigs($i) unset" "$(echo "$cfg" | awk '{print $1,$3,$4,$5}')" "$ZERO false 0 0"
done
BC=$(find "$BCAST" -name 'deployCore*-latest.json' | head -1); echo "    broadcast file: ${BC#$ROOT/}"
NM=$(jq -r '[.transactions[].contractName] | map(select(. != null and (test("Mock|Stub")))) | length' "$BC")
TOT=$(jq -r '[.transactions[].contractName] | map(select(. != null)) | join(",")' "$BC")
eq "broadcast creates 0 Mock/Stub contracts" "$NM" 0
echo "    contracts created: $TOT"

echo "== SCENARIO A: core only (no gold) -> full handoff procedure =="
snap; CORE_SNAP=$SNAP
cycle "core-only" 7 0
rev "$CORE_SNAP"; snap; CORE_SNAP=$SNAP

echo "== deployGold() negatives =="
GOLDENV=(GOLD_ORACLE=$GORA GOLD_MAX_STALENESS_SECONDS=86400 GOLD_PAXG=$PAXG GOLD_PAXG_ROUTER=$PAXG_R GOLD_PAXG_POOL_FEE=3000 GOLD_XAUT=$XAUT GOLD_XAUT_ROUTER=$XAUT_R GOLD_XAUT_POOL_FEE=3000)
expect_fail "gold staleness 299"        "GOLD_MAX_STALENESS_SECONDS out of range" $RPC $A0 0 "deployGold()" "${GOLDENV[@]}" GOLD_MAX_STALENESS_SECONDS=299
expect_fail "gold neither token (zero)" "set GOLD_PAXG and/or GOLD_XAUT" $RPC $A0 0 "deployGold()" "${GOLDENV[@]}" GOLD_PAXG=$ZERO GOLD_XAUT=$ZERO
expect_fail "gold neither token (unset)" "set GOLD_PAXG and/or GOLD_XAUT" $RPC $A0 0 "deployGold()" "${GOLDENV[@]}" -GOLD_PAXG -GOLD_XAUT
expect_fail "gold oracle no code"       "GOLD_ORACLE has no code" $RPC $A0 0 "deployGold()" "${GOLDENV[@]}" GOLD_ORACLE=0x00000000000000000000000000000000000a00ff
expect_fail "gold PAXG no code"         "GOLD_PAXG has no code" $RPC $A0 0 "deployGold()" "${GOLDENV[@]}" GOLD_PAXG=0x00000000000000000000000000000000000a00ff
expect_fail "gold PAXG router no code"  "GOLD_PAXG_ROUTER has no code" $RPC $A0 0 "deployGold()" "${GOLDENV[@]}" GOLD_PAXG_ROUTER=0x00000000000000000000000000000000000a00ff
expect_fail "gold XAUT router no code"  "GOLD_XAUT_ROUTER has no code" $RPC $A0 0 "deployGold()" "${GOLDENV[@]}" GOLD_XAUT_ROUTER=0x00000000000000000000000000000000000a00ff
expect_fail "gold wrong sender"         "run with --sender" $RPC $A1 0 "deployGold()" "${GOLDENV[@]}"
eq "no adapter linked after failed deployGold runs" "$(call $V 'goldSpreadAdapter()(address)')$(call $V 'goldAllocationAdapter()(address)')" "$ZERO$ZERO"

echo "== SCENARIO B: deployGold with ONLY XAUT set -> exactly one adapter =="
expect_ok "deployGold() XAUT only (PAXG vars unset)" $RPC $A0 1 "deployGold()" "${GOLDENV[@]}" -GOLD_PAXG -GOLD_PAXG_ROUTER -GOLD_PAXG_POOL_FEE
echo "$LAST" | grep -E "Adapter" | sed 's/^/    /'
SP=$(grab "GoldExchangeAdapter"); AL=$(grab "GoldAllocationAdapter")
eq "returned spread adapter is zero"  "$SP" $ZERO
eq "vault.goldSpreadAdapter == 0"     "$(call $V 'goldSpreadAdapter()(address)')" $ZERO
eq "vault.goldAllocationAdapter"      "$(call $V 'goldAllocationAdapter()(address)')" $AL
eq "XAUT permitted on vault, PAXG not" "$(call $V 'permittedAssets(address)(bool)' $XAUT)/$(call $V 'permittedAssets(address)(bool)' $PAXG)" "true/false"
eq "executor.shariahStrategyConfigs(1) unset (no spread adapter)" \
   "$(call $X 'shariahStrategyConfigs(uint8)(address,bytes32,bool,uint256,uint256)' 1 | tr '\n' ' ' | awk '{print $1,$3}')" "$ZERO false"
eq "executor.shariahStrategyConfigs(5) = allocation adapter, DISABLED" \
   "$(call $X 'shariahStrategyConfigs(uint8)(address,bytes32,bool,uint256,uint256)' 5 | tr '\n' ' ' | awk '{print $1,$3}')" "$AL false"
BC=$(find "$BCAST" -name 'deployGold*-latest.json' | head -1)
eq "XAUT-only broadcast created contracts" "$(jq -r '[.transactions[].contractName] | map(select(. != null)) | join(",")' "$BC")" "GoldAllocationAdapter"
cycle "xaut-only" 8 0
rev "$CORE_SNAP"; snap; CORE_SNAP=$SNAP

echo "== SCENARIO C: deployGold with ONLY PAXG set (token zero, XAUT vars + staleness unset) -> one adapter =="
expect_ok "deployGold() PAXG only" $RPC $A0 1 "deployGold()" "${GOLDENV[@]}" GOLD_XAUT=$ZERO -GOLD_XAUT_ROUTER -GOLD_XAUT_POOL_FEE -GOLD_MAX_STALENESS_SECONDS
echo "$LAST" | grep -E "Adapter" | sed 's/^/    /'
SP=$(grab "GoldExchangeAdapter"); AL=$(grab "GoldAllocationAdapter")
eq "returned allocation adapter is zero" "$AL" $ZERO
eq "vault.goldSpreadAdapter"          "$(call $V 'goldSpreadAdapter()(address)')" $SP
eq "vault.goldAllocationAdapter == 0" "$(call $V 'goldAllocationAdapter()(address)')" $ZERO
eq "executor.shariahStrategyConfigs(1) = spread adapter, DISABLED" \
   "$(call $X 'shariahStrategyConfigs(uint8)(address,bytes32,bool,uint256,uint256)' 1 | tr '\n' ' ' | awk '{print $1,$3}')" "$SP false"
BC=$(find "$BCAST" -name 'deployGold*-latest.json' | head -1)
eq "PAXG-only broadcast created contracts" "$(jq -r '[.transactions[].contractName] | map(select(. != null)) | join(",")' "$BC")" "GoldExchangeAdapter"
cycle "paxg-only" 8 0
rev "$CORE_SNAP"; snap; CORE_SNAP=$SNAP

echo "== SCENARIO D: deployGold with PAXG and XAUT -> both adapters, then full procedure =="
expect_ok   "deployGold() PAXG + XAUT" $RPC $A0 1 "deployGold()" "${GOLDENV[@]}"
echo "$LAST" | grep -E "Adapter" | sed 's/^/    /'
SP=$(grab "GoldExchangeAdapter"); AL=$(grab "GoldAllocationAdapter")
eq "vault.goldSpreadAdapter"          "$(call $V 'goldSpreadAdapter()(address)')" $SP
eq "vault.goldAllocationAdapter"      "$(call $V 'goldAllocationAdapter()(address)')" $AL
eq "executor.shariahStrategyConfigs(1) = spread adapter, DISABLED" \
   "$(call $X 'shariahStrategyConfigs(uint8)(address,bytes32,bool,uint256,uint256)' 1 | tr '\n' ' ' | awk '{print $1,$3}')" "$SP false"
eq "executor.shariahStrategyConfigs(5) = allocation adapter, DISABLED" \
   "$(call $X 'shariahStrategyConfigs(uint8)(address,bytes32,bool,uint256,uint256)' 5 | tr '\n' ' ' | awk '{print $1,$3}')" "$AL false"
for i in 0 1 2 3 4 5; do eq "aggregator.strategyEnabled($i) still disabled after gold" "$(call $G 'strategyEnabled(uint8)(bool)' $i)" false; done
BC=$(find "$BCAST" -name 'deployGold*-latest.json' | head -1)
echo "    gold contracts created: $(jq -r '[.transactions[].contractName] | map(select(. != null)) | join(",")' "$BC")"
NM=$(jq -r '[.transactions[].contractName] | map(select(. != null and (test("Mock|Stub")))) | length' "$BC")
eq "gold broadcast creates 0 Mock/Stub contracts" "$NM" 0
cycle "gold-both" 9 1

echo
echo "SUMMARY: $PASS passed, $FAIL failed"
[[ -n "${KEEP_BROADCAST:-}" ]] || rm -rf "$BCAST"
[[ $FAIL -eq 0 ]]
