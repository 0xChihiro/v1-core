///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface IVault {
    enum Bucket {
        Backing,
        Treasury,
        Team
    }

    struct TreasuryCall {
        address asset;
        address to;
        uint256 amount;
    }

    struct RedeemCall {
        address asset;
        uint256 amount;
    }

    struct TeamCall {
        address to;
        address asset;
        uint256 amount;
    }

    struct ReceiveCall {
        address from;
        address asset;
        uint256 amount;
        Bucket bucket;
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
    function transferTreasuryAsset(TreasuryCall calldata) external;
    function transferTreasuryAssets(TreasuryCall[] calldata) external;
    function transferRedeem(address, RedeemCall[] calldata) external;
    function transferTeamAsset(TeamCall calldata) external;
    function transferTeamAssets(TeamCall[] calldata) external;
    function credit(address, uint256, Bucket, Bucket) external;
    function credits(CreditCall[] calldata) external;
    function syncSurplus(address, Bucket) external;
    function receiveAsset(ReceiveCall calldata) external;
    function receiveAssets(ReceiveCall[] calldata) external;
    function backingBalances() external view returns (AssetBalance[] memory);
    function treasuryBalances() external view returns (AssetBalance[] memory);
    function teamBalances() external view returns (AssetBalance[] memory);
}
