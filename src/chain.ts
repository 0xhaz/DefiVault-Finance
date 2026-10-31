/**
 * Network selection for the app. VITE_ARC_NETWORK=mainnet targets Arc mainnet (chain 5042);
 * anything else (default) targets Arc Testnet (chain 5042002).
 */
import { arc, arcTestnet } from 'viem/chains'

export const IS_MAINNET = import.meta.env.VITE_ARC_NETWORK === 'mainnet'
export const ARC_CHAIN = IS_MAINNET ? arc : arcTestnet
export const ARC_CHAIN_ID = ARC_CHAIN.id
export const ARC_NETWORK_NAME = IS_MAINNET ? 'Arc Mainnet' : 'Arc Testnet'
export const ARC_EXPLORER = ARC_CHAIN.blockExplorers.default.url

export function txUrl(hash: string): string {
  return `${ARC_EXPLORER}/tx/${hash}`
}

export function addressUrl(address: string): string {
  return `${ARC_EXPLORER}/address/${address}`
}
