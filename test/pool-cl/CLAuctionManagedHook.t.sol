// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Test} from "forge-std/Test.sol";
import {Constants} from "pancake-v4-core/test/pool-cl/helpers/Constants.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {CLPoolParametersHelper} from "pancake-v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {CLAuctionManagedHook} from "../../src/pool-cl/CLAuctionManagedHook.sol";
import {CLTestUtils} from "./utils/CLTestUtils.sol";
import {PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {ICLRouterBase} from "pancake-v4-periphery/src/pool-cl/interfaces/ICLRouterBase.sol";

contract CLAuctionManagedHookTest is Test, CLTestUtils {
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;

    CLAuctionManagedHook hook;
    Currency currency0;
    Currency currency1;
    PoolKey key;
    MockERC20 bidToken;

    function setUp() public {
        (currency0, currency1) = deployContractsWithTokens();
        bidToken = new MockERC20("Bid Token", "BID", 18);
        hook = new CLAuctionManagedHook(poolManager, address(bidToken));

        // create the pool key
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: hook,
            poolManager: poolManager,
            fee: uint24(3000), // 0.3% fee
            parameters: bytes32(uint256(hook.getHooksRegistrationBitmap())).setTickSpacing(10)
        });

        // initialize pool at 1:1 price point (assume stablecoin pair)
        poolManager.initialize(key, Constants.SQRT_RATIO_1_1, new bytes(0));
    }

    function testStartAuction() public {
        hook.startAuction(key.toId());

        (,,,uint256 managerEndTime,uint256 lpWithdrawTime,,,) = hook.auctionInfo(key.toId());

        assertEq(lpWithdrawTime, block.timestamp + hook.LP_WITHDRAW_WINDOW());
        assertEq(managerEndTime, block.timestamp + hook.LP_WITHDRAW_WINDOW() + hook.AUCTION_TTL() + hook.MANAGER_TTL());
    }

    function testBid() public {
        address user1 = address(0x1);
        
        // Start the auction
        hook.startAuction(key.toId());

        // Warp to auction start time
        vm.warp(block.timestamp + hook.LP_WITHDRAW_WINDOW());

        // Prepare user1 to bid
        bidToken.mint(user1, 1000);
        vm.startPrank(user1);
        bidToken.approve(address(hook), 1000);

        // Place a bid
        hook.bid(key.toId(), 100);

        (address currentManager, uint256 highestBid,,,,,,) = hook.auctionInfo(key.toId());

        assertEq(currentManager, user1);
        assertEq(highestBid, 100);

        vm.stopPrank();
    }

    function testSetCurrentFees() public {
        address user1 = address(0x1);

        // Start the auction and place a bid
        hook.startAuction(key.toId());
        vm.warp(block.timestamp + hook.LP_WITHDRAW_WINDOW());
        bidToken.mint(user1, 1000);
        vm.startPrank(user1);
        bidToken.approve(address(hook), 1000);
        hook.bid(key.toId(), 100);

        // Set new fees
        hook.setCurrentFees(key.toId(), 1000);

        (,,,,,,,uint24 currentFee) = hook.auctionInfo(key.toId());
        assertEq(currentFee, 1000);

        vm.stopPrank();
    }

}