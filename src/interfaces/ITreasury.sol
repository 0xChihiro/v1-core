///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface ITreasury {
    enum Action {
        DeployFunds,
        RecallFunds,
        AddStrategy,
        RemoveStrategy
    }

    struct TreasuryCall {
        Action action;
        bytes data;
    }

    function execute(TreasuryCall memory) external returns (bool);

    function executeBatch(TreasuryCall[] memory) external returns (bool);
}
