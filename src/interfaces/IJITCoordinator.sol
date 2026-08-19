// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PoolId } from "v4-core/src/types/PoolId.sol";

interface IJITCoordinator {
    function isActive(PoolId poolId) external view returns (bool);
}

