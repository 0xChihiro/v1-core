///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

type Keycode is bytes5;

struct Permission {
    Keycode keycode;
    bytes4 selector;
}

interface IModule {
    function keycode() external pure returns (Keycode);
    function version() external pure returns (uint8 major, uint8 minor);
    function init() external;
}

interface IPolicy {
    function keycode() external pure returns (Keycode);
    function configureDependencies() external returns (Keycode[] memory);
    function requestPermissions() external view returns (Permission[] memory);
}

interface IController {
    enum Action {
        ActivateModule,
        ActivatePolicy,
        InstallModule,
        InstallPolicy,
        UpgradeModule,
        UpgradePolicy
    }
}
