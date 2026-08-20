// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IVaultOracle } from "./interfaces/IVaultOracle.sol";

/// @notice Pro-rata three-token fund backing atomic JIT liquidity operations.
/// @dev Prototype only. Fee-on-transfer, rebasing and callback tokens are unsupported.
contract JITFundVault is ERC20, Ownable {
    using SafeERC20 for IERC20;

    error ActiveOperation();
    error AlreadyBootstrapped();
    error BadAsset();
    error BadArrayLength();
    error CoordinatorOnly();
    error InsufficientDeposit();
    error NotActive();
    error NotBootstrapped();
    error OracleInvalid();
    error OracleStale();
    error UnsupportedDecimals();
    error ZeroAddress();

    event Bootstrapped(address indexed provider, uint256 shares);
    event CoordinatorSet(address indexed coordinator);
    event DepositBasket(address indexed caller, address indexed receiver, uint256 shares);
    event DepositSingle(
        address indexed caller,
        address indexed receiver,
        address indexed asset,
        uint256 amount,
        uint256 shares,
        uint256 feeAmount
    );
    event DepositFeeSet(uint16 feeBps);
    event OracleSettingsSet(address indexed oracle, uint32 maxOracleAge);
    event TargetWeightsSet(uint16 weight0, uint16 weight1, uint16 weight2);
    event WithdrawBasket(address indexed caller, address indexed receiver, uint256 shares);
    event OperationStarted(
        address indexed currency0, address indexed currency1, uint256 amount0, uint256 amount1
    );
    event OperationEnded(address indexed currency0, address indexed currency1);

    address[3] public assets;
    uint16[3] public targetWeightsBps;
    mapping(address asset => bool) public supported;
    mapping(address asset => uint8) public assetIndex;
    address public coordinator;
    bool public activeOperation;
    IVaultOracle public oracle;
    uint32 public maxOracleAge;
    uint16 public depositFeeBps;

    constructor(
        address[3] memory assets_,
        uint16[3] memory targetWeightsBps_,
        IVaultOracle oracle_,
        uint32 maxOracleAge_,
        address initialOwner
    ) ERC20("JIT Multi-Token Fund", "JITF") Ownable(initialOwner) {
        for (uint256 i; i < 3; ++i) {
            address asset = assets_[i];
            if (asset == address(0)) revert ZeroAddress();
            if (supported[asset]) revert BadAsset();
            if (IERC20Metadata(asset).decimals() != 18) revert UnsupportedDecimals();
            supported[asset] = true;
            assets[i] = asset;
            assetIndex[asset] = uint8(i);
        }
        _setTargetWeights(targetWeightsBps_);
        _setOracleSettings(oracle_, maxOracleAge_);
    }

    modifier unlocked() {
        if (activeOperation) revert ActiveOperation();
        _;
    }

    function setCoordinator(address coordinator_) external onlyOwner unlocked {
        if (coordinator_ == address(0)) revert ZeroAddress();
        coordinator = coordinator_;
        emit CoordinatorSet(coordinator_);
    }

    function setOracleSettings(IVaultOracle oracle_, uint32 maxOracleAge_)
        external
        onlyOwner
        unlocked
    {
        _setOracleSettings(oracle_, maxOracleAge_);
    }

    function setDepositFee(uint16 feeBps) external onlyOwner unlocked {
        if (feeBps > 1_000) revert InsufficientDeposit();
        depositFeeBps = feeBps;
        emit DepositFeeSet(feeBps);
    }

    function setTargetWeights(uint16[3] calldata weights) external onlyOwner unlocked {
        _setTargetWeights(weights);
    }

    /// @notice One-time proportional basket initialization.
    function bootstrap(uint256[3] calldata amounts, uint256 initialShares, address receiver)
        external
        onlyOwner
        unlocked
    {
        if (totalSupply() != 0) revert AlreadyBootstrapped();
        if (initialShares == 0 || receiver == address(0)) revert InsufficientDeposit();
        for (uint256 i; i < 3; ++i) {
            if (amounts[i] == 0) revert InsufficientDeposit();
            IERC20(assets[i]).safeTransferFrom(msg.sender, address(this), amounts[i]);
        }
        _mint(receiver, initialShares);
        emit Bootstrapped(receiver, initialShares);
    }

    /// @notice Deposit up to `maxAmounts`, accepting only the current vault ratio.
    /// @return shares Number of fungible fund shares minted.
    /// @return accepted Exact basket amounts transferred from the caller.
    function depositBasket(uint256[3] calldata maxAmounts, uint256 minShares, address receiver)
        external
        unlocked
        returns (uint256 shares, uint256[3] memory accepted)
    {
        uint256 supply = totalSupply();
        if (supply == 0) revert NotBootstrapped();
        shares = type(uint256).max;
        for (uint256 i; i < 3; ++i) {
            uint256 balance = IERC20(assets[i]).balanceOf(address(this));
            if (balance == 0) revert InsufficientDeposit();
            shares = Math.min(shares, Math.mulDiv(maxAmounts[i], supply, balance));
        }
        if (shares < minShares || shares == 0) revert InsufficientDeposit();

        for (uint256 i; i < 3; ++i) {
            uint256 balance = IERC20(assets[i]).balanceOf(address(this));
            accepted[i] = Math.mulDiv(shares, balance, supply, Math.Rounding.Ceil);
            if (accepted[i] > maxAmounts[i]) revert InsufficientDeposit();
            IERC20(assets[i]).safeTransferFrom(msg.sender, address(this), accepted[i]);
        }
        _mint(receiver, shares);
        emit DepositBasket(msg.sender, receiver, shares);
    }

    /// @notice Deposit one supported 18-decimal token at oracle NAV.
    function depositSingle(address asset, uint256 amount, uint256 minShares, address receiver)
        external
        unlocked
        returns (uint256 shares)
    {
        if (!supported[asset] || amount == 0 || receiver == address(0)) {
            revert InsufficientDeposit();
        }
        uint256 supply = totalSupply();
        if (supply == 0) revert NotBootstrapped();
        uint256 navBefore = navX18();
        (uint256 price,) = _freshPrice(asset);
        uint256 grossValue = Math.mulDiv(amount, price, 1e18);
        uint256 feeAmount = Math.mulDiv(grossValue, depositFeeBps, 10_000);
        uint256 netValue = grossValue - feeAmount;
        shares = Math.mulDiv(netValue, supply, navBefore);
        if (shares < minShares || shares == 0) revert InsufficientDeposit();
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        _mint(receiver, shares);
        emit DepositSingle(msg.sender, receiver, asset, amount, shares, feeAmount);
    }

    function navX18() public view returns (uint256 nav) {
        for (uint256 i; i < 3; ++i) {
            (uint256 price,) = _freshPrice(assets[i]);
            nav += Math.mulDiv(IERC20(assets[i]).balanceOf(address(this)), price, 1e18);
        }
    }

    /// @notice Signed relative representation of token0 versus token1 in basis points.
    function relativeImbalanceBps(address token0, address token1) external view returns (int256) {
        if (!supported[token0] || !supported[token1] || token0 == token1) revert BadAsset();
        (uint256 price0,) = _freshPrice(token0);
        (uint256 price1,) = _freshPrice(token1);
        uint256 value0 = Math.mulDiv(IERC20(token0).balanceOf(address(this)), price0, 1e18);
        uint256 value1 = Math.mulDiv(IERC20(token1).balanceOf(address(this)), price1, 1e18);
        uint256 normalized0 = Math.mulDiv(value0, 10_000, targetWeightsBps[assetIndex[token0]]);
        uint256 normalized1 = Math.mulDiv(value1, 10_000, targetWeightsBps[assetIndex[token1]]);
        uint256 denominator = Math.max(normalized0, normalized1);
        if (denominator == 0) return 0;
        if (normalized0 >= normalized1) {
            return int256(Math.mulDiv(normalized0 - normalized1, 10_000, denominator));
        }
        return -int256(Math.mulDiv(normalized1 - normalized0, 10_000, denominator));
    }

    function relativeVolatilityBps(address token0, address token1)
        external
        view
        returns (uint256 volatilityBps)
    {
        uint256 updatedAt;
        (volatilityBps, updatedAt) = oracle.relativeVolatilityBps(token0, token1);
        _validateObservation(volatilityBps, updatedAt);
    }

    /// @notice Burn shares and receive the current basket pro rata, without swaps.
    function withdrawBasket(uint256 shares, uint256[3] calldata minAmounts, address receiver)
        external
        unlocked
        returns (uint256[3] memory amounts)
    {
        uint256 supply = totalSupply();
        if (shares == 0 || shares >= supply) revert InsufficientDeposit();
        _burn(msg.sender, shares);
        for (uint256 i; i < 3; ++i) {
            IERC20 token = IERC20(assets[i]);
            amounts[i] = Math.mulDiv(token.balanceOf(address(this)), shares, supply);
            if (amounts[i] < minAmounts[i]) revert InsufficientDeposit();
            token.safeTransfer(receiver, amounts[i]);
        }
        emit WithdrawBasket(msg.sender, receiver, shares);
    }

    /// @notice Lend the complete requested pair inventory to the coordinator for one transaction.
    function beginOperation(address currency0, address currency1)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        if (msg.sender != coordinator) revert CoordinatorOnly();
        if (activeOperation) revert ActiveOperation();
        if (!supported[currency0] || !supported[currency1] || currency0 == currency1) {
            revert BadAsset();
        }
        activeOperation = true;
        amount0 = IERC20(currency0).balanceOf(address(this));
        amount1 = IERC20(currency1).balanceOf(address(this));
        IERC20(currency0).safeTransfer(msg.sender, amount0);
        IERC20(currency1).safeTransfer(msg.sender, amount1);
        emit OperationStarted(currency0, currency1, amount0, amount1);
    }

    /// @notice Finish after the coordinator has returned the complete residual pair inventory.
    function endOperation(address currency0, address currency1) external {
        if (msg.sender != coordinator) revert CoordinatorOnly();
        if (!activeOperation) revert NotActive();
        activeOperation = false;
        emit OperationEnded(currency0, currency1);
    }

    function _freshPrice(address asset) internal view returns (uint256 price, uint256 updatedAt) {
        (price, updatedAt) = oracle.priceX18(asset);
        _validateObservation(price, updatedAt);
    }

    function _validateObservation(uint256 value, uint256 updatedAt) internal view {
        if (value == 0 || updatedAt > block.timestamp) revert OracleInvalid();
        if (block.timestamp - updatedAt > maxOracleAge) revert OracleStale();
    }

    function _setOracleSettings(IVaultOracle oracle_, uint32 maxOracleAge_) internal {
        if (address(oracle_) == address(0) || maxOracleAge_ == 0) revert OracleInvalid();
        oracle = oracle_;
        maxOracleAge = maxOracleAge_;
        emit OracleSettingsSet(address(oracle_), maxOracleAge_);
    }

    function _setTargetWeights(uint16[3] memory weights) internal {
        if (uint256(weights[0]) + weights[1] + weights[2] != 10_000) revert BadArrayLength();
        if (weights[0] == 0 || weights[1] == 0 || weights[2] == 0) revert BadArrayLength();
        targetWeightsBps = weights;
        emit TargetWeightsSet(weights[0], weights[1], weights[2]);
    }
}
