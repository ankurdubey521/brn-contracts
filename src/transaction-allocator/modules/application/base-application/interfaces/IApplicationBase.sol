// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

interface IApplicationBase {
    error ExternalCallsNotAllowed();
    error RelayerNotAssignedToTransaction();
    error RelayerAllocationResultLengthMismatch(uint256 expectedLength, uint256 actualLength);
    error AlreadyInitialized();
}
