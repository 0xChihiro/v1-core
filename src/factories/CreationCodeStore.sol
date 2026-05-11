///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

contract CreationCodeStore {
    constructor(bytes memory creationCode) {
        assembly ("memory-safe") {
            return(add(creationCode, 0x20), mload(creationCode))
        }
    }
}
