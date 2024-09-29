# CLAuctionManagedHook

## Overview

CLAuctionManagedHook is a smart contract designed for the PancakeSwap V4 ecosystem, implementing a dynamic fee management system for Concentrated Liquidity (CL) pools. This hook introduces an auction mechanism where users can bid to become the fee manager for a specific pool for a limited time period.

## Key Features

- Auction-based fee management system
- Dynamic fee adjustment within predefined limits
- Incentivized pool management through fee sharing
- Integration with PancakeSwap V4 pool operations

## How It Works

1. **Auction Cycle**: 
   - The hook initiates an auction for each pool.
   - Users bid using a specified ERC20 token.
   - The highest bidder becomes the fee manager for a set period.

2. **Fee Management**:
   - The current fee manager can adjust the pool's swap fees within predefined limits.
   - A portion of the collected fees goes to the auction winner, incentivizing active management.

3. **Lifecycle Phases**:
   - LP Withdraw Window: Initial period where LPs can withdraw without new fee impact.
   - Auction Period: Users place bids to become the fee manager.
   - Management Period: The winning bidder can adjust fees.

4. **Integration with Pool Operations**:
   - The hook interacts with swap and liquidity operations, collecting additional fees as specified by the current manager.

## Prerequisite

1. Install foundry, see https://book.getfoundry.sh/getting-started/installation

## Running test

1. Install dependencies with `forge install`
2. Run test with `forge test`