// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.16;

import "../interfaces/IBiswapPoolV3.sol";
import "../interfaces/IBiswapCallback.sol";
import "../interfaces/IBiswapFactoryV3.sol";

import "../libraries/Liquidity.sol";
import "../libraries/Point.sol";
import "../libraries/PointBitmap.sol";
import "../libraries/LogPowMath.sol";
import "../libraries/MulDivMath.sol";
import "../libraries/TwoPower.sol";
import "../libraries/LimitOrder.sol";
import "../libraries/SwapMathY2X.sol";
import "../libraries/SwapMathX2Y.sol";
import "../libraries/SwapMathY2XDesire.sol";
import "../libraries/SwapMathX2YDesire.sol";
import "../libraries/TokenTransfer.sol";
import "../libraries/UserEarn.sol";
import "../libraries/State.sol";
import "../libraries/Oracle.sol";
import "../libraries/OrderOrEndpoint.sol";
import "../libraries/MaxMinMath.sol";
import "../libraries/SwapCache.sol";


contract SwapY2XModule {

    using Liquidity for mapping(bytes32 =>Liquidity.Data);
    using Liquidity for Liquidity.Data;
    using Point for mapping(int24 =>Point.Data);
    using Point for Point.Data;
    using PointBitmap for mapping(int16 =>uint256);
    using LimitOrder for LimitOrder.Data;
    using UserEarn for UserEarn.Data;
    using UserEarn for mapping(bytes32 =>UserEarn.Data);
    using Oracle for Oracle.Observation[65535];
    using OrderOrEndpoint for mapping(int24 =>int24);

    int24 internal constant LEFT_MOST_PT = -800000;
    int24 internal constant RIGHT_MOST_PT = 800000;

    /// @notice left most point regularized by pointDelta
    int24 public leftMostPt;

    /// @notice right most point regularized by pointDelta
    int24 public rightMostPt;
    /// @notice maximum liquidSum for each point, see points() in IBiswapPoolV3 or library Point
    uint128 public maxLiquidPt;

    /// @notice address of BiswapFactoryV3
    address public factory;

    /// @notice address of tokenX
    address public tokenX;
    /// @notice address of tokenY
    address public tokenY;
    /// @notice initialize fee amount of this swap pool, 3000 means 0.3%
    uint16 public fee;


    /// @notice minimum number of distance between initialized or limitorder points
    int24 public pointDelta;

    /// @notice the fee growth as a 128-bit fixpoint fees of tokenX collected per 1 liquidity of the pool
    uint256 public feeScaleX_128;
    /// @notice the fee growth as a 128-bit fixpoint fees of tokenY collected per 1 liquidity of the pool
    uint256 public feeScaleY_128;

    /// @notice the farm point scale per 1 liquidity of the pool
    uint256 public fpScale_128;

    /// @notice last block number of farm point calculations
    uint256 public lastBlockNumber;

    /// @notice sqrt(1.0001), 96 bit fixpoint number
    uint160 public sqrtRate_96;

    /// @notice state of pool, see library State or IBiswapPoolV3#state for more information
    State public state;

    /// @notice the information about a liquidity by the liquidity's key
    mapping(bytes32 =>Liquidity.Data) public liquidity;

    /// @notice 256 packed point (orderOrEndpoint>0) boolean values. See PointBitmap for more information
    mapping(int16 =>uint256) public  pointBitmap;

    /// @notice returns information of a point in the pool, see Point library of IBiswapPoolV3#points for more information
    mapping(int24 =>Point.Data) public  points;
    /// @notice information about a point whether has limit order and whether as an liquidity's endpoint
    mapping(int24 =>int24) public orderOrEndpoint;
    /// @notice limitOrder info on a given point
    mapping(int24 =>LimitOrder.Data) public  limitOrderData;
    /// @notice information about a user's limit order (sell tokenY and earn tokenX)
    mapping(bytes32 => UserEarn.Data) public  userEarnX;
    /// @notice information about a user's limit order (sell tokenX and earn tokenY)
    mapping(bytes32 => UserEarn.Data) public  userEarnY;

    /// @notice observation data array
    Oracle.Observation[65535] public  observations;

    uint256 public  totalFeeXCharged;
    uint256 public  totalFeeYCharged;

    address private original;

    address private swapModuleX2Y;
    address private swapModuleY2X;
    address private liquidityModule;
    address private limitOrderModule;
    address private flashModule;

    /// @notice percent to charge from miner's fee
    uint24 public feeChargePercent;

    function balanceY() private view returns (uint256) {
        (bool success, bytes memory data) =
        tokenY.staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this)));
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

    /// Delegate call implementation for IBiswapPoolV3#swapY2X.
    function swapY2X(
        address recipient,
        uint128 amount,
        int24 highPt,
        bytes calldata data
    ) external returns (RetVal memory retVal) {
        require(amount > 0, "AP");

        highPt = MaxMinMath.min(highPt, rightMostPt);
        retVal.amountX = 0;
        retVal.amountY = 0;
        State memory st = state;
        SwapCache memory cache;
        cache.currFeeScaleX_128 = feeScaleX_128;
        cache.currFeeScaleY_128 = feeScaleY_128;
        cache.finished = false;
        cache._sqrtRate_96 = sqrtRate_96;
        cache.pointDelta = pointDelta;
        cache.currentOrderOrEndpt = orderOrEndpoint.getOrderOrEndptVal(st.currentPoint, cache.pointDelta);
        cache.startPoint = st.currentPoint;
        cache.currentDiscount = IBiswapFactoryV3(factory).feeDiscount(recipient, address(this));
        cache.startLiquidity = st.liquidity;
        uint256 calcBlocksWithRate = (block.number - lastBlockNumber) * IBiswapFactoryV3(factory).farmsRatio(address(this));
        cache.currFPScale_128 = fpScale_128 + (cache.startLiquidity == 0 ? 0 : MulDivMath.mulDivFloor(calcBlocksWithRate, TwoPower.Pow128, cache.startLiquidity));
        lastBlockNumber = block.number;
        while (st.currentPoint < highPt && !cache.finished) {
            uint16 _fee = getFeeWithDiscount(st.fee, cache.currentDiscount);
            if (cache.currentOrderOrEndpt & 2 > 0) {
                // amount <= uint128.max
                uint128 amountNoFee = uint128(uint256(amount) * (1e6 - _fee) / 1e6);
                if (amountNoFee > 0) {
                    // clear limit order first
                    LimitOrder.Data storage od = limitOrderData[st.currentPoint];
                    uint128 currX = od.sellingX;
                    (uint128 costY, uint128 acquireX) = SwapMathY2X.y2XAtPrice(
                        amountNoFee, st.sqrtPrice_96, currX
                    );
                    if (acquireX < currX || costY >= amountNoFee) {
                        cache.finished = true;
                    }
                    uint128 feeAmount;
                    if (costY >= amountNoFee) {
                        feeAmount = amount - costY;
                    } else {
                        // amount <= uint128.max
                        feeAmount = uint128(uint256(costY) * _fee / (1e6 - _fee));
                        uint256 mod = uint256(costY) * _fee % (1e6 - _fee);
                        if (mod > 0) {
                            feeAmount += 1;
                        }
                    }
                    totalFeeYCharged += feeAmount;
                    amount -= (costY + feeAmount);
                    retVal.amountY = retVal.amountY + costY + feeAmount;
                    retVal.amountX += acquireX;
                    currX -= acquireX;
                    od.sellingX = currX;
                    od.earnY += costY;
                    od.accEarnY += costY;
                    if (currX == 0) {
                        od.legacyEarnY += od.earnY;
                        od.earnY = 0;
                        od.legacyAccEarnY = od.accEarnY;
                        if (od.sellingY == 0) {
                            int24 newVal = cache.currentOrderOrEndpt & 1;
                            orderOrEndpoint.setOrderOrEndptVal(st.currentPoint, cache.pointDelta, newVal);
                            if (newVal == 0) {
                                pointBitmap.setZero(st.currentPoint, cache.pointDelta);
                            }
                        }
                    }
                } else {
                    cache.finished = true;
                }
            }

            if (cache.finished) {
                break;
            }

            int24 nextPoint = pointBitmap.nearestRightOneOrBoundary(st.currentPoint, cache.pointDelta);
            int24 nextVal = orderOrEndpoint.getOrderOrEndptVal(nextPoint, cache.pointDelta);
            if (nextPoint > highPt) {
                nextVal = 0;
                nextPoint = highPt;
            }

            // in [st.currentPoint, nextPoint)
            if (st.liquidity == 0) {
                // no liquidity in the range [st.currentPoint, nextPoint)
                st.currentPoint = nextPoint;
                st.sqrtPrice_96 = LogPowMath.getSqrtPrice(st.currentPoint);
                if (nextVal & 1 > 0) {
                    Point.Data storage endPt = points[nextPoint];
                    // pass next point from left to right
                    endPt.passEndpoint(cache.currFeeScaleX_128, cache.currFeeScaleY_128, cache.currFPScale_128);
                    // we should add delta liquid of nextPoint
                    int128 liquidDelta = endPt.liquidDelta;
                    st.liquidity = Liquidity.liquidityAddDelta(st.liquidity, liquidDelta);
                    st.liquidityX = st.liquidity;
                    st.feeTimesL = liquidDelta < 0 ? st.feeTimesL - endPt.feeTimesL : st.feeTimesL + endPt.feeTimesL;
                    st.fee = st.liquidity == 0 ? fee : uint16(st.feeTimesL / st.liquidity);
                    _fee = getFeeWithDiscount(st.fee, cache.currentDiscount);
                }
                cache.currentOrderOrEndpt = nextVal;
            } else {
                // amount <= uint128.max
                uint128 amountNoFee = uint128(uint256(amount) * (1e6 - _fee) / 1e6);
                if (amountNoFee > 0) {
                    SwapMathY2X.RangeRetState memory retState = SwapMathY2X.y2XRange(
                        st, nextPoint, cache._sqrtRate_96, amountNoFee
                    );

                    cache.finished = retState.finished;
                    uint128 feeAmount;
                    if (retState.costY >= amountNoFee) {
                        feeAmount = amount - retState.costY;
                    } else {
                        // retState.costY <= uint128.max
                        feeAmount = uint128(uint256(retState.costY) * _fee / (1e6 - _fee));
                        uint256 mod = uint256(retState.costY) * _fee % (1e6 - _fee);
                        if (mod > 0) {
                            feeAmount += 1;
                        }
                    }

                    retVal.amountX += retState.acquireX;
                    retVal.amountY = retVal.amountY + retState.costY + feeAmount;
                    amount -= (retState.costY + feeAmount);

                    uint256 chargedFeeAmount = uint256(feeAmount) * feeChargePercent / 100;
                    totalFeeYCharged += chargedFeeAmount;

                    cache.currFeeScaleY_128 = cache.currFeeScaleY_128 + MulDivMath.mulDivFloor(feeAmount - chargedFeeAmount, TwoPower.Pow128, st.liquidity);
                    retVal.accFee += uint128(feeAmount - chargedFeeAmount);
                    st.currentPoint = retState.finalPt;
                    st.sqrtPrice_96 = retState.sqrtFinalPrice_96;
                    st.liquidityX = retState.liquidityX;
                } else {
                    cache.finished = true;
                }

                if (st.currentPoint == nextPoint) {
                    if ((nextVal & 1) > 0) {
                        Point.Data storage endPt = points[nextPoint];
                        // pass next point from left to right
                        endPt.passEndpoint(cache.currFeeScaleX_128, cache.currFeeScaleY_128, cache.currFPScale_128);
                        st.liquidity = Liquidity.liquidityAddDelta(st.liquidity, endPt.liquidDelta);
                        st.feeTimesL = endPt.liquidDelta < 0 ? Point.abs(st.feeTimesL, endPt.feeTimesL) : st.feeTimesL + endPt.feeTimesL;
                        st.fee = st.liquidity == 0 ? fee : uint16(st.feeTimesL / st.liquidity);
                        _fee = getFeeWithDiscount(st.fee, cache.currentDiscount);
                    }
                    st.liquidityX = st.liquidity;
                }
                if (st.currentPoint == nextPoint) {
                    cache.currentOrderOrEndpt = nextVal;
                } else {
                    // not necessary, because finished must be true
                    cache.currentOrderOrEndpt = 0;
                }
            }
        }
        if (cache.startPoint != st.currentPoint) {
            (st.observationCurrentIndex, st.observationQueueLen) = observations.append(
                st.observationCurrentIndex,
                uint32(block.timestamp),
                cache.startPoint,
                st.observationQueueLen,
                st.observationNextQueueLen
            );
        }
        // write back fee scale, no fee of x
        feeScaleY_128 = cache.currFeeScaleY_128;
        fpScale_128 = cache.currFPScale_128;
        // write back state
        state = st;
        require(retVal.amountX > 0, "PR");
        // transfer x to trader
        TokenTransfer.transferToken(tokenX, recipient, retVal.amountX);
        // trader pay y
        require(retVal.amountY > 0, "PP");
        uint256 by = balanceY();
        IBiswapCallback(msg.sender).swapY2XCallback(retVal.amountX, retVal.amountY, data);
        require(balanceY() >= by + retVal.amountY, "YE");
    }

    /// Delegate call implementation for IBiswapPoolV3#swapY2XDesireX.
    function swapY2XDesireX(
        address recipient,
        uint128 desireX,
        int24 highPt,
        bytes calldata data
    ) external returns (RetVal memory retVal) {
        require (desireX > 0, "XP");

        highPt = MaxMinMath.min(highPt, rightMostPt);
        retVal.amountX = 0;
        retVal.amountY = 0;
        State memory st = state;
        SwapCache memory cache;
        cache.currFeeScaleX_128 = feeScaleX_128;
        cache.currFeeScaleY_128 = feeScaleY_128;
        cache.finished = false;
        cache._sqrtRate_96 = sqrtRate_96;
        cache.pointDelta = pointDelta;
        cache.currentOrderOrEndpt = orderOrEndpoint.getOrderOrEndptVal(st.currentPoint, cache.pointDelta);
        cache.startPoint = st.currentPoint;
        cache.currentDiscount = IBiswapFactoryV3(factory).feeDiscount(recipient, address(this));
        cache.startLiquidity = st.liquidity;
        uint256 calcBlocksWithRate = (block.number - lastBlockNumber) * IBiswapFactoryV3(factory).farmsRatio(address(this));
        cache.currFPScale_128 = fpScale_128 + (cache.startLiquidity == 0 ? 0 : MulDivMath.mulDivFloor(calcBlocksWithRate, TwoPower.Pow128, cache.startLiquidity));
        lastBlockNumber = block.number;
        while (st.currentPoint < highPt && !cache.finished) {
            uint16 _fee = getFeeWithDiscount(st.fee, cache.currentDiscount);
            if (cache.currentOrderOrEndpt & 2 > 0) {
                // clear limit order first
                LimitOrder.Data storage od = limitOrderData[st.currentPoint];
                uint128 currX = od.sellingX;
                (uint128 costY, uint128 acquireX) = SwapMathY2XDesire.y2XAtPrice(
                    desireX, st.sqrtPrice_96, currX
                );
                if (acquireX >= desireX) {
                    cache.finished = true;
                }
                uint256 feeAmount = MulDivMath.mulDivCeil(costY, _fee, 1e6 - _fee);
                totalFeeYCharged += feeAmount;
                desireX = (desireX <= acquireX) ? 0 : desireX - acquireX;
                retVal.amountY += (costY + feeAmount);
                retVal.amountX += acquireX;
                currX -= acquireX;
                od.sellingX = currX;
                od.earnY += costY;
                od.accEarnY += costY;
                if (currX == 0) {
                    od.legacyEarnY += od.earnY;
                    od.earnY = 0;
                    od.legacyAccEarnY = od.accEarnY;
                    if (od.sellingY == 0) {
                        int24 newVal = cache.currentOrderOrEndpt & 1;
                        orderOrEndpoint.setOrderOrEndptVal(st.currentPoint, cache.pointDelta, newVal);
                        if (newVal == 0) {
                            pointBitmap.setZero(st.currentPoint, cache.pointDelta);
                        }
                    }
                }
            }

            if (cache.finished) {
                break;
            }
            int24 nextPoint = pointBitmap.nearestRightOneOrBoundary(st.currentPoint, cache.pointDelta);
            int24 nextVal = orderOrEndpoint.getOrderOrEndptVal(nextPoint, cache.pointDelta);
            if (nextPoint > highPt) {
                nextVal = 0;
                nextPoint = highPt;
            }
            // in [st.currentPoint, nextPoint)
            if (st.liquidity == 0) {
                // no liquidity in the range [st.currentPoint, nextPoint)
                st.currentPoint = nextPoint;
                st.sqrtPrice_96 = LogPowMath.getSqrtPrice(st.currentPoint);
                if (nextVal & 1 > 0) {
                    Point.Data storage endPt = points[nextPoint];
                    // pass next point from left to right
                    endPt.passEndpoint(cache.currFeeScaleX_128, cache.currFeeScaleY_128,  cache.currFPScale_128);
                    // we should add delta liquid of nextPoint
                    int128 liquidDelta = endPt.liquidDelta;
                    st.liquidity = Liquidity.liquidityAddDelta(st.liquidity, liquidDelta);
                    st.liquidityX = st.liquidity;
                    st.feeTimesL = liquidDelta < 0 ? st.feeTimesL - endPt.feeTimesL : st.feeTimesL + endPt.feeTimesL;
                    st.fee = st.liquidity == 0 ? fee : uint16(st.feeTimesL / st.liquidity);
                    _fee = getFeeWithDiscount(st.fee, cache.currentDiscount);
                }
                cache.currentOrderOrEndpt = nextVal;
            } else {
                // desireX > 0
                if (desireX > 0) {
                    SwapMathY2XDesire.RangeRetState memory retState = SwapMathY2XDesire.y2XRange(
                        st, nextPoint, cache._sqrtRate_96, desireX
                    );
                    cache.finished = retState.finished;
                    uint256 feeAmount = MulDivMath.mulDivCeil(retState.costY, _fee, 1e6 - _fee);
                    uint256 chargedFeeAmount = feeAmount * feeChargePercent / 100;
                    totalFeeYCharged += chargedFeeAmount;

                    retVal.amountX += retState.acquireX;
                    retVal.amountY += (retState.costY + feeAmount);
                    desireX -= MaxMinMath.min(desireX, retState.acquireX);

                    cache.currFeeScaleY_128 = cache.currFeeScaleY_128 + MulDivMath.mulDivFloor(feeAmount - chargedFeeAmount, TwoPower.Pow128, st.liquidity);
                    retVal.accFee += uint128(feeAmount - chargedFeeAmount);
                    st.currentPoint = retState.finalPt;
                    st.sqrtPrice_96 = retState.sqrtFinalPrice_96;
                    st.liquidityX = retState.liquidityX;
                } else {
                    cache.finished = true;
                }

                if (st.currentPoint == nextPoint) {
                    if ((nextVal & 1) > 0) {
                        Point.Data storage endPt = points[nextPoint];
                        // pass next point from left to right
                        endPt.passEndpoint(cache.currFeeScaleX_128, cache.currFeeScaleY_128, cache.currFPScale_128);
                        st.liquidity = Liquidity.liquidityAddDelta(st.liquidity, endPt.liquidDelta);
                        st.feeTimesL = endPt.liquidDelta < 0 ? st.feeTimesL - endPt.feeTimesL : st.feeTimesL + endPt.feeTimesL;
                        st.fee = st.liquidity == 0 ? fee : uint16(st.feeTimesL / st.liquidity);
                        _fee = getFeeWithDiscount(st.fee, cache.currentDiscount);
                    }
                    st.liquidityX = st.liquidity;
                }
                if (st.currentPoint == nextPoint) {
                    cache.currentOrderOrEndpt = nextVal;
                } else {
                    // not necessary, because finished must be true
                    cache.currentOrderOrEndpt = 0;
                }
            }
        }
        if (cache.startPoint != st.currentPoint) {
            (st.observationCurrentIndex, st.observationQueueLen) = observations.append(
                st.observationCurrentIndex,
                uint32(block.timestamp),
                cache.startPoint,
                st.observationQueueLen,
                st.observationNextQueueLen
            );
        }
        // write back fee scale, no fee of x
        feeScaleY_128 = cache.currFeeScaleY_128;
        fpScale_128 = cache.currFPScale_128;
        // write back state
        state = st;
        // transfer x to trader
        require(retVal.amountX > 0, "PR");
        TokenTransfer.transferToken(tokenX, recipient, retVal.amountX);
        // trader pay y
        require(retVal.amountY > 0, "PP");
        uint256 by = balanceY();
        IBiswapCallback(msg.sender).swapY2XCallback(retVal.amountX, retVal.amountY, data);
        require(balanceY() >= by + retVal.amountY, "YE");
    }

    function getFeeWithDiscount(uint256 _fee, uint256 discount) private pure returns(uint16){
        return uint16(_fee - _fee * discount / 10000);
    }

}
