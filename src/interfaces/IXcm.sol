// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Polkadot Hub XCM Precompile
// Source: polkadot-sdk/xcm/pallet-xcm/src/precompiles/IXcm.sol
address constant XCM_PRECOMPILE = address(0x00000000000000000000000000000000000a0000);

interface IXcm {
    struct Weight {
        uint64 refTime;
        uint64 proofSize;
    }

    /// @notice Execute an XCM message locally with the caller's origin
    /// @param message SCALE-encoded XCM message bytes
    /// @param weight Max weight to use for execution
    function execute(bytes calldata message, Weight calldata weight) external;

    /// @notice Send an XCM message to another parachain or consensus system
    /// @param destination SCALE-encoded destination MultiLocation
    /// @param message SCALE-encoded XCM message bytes
    function send(bytes calldata destination, bytes calldata message) external;

    /// @notice Estimate weight required to execute a given XCM message (view)
    /// @param message SCALE-encoded XCM message bytes
    /// @return weight Estimated Weight struct
    function weighMessage(bytes calldata message) external view returns (Weight memory weight);
}
