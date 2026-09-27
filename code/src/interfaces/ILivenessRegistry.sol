// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Declared at file level so that the vault and the registry share one nominal type.
struct Groth16Proof {
    uint256[2] a;
    uint256[2][2] b;
    uint256[2] c;
}

/// @notice The part of LivenessRegistry a vault depends on.
interface ILivenessRegistry {
    function enroll(Groth16Proof calldata p, uint256 newRoot, uint256 binding) external returns (uint256 slot);

    /// @return binding The principal's enrolled binding, or 0 if they never enrolled.
    /// @return since   Start of the most recent epoch, within `lookback`, that recorded them
    ///                 present, or 0 if none did.
    function presenceOf(address principal, uint256 lookback) external view returns (uint256 binding, uint64 since);

    function slotOf(address principal) external view returns (bool enrolled, uint256 slot);

    /// @notice Largest `lookback` that `presenceOf` accepts.
    function MAX_LOOKBACK() external view returns (uint256);

    /// @notice Shortest epoch the registry accepts; a vault sizes its timers against it.
    function MIN_EPOCH_LENGTH() external view returns (uint64);
}
