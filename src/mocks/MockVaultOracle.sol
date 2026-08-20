// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IVaultOracle } from "../interfaces/IVaultOracle.sol";

contract MockVaultOracle is IVaultOracle {
    struct Observation {
        uint256 value;
        uint256 updatedAt;
    }

    mapping(address => Observation) public prices;
    mapping(bytes32 => Observation) public volatilities;

    function setPrice(address asset, uint256 value, uint256 updatedAt) external {
        prices[asset] = Observation(value, updatedAt);
    }

    function setRelativeVolatility(address asset0, address asset1, uint256 value, uint256 updatedAt)
        external
    {
        volatilities[_key(asset0, asset1)] = Observation(value, updatedAt);
    }

    function priceX18(address asset) external view returns (uint256, uint256) {
        Observation memory observation = prices[asset];
        return (observation.value, observation.updatedAt);
    }

    function relativeVolatilityBps(address asset0, address asset1)
        external
        view
        returns (uint256, uint256)
    {
        Observation memory observation = volatilities[_key(asset0, asset1)];
        return (observation.value, observation.updatedAt);
    }

    function _key(address asset0, address asset1) internal pure returns (bytes32) {
        return asset0 < asset1
            ? keccak256(abi.encode(asset0, asset1))
            : keccak256(abi.encode(asset1, asset0));
    }
}
