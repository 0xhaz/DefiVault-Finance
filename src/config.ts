/**
 * wagmi configuration
 * Built with Arc Studio — https://studio.arc.io
 */

import { http, createConfig } from 'wagmi'
import { mainnet } from 'wagmi/chains'
import { arc, arcTestnet } from 'viem/chains'
import { ARC_CHAIN } from './chain'
import { injected } from 'wagmi/connectors'
import { registerChain } from './tracing'

// Pre-register chain RPC URLs so trace events show correct chain names immediately
registerChain(ARC_CHAIN.id, ARC_CHAIN.rpcUrls.default.http[0])

export const config = createConfig({
  chains: [ARC_CHAIN, mainnet], // mainnet needed for ENS resolution
  connectors: [injected()],
  transports: {
    // Both Arc ids are listed so the type covers either build; only ARC_CHAIN is in `chains`.
    [arc.id]: http(),
    [arcTestnet.id]: http(),
    [mainnet.id]: http(), // ENS resolution uses mainnet
  },
})
