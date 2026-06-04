///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IKernel} from "./IKernel.sol";

interface IVault {
    enum TransferType {
        Receive,
        Send
    }

    enum Bucket {
        Borrow,
        Redeem,
        Treasury,
        Team,
        Collateral,
        None
    }

    struct TransferCall {
        TransferType callType;
        Bucket toBucket;
        Bucket fromBucket;
        address asset;
        address user;
        uint256 amount;
    }

    struct CreditCall {
        Bucket from;
        Bucket to;
        address asset;
        uint256 amount;
    }

    struct AssetBalance {
        address asset;
        uint256 amount;
    }

    function CONTROLLER() external view returns (address);
    function KERNEL() external view returns (IKernel);

    function handleAccounting(TransferCall[] memory calls) external;
    function credit(address asset, uint256 amount, Bucket from, Bucket to) external;
    function credits(CreditCall[] calldata calls) external;
    function syncSurplus(address asset, Bucket bucket) external;
    function validateBalances(address[] calldata assets_) external view;

    function assets() external view returns (address[] memory);
    function bucketBalance(Bucket bucket, address asset) external view returns (uint256);
    function bucketBalances(Bucket bucket) external view returns (AssetBalance[] memory);
    function bucketBalances(Bucket bucket, address[] calldata assets_) external view returns (AssetBalance[] memory);
    function backingBalances() external view returns (AssetBalance[] memory);
    function treasuryBalances() external view returns (AssetBalance[] memory);
    function treasuryBalances(address[] calldata assets_) external view returns (AssetBalance[] memory);
    function teamBalances() external view returns (AssetBalance[] memory);
}
