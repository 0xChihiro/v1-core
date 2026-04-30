///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

library CREATE3 {
    error CREATE3__EmptyCreationCode();
    error CREATE3__ProxyDeploymentFailed();
    error CREATE3__DeploymentFailed();

    bytes internal constant PROXY_BYTECODE = hex"67363d3d37363d34f03d5260086018f3";
    bytes32 internal constant PROXY_BYTECODE_HASH = keccak256(PROXY_BYTECODE);

    function deploy(bytes32 salt, bytes memory creationCode) internal returns (address deployed) {
        if (creationCode.length == 0) revert CREATE3__EmptyCreationCode();

        bytes memory proxyBytecode = PROXY_BYTECODE;
        address proxy;

        assembly ("memory-safe") {
            proxy := create2(0, add(proxyBytecode, 0x20), mload(proxyBytecode), salt)
        }

        if (proxy == address(0)) revert CREATE3__ProxyDeploymentFailed();

        deployed = getDeployed(salt);

        (bool success,) = proxy.call(creationCode);
        if (!success || deployed.code.length == 0) revert CREATE3__DeploymentFailed();
    }

    function getDeployed(bytes32 salt) internal view returns (address deployed) {
        address proxy = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, PROXY_BYTECODE_HASH))))
        );

        deployed = address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", proxy, hex"01")))));
    }
}
