///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ITreasury} from "./interfaces/ITreasury.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";

contract Treasury is ITreasury {
    address public immutable CONTROLLER;
    uint256 public immutable MAX_STRATEGIES;

    mapping(address => bool) private _strategies;

    event Treasury__StrategyAdded(address indexed strategy);
    event Treasury__StrategyRemoved(address indexed strategy);

    error Treasury__ControllerAddressZero();
    error Treasury__MaxStrategiesZero();
    error Treasury__FundsDeployment();
    error Treasury__FundsRecall();
    error Treasury__StrategyActive();
    error Treasury__InvalidStrategy();
    error Treasury__StrategyFundsDeployed();
    error Treasury__StrategyNotActive();

    constructor(address controller, uint256 maxStrategies) {
        if (controller == address(0)) revert Treasury__ControllerAddressZero();
        if (maxStrategies == 0) revert Treasury__MaxStrategiesZero();
        CONTROLLER = controller;
        MAX_STRATEGIES = maxStrategies;
    }

    function execute(ITreasury.TreasuryCall calldata call) external returns (bool) {
        _execute(call);
        return true;
    }

    function executeBatch(ITreasury.TreasuryCall[] calldata calls) external returns (bool) {
        for (uint256 i = 0; i < calls.length; i++) {
            _execute(calls[i]);
        }
        return true;
    }

    function _execute(ITreasury.TreasuryCall calldata call) internal {
        ITreasury.Action action = call.action;
        if (ITreasury.Action.DeployFunds == action) {
            _deployFunds(call.data);
        } else if (ITreasury.Action.RecallFunds == action) {
            _recallFunds(call.data);
        } else if (ITreasury.Action.AddStrategy == action) {
            _addStrategy(call.data);
        } else if (ITreasury.Action.RemoveStrategy == action) {
            _removeStrategy(call.data);
        }
    }

    function _deployFunds(bytes calldata data) internal {
        (address strategy, bytes memory call) = abi.decode(data, (address, bytes));
        if (!_strategies[strategy]) revert Treasury__StrategyNotActive();
        bool success = IStrategy(strategy).execute(call);
        if (!success) revert Treasury__FundsDeployment();
    }

    function _recallFunds(bytes calldata data) internal {
        (address strategy, bytes memory call) = abi.decode(data, (address, bytes));
        if (!_strategies[strategy]) revert Treasury__StrategyNotActive();
        bool success = IStrategy(strategy).execute(call);
        if (!success) revert Treasury__FundsRecall();
    }

    function _addStrategy(bytes calldata data) internal {
        address strategy = abi.decode(data, (address));
        if (strategy == address(0)) revert Treasury__InvalidStrategy();
        if (_strategies[strategy]) revert Treasury__StrategyActive();
        _strategies[strategy] = true;
        emit Treasury__StrategyAdded(strategy);
    }

    function _removeStrategy(bytes calldata data) internal {
        address strategy = abi.decode(data, (address));
        if (!_strategies[strategy]) revert Treasury__StrategyNotActive();
        if (IStrategy(strategy).activeFunds() > 0) revert Treasury__StrategyFundsDeployed();
        _strategies[strategy] = false;
        emit Treasury__StrategyRemoved(strategy);
    }
}
