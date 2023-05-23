// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "src/transaction-allocator/common/TAStructs.sol";
import "src/transaction-allocator/common/TAHelpers.sol";
import "src/transaction-allocator/common/TATypes.sol";

import "./interfaces/ITATransactionAllocation.sol";
import "./TATransactionAllocationStorage.sol";
import "../application/base-application/interfaces/IApplicationBase.sol";
import "../relayer-management/TARelayerManagementStorage.sol";

contract TATransactionAllocation is ITATransactionAllocation, TAHelpers, TATransactionAllocationStorage {
    using FixedPointTypeHelper for FixedPointType;
    using Uint256WrapperHelper for uint256;
    using VersionManager for VersionManager.VersionManagerState;

    ///////////////////////////////// Transaction Execution ///////////////////////////////
    function _executeTransaction(
        bytes calldata _req,
        uint256 _value,
        uint256 _relayerGenerationIterationBitmap,
        uint256 _relayerCount,
        RelayerAddress _relayerAddress
    ) internal returns (bool status, bytes memory returndata) {
        (status, returndata) = address(this).call{value: _value}(
            abi.encodePacked(
                _req, _relayerGenerationIterationBitmap, _relayerCount, RelayerAddress.unwrap(_relayerAddress)
            )
        );
    }

    function _executeTransactions(
        bytes[] calldata _reqs,
        uint256[] calldata _forwardedNativeAmounts,
        uint256 _relayerCount,
        RelayerAddress _relayerAddress,
        uint256 _relayerGenerationIterationBitmap
    ) internal {
        uint256 length = _reqs.length;

        for (uint256 i; i != length;) {
            (bool success, bytes memory returndata) = _executeTransaction(
                _reqs[i], _forwardedNativeAmounts[i], _relayerGenerationIterationBitmap, _relayerCount, _relayerAddress
            );

            emit TransactionStatus(i, success, returndata);

            if (!success) {
                revert TransactionExecutionFailed(i);
            }

            unchecked {
                ++i;
            }
        }
    }

    function _verifySufficientValueAttached(uint256[] calldata _forwardedNativeAmounts) internal view {
        uint256 totalExpectedValue;
        uint256 length = _forwardedNativeAmounts.length;
        for (uint256 i; i != length;) {
            totalExpectedValue += _forwardedNativeAmounts[i];
            unchecked {
                ++i;
            }
        }
        if (msg.value != totalExpectedValue) {
            revert InvalidFeeAttached(totalExpectedValue, msg.value);
        }
    }

    /// @notice allows relayer to execute a tx on behalf of a client
    // TODO: can we decrease calldata cost by using merkle proofs or square root decomposition?
    // TODO: Non Reentrant?
    function execute(ExecuteParams calldata _params) public payable {
        uint256 length = _params.reqs.length;
        if (length != _params.forwardedNativeAmounts.length) {
            revert ParameterLengthMismatch();
        }

        _verifySufficientValueAttached(_params.forwardedNativeAmounts);

        // Verify Relayer Selection
        if (
            !_verifyRelayerSelection(
                msg.sender,
                _params.cdf,
                _params.activeRelayers,
                _params.relayerIndex,
                _params.relayerGenerationIterationBitmap,
                block.number
            )
        ) {
            revert InvalidRelayerWindow();
        }

        // Execute Transactions
        _executeTransactions(
            _params.reqs,
            _params.forwardedNativeAmounts,
            _params.activeRelayers.length,
            _params.activeRelayers[_params.relayerIndex],
            _params.relayerGenerationIterationBitmap
        );

        TAStorage storage ts = getTAStorage();

        // Record Liveness Metrics
        // TODO: Is extra store for total transactions TRULY required?
        unchecked {
            ++ts.transactionsSubmitted[ts.epochEndTimestamp][_params.activeRelayers[_params.relayerIndex]];
            ++ts.totalTransactionsSubmitted[ts.epochEndTimestamp];
        }

        // TODO: Check how to update this logic
        // Validate that the relayer has sent enough gas for the call.
        // if (gasleft() <= totalGas / 63) {
        //     assembly {
        //         invalid()
        //     }
        // }
    }

    /////////////////////////////// Allocation Helpers ///////////////////////////////
    // TODO: Use oz
    function _lowerBound(uint16[] calldata arr, uint256 target) internal pure returns (uint256) {
        uint256 low = 0;
        uint256 high = arr.length;
        unchecked {
            while (low < high) {
                uint256 mid = (low + high) / 2;
                if (arr[mid] < target) {
                    low = mid + 1;
                } else {
                    high = mid;
                }
            }
        }
        return low;
    }

    /// @notice Given a block number, the function generates a list of pseudo-random relayers
    ///         for the window of which the block in a part of. The generated list of relayers
    ///         is pseudo-random but deterministic
    /// @return selectedRelayers list of relayers selected of length relayersPerWindow, but
    ///                          there can be duplicates
    /// @return cdfIndex list of indices of the selected relayers in the cdf, used for verification
    function allocateRelayers(uint16[] calldata _cdf, RelayerAddress[] calldata _activeRelayers)
        external
        view
        override
        returns (RelayerAddress[] memory selectedRelayers, uint256[] memory cdfIndex)
    {
        _verifyExternalStateForTransactionAllocation(_cdf, _activeRelayers, block.number);

        if (_cdf.length == 0) {
            revert NoRelayersRegistered();
        }

        if (_cdf[_cdf.length - 1] == 0) {
            revert NoRelayersRegistered();
        }

        {
            RMStorage storage ds = getRMStorage();
            selectedRelayers = new RelayerAddress[](ds.relayersPerWindow);
            cdfIndex = new uint256[](ds.relayersPerWindow);
        }

        for (uint256 i = 0; i != getRMStorage().relayersPerWindow;) {
            uint256 randomCdfNumber = _randomNumberForCdfSelection(block.number, i, _cdf[_cdf.length - 1]);
            cdfIndex[i] = _lowerBound(_cdf, randomCdfNumber);
            selectedRelayers[i] = _activeRelayers[cdfIndex[i]];
            unchecked {
                ++i;
            }
        }
        return (selectedRelayers, cdfIndex);
    }

    ///////////////////////////////// Liveness ///////////////////////////////
    function calculateMinimumTranasctionsForLiveness(
        uint256 _relayerStake,
        uint256 _totalStake,
        FixedPointType _totalTransactions,
        FixedPointType _zScore
    ) public pure override returns (FixedPointType) {
        if (_totalTransactions == FP_ZERO) {
            return FP_ZERO;
        }

        if (_totalStake == 0) {
            revert NoRelayersRegistered();
        }

        FixedPointType p = _relayerStake.fp() / _totalStake.fp();
        FixedPointType s = ((p * (FP_ONE - p)) / _totalTransactions).sqrt();
        FixedPointType d = _zScore * s;
        FixedPointType e = p * _totalTransactions;
        if (e > d) {
            return e - d;
        }

        return FP_ZERO;
    }

    function _verifyRelayerLiveness(
        uint16[] calldata _cdf,
        RelayerAddress[] calldata _activeRelayers,
        uint256 _relayerIndex,
        uint256 _epochEndTimestamp,
        FixedPointType _totalTransactionsInEpoch
    ) internal returns (bool) {
        TAStorage storage ts = getTAStorage();
        FixedPointType minimumTransactions;
        {
            uint256 relayerStakeNormalized = _cdf[_relayerIndex];

            if (_relayerIndex != 0) {
                relayerStakeNormalized -= _cdf[_relayerIndex - 1];
            }

            minimumTransactions = calculateMinimumTranasctionsForLiveness(
                relayerStakeNormalized, _cdf[_cdf.length - 1], _totalTransactionsInEpoch, LIVENESS_Z_PARAMETER
            );
        }

        uint256 transactionsProcessedByRelayer =
            ts.transactionsSubmitted[_epochEndTimestamp][_activeRelayers[_relayerIndex]];
        delete ts.transactionsSubmitted[_epochEndTimestamp][_activeRelayers[_relayerIndex]];
        return transactionsProcessedByRelayer.fp() >= minimumTransactions;
    }

    function _calculatePenalty(uint256 _stake) internal pure returns (uint256) {
        return (_stake * ABSENCE_PENALTY) / (100 * PERCENTAGE_MULTIPLIER);
    }

    function processLivenessCheck(ProcessLivenessCheckParams calldata _params) external override {
        // If this is the first transaction of the epoch, run the liveness check
        TAStorage storage ts = getTAStorage();
        RMStorage storage rms = getRMStorage();

        if (ts.epochEndTimestamp < block.timestamp) {
            revert LivenessCheckAlreadyProcessed();
        }

        // Verify the currently active CDF and active relayers
        _verifyExternalStateForTransactionAllocation(_params.currentCdf, _params.currentActiveRelayers, block.number);

        // Verify the state against which the new CDF would be calculated
        _verifyExternalStateForCdfUpdation(
            _params.latestStakeArray, _params.latestDelegationArray, _params.pendingActiveRelayers
        );

        // Run the liveness check
        _processLivenessCheck(_params);

        // Process any pending Updates
        uint256 updateWindowIndex = _nextWindowForUpdate(block.number);

        // TODO: We don't necessarily need to store this in two different hashes. These can be combined to save gas.
        if (rms.cdfVersionManager.pendingHash != bytes32(0)) {
            rms.cdfVersionManager.setPendingStateForActivation(updateWindowIndex);
        }

        if (rms.activeRelayerListVersionManager.pendingHash != bytes32(0)) {
            rms.activeRelayerListVersionManager.setPendingStateForActivation(updateWindowIndex);
        }

        // Update the epoch end time
        ts.epochEndTimestamp = block.timestamp + ts.epochLengthInSec;
    }

    // TODO: Split the penalty b/w DAO and relayer
    // TODO: Jail the relayer, the relayer needs to topup or leave with their money
    function _processLivenessCheck(ProcessLivenessCheckParams calldata _params) internal {
        TAStorage storage ts = getTAStorage();
        uint256 epochEndTimestamp_ = ts.epochEndTimestamp;
        FixedPointType totalTransactionsInEpoch = ts.totalTransactionsSubmitted[epochEndTimestamp_].fp();
        delete ts.totalTransactionsSubmitted[epochEndTimestamp_];

        // If no transactions were submitted in the epoch, then no need to process liveness check
        if (totalTransactionsInEpoch == FP_ZERO) {
            return;
        }

        uint256 relayerCount = _params.currentActiveRelayers.length;

        uint32[] memory newStakeArray = _params.latestStakeArray;
        bool shouldUpdateCdf;

        for (uint256 i; i != relayerCount;) {
            if (
                _verifyRelayerLiveness(
                    _params.currentCdf, _params.currentActiveRelayers, i, epochEndTimestamp_, totalTransactionsInEpoch
                )
            ) {
                unchecked {
                    ++i;
                }
                continue;
            }

            // Penalize the relayer
            {
                uint256 penalty;
                RelayerAddress relayerAddress = _params.currentActiveRelayers[i];

                // TODO: What happens if relayer stake is less than minimum stake after penalty?
                // TODO: Change withdrawl pattern so that the status of the relayer is set to pending exit

                RelayerInfo storage relayerInfo = getRMStorage().relayerInfo[relayerAddress];
                penalty = _calculatePenalty(relayerInfo.stake);
                relayerInfo.stake -= penalty;

                // If the relayer is not exiting, then we need to update the stake array and CDF
                if (_isStakedRelayer(relayerAddress)) {
                    // Find the index of the relayer in the pending state
                    uint256 newIndex = _params.currentActiveRelayerToPendingActiveRelayersIndex[i];
                    _checkRelayerIndexInNewMapping(
                        _params.currentActiveRelayers, _params.pendingActiveRelayers, i, newIndex
                    );

                    // Update the stake array and CDF
                    newStakeArray[newIndex] = _scaleStake(relayerInfo.stake);
                    shouldUpdateCdf = true;
                }

                // TODO: What should be done with the penalty amount?

                emit RelayerPenalized(relayerAddress, penalty);
            }

            unchecked {
                ++i;
            }
        }

        // Process All CDF Updates if Necessary
        if (shouldUpdateCdf) {
            _updateCdf(newStakeArray, true, _params.latestDelegationArray, false);
        }
    }

    function _checkRelayerIndexInNewMapping(
        RelayerAddress[] calldata _oldRelayerIndexToRelayerMapping,
        RelayerAddress[] calldata _newRelayerIndexToRelayerMapping,
        uint256 _oldIndex,
        uint256 _proposedNewIndex
    ) internal pure {
        if (_oldRelayerIndexToRelayerMapping[_oldIndex] != _newRelayerIndexToRelayerMapping[_proposedNewIndex]) {
            revert RelayerIndexMappingMismatch(_oldIndex, _proposedNewIndex);
        }
    }

    ///////////////////////////////// Getters ///////////////////////////////
    function transactionsSubmittedRelayer(RelayerAddress _relayerAddress) external view override returns (uint256) {
        return getTAStorage().transactionsSubmitted[getTAStorage().epochEndTimestamp][_relayerAddress];
    }

    function totalTransactionsSubmitted() external view override returns (uint256) {
        return getTAStorage().totalTransactionsSubmitted[getTAStorage().epochEndTimestamp];
    }

    function epochLengthInSec() external view override returns (uint256) {
        return getTAStorage().epochLengthInSec;
    }

    function epochEndTimestamp() external view override returns (uint256) {
        return getTAStorage().epochEndTimestamp;
    }
}
