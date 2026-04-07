///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface ITreasury {
    enum Action {
        DeployFunds,
        RecallFunds,
        AddStrategy,
        RemoveStrategy
    }

    function execute(Action action, bytes memory data) external returns (bool);

    function executeBatch(Action[] memory actions, bytes[] memory data) external returns (bool);
}
