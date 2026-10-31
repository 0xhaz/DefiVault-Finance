#!/usr/bin/env bash
# LP-4: seed the two testnet pools created by DeployUniswapV3Testnet.s.sol. Arc Testnet only.
#
# Uses `cast send` (not a Foundry broadcast) because Arc's USDC predeploy fails ERC-20 calls inside forge scripts
# (docs/rehearsal.md, issue 1). Liquidity is minted to the signer. After seeding, wait 30 minutes before deploying
# HalalLPAdapter: its 1800 s TWAP needs that much pool history (the initialize observation counts).
#
# Required env:
#   RPC_URL                 Arc Testnet RPC (https://rpc.testnet.arc.io)
#   DEPLOYER_PK             signer key (testnet only; never a mainnet key)
#   NPM, ROUTER, MVOL       addresses printed by DeployUniswapV3Testnet.s.sol
# Optional env (6-decimal base units; testnet USDC comes from the faucet, so defaults are small):
#   SEED_STABLE_USDC=10000000  SEED_STABLE_EURC=9000000   USDC/EURC 0.05%, ticks -1600..-600 around the price
#   SEED_VOL_USDC=10000000     SEED_VOL_MVOL=10000000     MVOL/USDC 0.3%, full range
#
# Keep later adapter deploys small relative to these pools (for example 0.1 to 1 USDC): the adapter swaps about half
# of each deploy and enforces its TWAP-based minimum output.
set -euo pipefail

: "${RPC_URL:?set RPC_URL}" "${DEPLOYER_PK:?set DEPLOYER_PK}" "${NPM:?set NPM}" "${ROUTER:?set ROUTER}" "${MVOL:?set MVOL}"
USDC=0x3600000000000000000000000000000000000000
EURC=0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a
SEED_STABLE_USDC=${SEED_STABLE_USDC:-10000000}
SEED_STABLE_EURC=${SEED_STABLE_EURC:-9000000}
SEED_VOL_USDC=${SEED_VOL_USDC:-10000000}
SEED_VOL_MVOL=${SEED_VOL_MVOL:-10000000}

chain=$(cast chain-id --rpc-url "$RPC_URL")
if [ "$chain" != "5042002" ] && [ "${ALLOW_LOCAL:-0}" != "1" ]; then
  echo "refusing: chain $chain is not Arc Testnet (5042002)" >&2; exit 1
fi
ME=$(cast wallet address --private-key "$DEPLOYER_PK")
send() { cast send --rpc-url "$RPC_URL" --private-key "$DEPLOYER_PK" "$@" >/dev/null; echo "ok: ${2}"; }
DEADLINE=$(( $(date +%s) + 3600 ))
MINT_SIG="mint((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,address,uint256))"

echo "signer $ME on chain $chain"
send "$MVOL" "mint(address,uint256)" "$ME" "$SEED_VOL_MVOL"
send "$USDC" "approve(address,uint256)" "$NPM" $(( SEED_STABLE_USDC + SEED_VOL_USDC ))
send "$EURC" "approve(address,uint256)" "$NPM" "$SEED_STABLE_EURC"
send "$MVOL" "approve(address,uint256)" "$NPM" "$SEED_VOL_MVOL"

# USDC/EURC 0.05%: USDC is token0. Concentrated around the price, like the mainnet pool.
send "$NPM" "$MINT_SIG" "($USDC,$EURC,500,-1600,-600,$SEED_STABLE_USDC,$SEED_STABLE_EURC,0,0,$ME,$DEADLINE)"
# MVOL/USDC 0.3%: MVOL sorts below USDC, so USDC is token1. Full range, 1:1.
send "$NPM" "$MINT_SIG" "($MVOL,$USDC,3000,-887220,887220,$SEED_VOL_MVOL,$SEED_VOL_USDC,0,0,$ME,$DEADLINE)"

echo "seeded. Positions held by $ME. Wait 30 minutes before the first HalalLPAdapter deploy."
