// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "pancake-v4-core/src/types/BeforeSwapDelta.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLBaseHook} from "./CLBaseHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";

import {LPFeeLibrary} from "pancake-v4-core/src/libraries/LPFeeLibrary.sol";

contract CLAuctionManagedHook is CLBaseHook, Ownable {
    using PoolIdLibrary for PoolKey;

    IERC20 public bidToken;

    address public auctionFeeReceiver;

    uint256 public constant MANAGER_TTL = 20 hours;
    uint256 public constant LP_WITHDRAW_WINDOW = 3 hours;
    uint256 public constant AUCTION_TTL = 1 hours;

    struct AuctionInfo {
        address currentManager;
        uint256 highestBid;
        uint256 auctionEndTime;
        uint256 managerEndTime;
        uint256 lpWithdrawTime;
        uint256 feesToken0;
        uint256 feesToken1;
        uint24 currentFee;
    }

    struct PoolTokensInfo {
        address token0;
        address token1;
    }

    mapping(PoolId => AuctionInfo) public auctionInfo;
    mapping(PoolId => PoolTokensInfo) public poolTokensInfo;
    
    constructor(ICLPoolManager _poolManager, address _bidToken) CLBaseHook(_poolManager) Ownable(msg.sender) {
        bidToken = IERC20(_bidToken);
    }

    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return _hooksRegistrationBitmapFrom(
            Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: true,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnsDelta: false,
                afterSwapReturnsDelta: false,
                afterAddLiquidityReturnsDelta: false,
                afterRemoveLiquidityReturnsDelta: false
            })
        );
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24, bytes calldata) external override returns (bytes4) {
        poolTokensInfo[key.toId()] = PoolTokensInfo({
            token0: Currency.unwrap(key.currency0),
            token1: Currency.unwrap(key.currency1)
        });

        return this.afterInitialize.selector;
    }

    function startAuction(PoolId poolId) external {
        AuctionInfo storage auction = auctionInfo[poolId];

        if(auction.managerEndTime > block.timestamp) {
            revert("Manager already set");
        }

        auction.lpWithdrawTime = block.timestamp + LP_WITHDRAW_WINDOW;
        auction.auctionEndTime = auction.lpWithdrawTime + AUCTION_TTL;
        auction.managerEndTime = auction.auctionEndTime + MANAGER_TTL;

        auction.currentFee = 500;

        IERC20(poolTokensInfo[poolId].token0).transfer(auction.currentManager, auction.feesToken0);
        IERC20(poolTokensInfo[poolId].token1).transfer(auction.currentManager, auction.feesToken1);

        auction.feesToken0 = 0;
        auction.feesToken1 = 0;

        auction.currentManager = address(0);
    }

    function bid(PoolId poolId, uint256 amount) external {
        AuctionInfo storage auction = auctionInfo[poolId];

        if(auction.auctionEndTime < block.timestamp) {
            revert("Auction already started");
        }

        if(auction.currentManager != address(0)) {
            revert("Auction not started");
        }

        if(amount <= auction.highestBid) {
            revert("Bid must be higher than highest bid");
        }
        
        bidToken.transferFrom(msg.sender, address(this), amount);
        if(auction.highestBid > 0) {
            bidToken.transfer(auction.currentManager, auction.highestBid);
        }

        auction.highestBid = amount;
        auction.currentManager = msg.sender;
    }

    function setCurrentFees(PoolId poolId, uint24 fee) external {
        AuctionInfo storage auction = auctionInfo[poolId];

        if(auction.currentManager != msg.sender) {
            revert("Only manager can set fees");
        }

        if(auction.managerEndTime < block.timestamp) {
            revert("Not in manager mode");
        }

        auction.currentFee = fee;
    }

    function collectAuctionFees() external onlyOwner {
        bidToken.transfer(auctionFeeReceiver, bidToken.balanceOf(address(this)));
    }


    function beforeSwap(address, PoolKey calldata key, ICLPoolManager.SwapParams calldata swapParams, bytes calldata)
        external
        override
        poolManagerOnly
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        AuctionInfo storage auction = auctionInfo[key.toId()];

        if(auction.currentManager == address(0) || auction.managerEndTime < block.timestamp) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, auction.currentFee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
        }

        uint256 fee;
        if(swapParams.zeroForOne && swapParams.amountSpecified > 0) {
            fee = (uint256(swapParams.amountSpecified) * auction.currentFee) / 1_000_000;
            auction.feesToken1 += (fee);
            IERC20(poolTokensInfo[key.toId()].token1).transferFrom(tx.origin, address(this), fee);
        } else if(swapParams.zeroForOne && swapParams.amountSpecified < 0) {
            fee = (uint256(-swapParams.amountSpecified) * auction.currentFee) / 1_000_000;
            auction.feesToken0 += (fee);
            IERC20(poolTokensInfo[key.toId()].token0).transferFrom(tx.origin, address(this), fee);
        } else if (!swapParams.zeroForOne && swapParams.amountSpecified > 0) {
            fee = (uint256(swapParams.amountSpecified) * auction.currentFee) / 1_000_000;
            auction.feesToken0 += (fee);
            IERC20(poolTokensInfo[key.toId()].token0).transferFrom(tx.origin, address(this), fee);
        } else if (!swapParams.zeroForOne && swapParams.amountSpecified < 0) {
            fee = (uint256(-swapParams.amountSpecified) * auction.currentFee) / 1_000_000;
            auction.feesToken1 += (fee);
            IERC20(poolTokensInfo[key.toId()].token1).transferFrom(tx.origin, address(this), fee);
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function beforeRemoveLiquidity(address, PoolKey calldata key, ICLPoolManager.ModifyLiquidityParams calldata, bytes calldata) external override poolManagerOnly returns (bytes4) {
        AuctionInfo memory auction = auctionInfo[key.toId()];

        if(auction.lpWithdrawTime < block.timestamp) {
            revert("LP withdraw time over");
        }
        
        return this.beforeRemoveLiquidity.selector;
    }


}
