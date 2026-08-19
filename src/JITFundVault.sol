// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

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
    error ZeroAddress();

    event Bootstrapped(address indexed provider, uint256 shares);
    event CoordinatorSet(address indexed coordinator);
    event DepositBasket(address indexed caller, address indexed receiver, uint256 shares);
    event WithdrawBasket(address indexed caller, address indexed receiver, uint256 shares);
    event OperationStarted(
        address indexed currency0, address indexed currency1, uint256 amount0, uint256 amount1
    );
    event OperationEnded(address indexed currency0, address indexed currency1);

    address[3] public assets;
    mapping(address asset => bool) public supported;
    address public coordinator;
    bool public activeOperation;

    constructor(address[3] memory assets_, address initialOwner)
        ERC20("JIT Multi-Token Fund", "JITF")
        Ownable(initialOwner)
    {
        for (uint256 i; i < 3; ++i) {
            address asset = assets_[i];
            if (asset == address(0)) revert ZeroAddress();
            if (supported[asset]) revert BadAsset();
            supported[asset] = true;
            assets[i] = asset;
        }
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
}

