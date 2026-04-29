///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

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

    function handleAccounting(TransferCall[] memory) external;
    function credit(address, uint256, Bucket, Bucket) external;
    function credits(CreditCall[] calldata) external;
    function syncSurplus(address, Bucket) external;
    function backingBalances() external view returns (AssetBalance[] memory);
    function treasuryBalances() external view returns (AssetBalance[] memory);
    function teamBalances() external view returns (AssetBalance[] memory);
}
