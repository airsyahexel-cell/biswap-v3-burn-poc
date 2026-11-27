// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import "../biswap/interfaces/IBiswapFactoryV3.sol";
import "../biswap/core/BiswapPoolV3.sol";

/// @dev Just enough of BiswapFactoryV3 for a local pool deployment.
///      The production factory is intentionally not used: this contract only
///      stores the constructor parameters and module addresses, then deploys
///      BiswapPoolV3 so that msg.sender inside the pool constructor is the
///      factory (the real factory deploys through DeployPool).
contract MockBiswapFactory is IBiswapFactoryV3 {
    address public tokenX;
    address public tokenY;
    uint16 public fee;
    int24 public currentPoint;
    int24 public pointDelta;
    uint24 public feeChargePercent;

    address public swapX2YModule;
    address public swapY2XModule;
    address public liquidityModule;
    address public limitOrderModule;
    address public flashModule;

    mapping(address => bool) public isPool;

    event PoolCreated(address indexed pool);

    function setPoolParams(
        address tokenX_,
        address tokenY_,
        uint16 fee_,
        int24 currentPoint_,
        int24 pointDelta_,
        uint24 feeChargePercent_
    ) external {
        tokenX = tokenX_;
        tokenY = tokenY_;
        fee = fee_;
        currentPoint = currentPoint_;
        pointDelta = pointDelta_;
        feeChargePercent = feeChargePercent_;
    }

    function setModules(
        address swapX2YModule_,
        address swapY2XModule_,
        address liquidityModule_,
        address limitOrderModule_,
        address flashModule_
    ) external {
        swapX2YModule = swapX2YModule_;
        swapY2XModule = swapY2XModule_;
        liquidityModule = liquidityModule_;
        limitOrderModule = limitOrderModule_;
        flashModule = flashModule_;
    }

    /// @notice Deploy a pool whose constructor reads this factory's params.
    function createPool() external returns (address poolAddress) {
        poolAddress = address(new BiswapPoolV3());
        isPool[poolAddress] = true;
        emit PoolCreated(poolAddress);
    }

    // ---------------------------------------------------------------------
    // IBiswapFactoryV3
    // ---------------------------------------------------------------------

    function addresses()
        external
        view
        override
        returns (
            address swapX2YModule_,
            address swapY2XModule_,
            address liquidityModule_,
            address limitOrderModule_,
            address flashModule_
        )
    {
        return (swapX2YModule, swapY2XModule, liquidityModule, limitOrderModule, flashModule);
    }

    function deployPoolParams()
        external
        view
        override
        returns (
            address tokenX_,
            address tokenY_,
            uint16 fee_,
            int24 currentPoint_,
            int24 pointDelta_,
            uint24 feeChargePercent_
        )
    {
        return (tokenX, tokenY, fee, currentPoint, pointDelta, feeChargePercent);
    }

    function farmsRatio(address) external pure override returns (uint256) {
        return 0;
    }

    function checkFeeInRange(uint16, uint16) external pure override returns (bool) {
        return true;
    }

    function getFeeRange(uint16 fee_) external pure override returns (uint16, uint16) {
        return (fee_, fee_);
    }

    function feeDiscount(address, address) external pure override returns (uint16) {
        return 0;
    }

    function chargeReceiver() external view override returns (address) {
        return address(this);
    }

    function defaultFeeChargePercent() external view override returns (uint24) {
        return feeChargePercent;
    }

    function fee2pointDelta(uint16) external view override returns (int24) {
        return pointDelta;
    }

    function fee2DeltaFee(uint16) external pure override returns (uint16) {
        return 0;
    }

    function pool(address, address, uint16) external pure override returns (address) {
        return address(0);
    }

    function farmsContract() external pure override returns (address) {
        return address(0);
    }

    function INIT_CODE_HASH() external pure override returns (bytes32) {
        return bytes32(0);
    }

    function setDiscount(DiscountStr[] calldata) external pure override {
        revert("MOCK");
    }

    function setFarmsRatio(address, uint256) external pure override {
        revert("MOCK");
    }

    function enableFeeAmount(uint16, uint24) external pure override {
        revert("MOCK");
    }

    function newPool(address, address, uint16, int24) external pure override returns (address) {
        revert("MOCK");
    }

    function modifyChargeReceiver(address) external pure override {
        revert("MOCK");
    }

    function modifyDefaultFeeChargePercent(uint24) external pure override {
        revert("MOCK");
    }

    function setFeeDelta(uint16, uint16) external pure override {
        revert("MOCK");
    }

    function setDiscountSetter(address) external pure override {
        revert("MOCK");
    }

    function setFarmsContract(address) external pure override {
        revert("MOCK");
    }
}
