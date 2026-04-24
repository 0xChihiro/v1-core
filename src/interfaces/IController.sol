///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface IController {
    function isPermissioned(address) external view returns (bool);
    function vaultAccess(address) external view returns (bool);
}
