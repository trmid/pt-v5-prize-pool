// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.17;

import { RingBufferLib } from "ring-buffer-lib/RingBufferLib.sol";
import { E, SD59x18, sd, unwrap, toSD59x18, fromSD59x18 } from "prb-math/SD59x18.sol";

/// @notice Emitted when adding balance for draw zero.
error AddToDrawZero();

/// @notice Emitted when an action can't be done on a closed draw.
/// @param drawId The ID of the closed draw
/// @param newestDrawId The newest draw ID
error DrawClosed(uint16 drawId, uint16 newestDrawId);

/// @notice Emitted when a draw range is not strictly increasing.
/// @param startDrawId The start draw ID of the range
/// @param endDrawId The end draw ID of the range
error InvalidDrawRange(uint16 startDrawId, uint16 endDrawId);

/// @notice Emitted when the end draw ID for a disbursed range is invalid (too old).
/// @param endDrawId The end draw ID for the range
error InvalidDisbursedEndDrawId(uint16 endDrawId);

struct Observation {
  // track the total amount available as of this Observation
  uint96 available;
  // track the total accumulated previously
  uint168 disbursed;
}

/// @title Draw Accumulator Lib
/// @author PoolTogether Inc. Team
/// @notice This contract distributes tokens over time according to an exponential weighted average. Time is divided into discrete "draws", of which each is allocated tokens.
library DrawAccumulatorLib {
  /// @notice The maximum number of observations that can be recorded.
  uint24 internal constant MAX_CARDINALITY = 366;

  /// @notice The metadata for using the ring buffer.
  struct RingBufferInfo {
    uint16 nextIndex;
    uint16 cardinality;
  }

  /// @notice An accumulator for a draw.
  struct Accumulator {
    RingBufferInfo ringBufferInfo;
    uint16[366] drawRingBuffer;
    mapping(uint256 => Observation) observations;
  }

  /// @notice A pair of uint16s.
  struct Pair32 {
    uint16 first;
    uint16 second;
  }

  /// @notice Adds balance for the given draw id to the accumulator.
  /// @param accumulator The accumulator to add to
  /// @param _amount The amount of balance to add
  /// @param _drawId The draw id to which to add balance to. This must be greater than or equal to the previous addition's draw id.
  /// @param _alpha The alpha value to use for the exponential weighted average.
  /// @return True if a new observation was created, false otherwise.
  function add(
    Accumulator storage accumulator,
    uint256 _amount,
    uint16 _drawId,
    SD59x18 _alpha
  ) internal returns (bool) {
    if (_drawId == 0) {
      revert AddToDrawZero();
    }
    RingBufferInfo memory ringBufferInfo = accumulator.ringBufferInfo;

    uint256 newestIndex = RingBufferLib.newestIndex(ringBufferInfo.nextIndex, MAX_CARDINALITY);
    uint16 newestDrawId_ = accumulator.drawRingBuffer[newestIndex];

    if (_drawId < newestDrawId_) {
      revert DrawClosed(_drawId, newestDrawId_);
    }

    Observation memory newestObservation_ = accumulator.observations[newestDrawId_];
    if (_drawId != newestDrawId_) {
      uint256 relativeDraw = _drawId - newestDrawId_;

      uint256 remainingAmount = integrateInf(_alpha, relativeDraw, newestObservation_.available);
      uint256 disbursedAmount = integrate(_alpha, 0, relativeDraw, newestObservation_.available);
      uint256 remainder = newestObservation_.available - (remainingAmount + disbursedAmount);

      accumulator.drawRingBuffer[ringBufferInfo.nextIndex] = _drawId;
      accumulator.observations[_drawId] = Observation({
        available: uint96(_amount + remainingAmount),
        disbursed: uint168(newestObservation_.disbursed + disbursedAmount + remainder)
      });
      uint16 nextIndex = uint16(RingBufferLib.nextIndex(ringBufferInfo.nextIndex, MAX_CARDINALITY));
      uint16 cardinality = ringBufferInfo.cardinality;
      if (ringBufferInfo.cardinality < MAX_CARDINALITY) {
        cardinality += 1;
      }
      accumulator.ringBufferInfo = RingBufferInfo({
        nextIndex: nextIndex,
        cardinality: cardinality
      });
      return true;
    } else {
      accumulator.observations[newestDrawId_] = Observation({
        available: uint96(newestObservation_.available + _amount),
        disbursed: newestObservation_.disbursed
      });
      return false;
    }
  }

  /// @notice Gets the total remaining balance after and including the given start draw id. This is the sum of all draw balances from start draw id to infinity.
  /// The start draw id must be greater than or equal to the newest draw id.
  /// @param accumulator The accumulator to sum
  /// @param _startDrawId The draw id to start summing from, inclusive
  /// @param _alpha The alpha value to use for the exponential weighted average
  /// @return The sum of draw balances from start draw to infinity
  function getTotalRemaining(
    Accumulator storage accumulator,
    uint16 _startDrawId,
    SD59x18 _alpha
  ) internal view returns (uint256) {
    RingBufferInfo memory ringBufferInfo = accumulator.ringBufferInfo;
    if (ringBufferInfo.cardinality == 0) {
      return 0;
    }
    uint256 newestIndex = RingBufferLib.newestIndex(ringBufferInfo.nextIndex, MAX_CARDINALITY);
    uint16 newestDrawId_ = accumulator.drawRingBuffer[newestIndex];
    if (_startDrawId < newestDrawId_) {
      revert DrawClosed(_startDrawId, newestDrawId_);
    }
    Observation memory newestObservation_ = accumulator.observations[newestDrawId_];
    return integrateInf(_alpha, _startDrawId - newestDrawId_, newestObservation_.available);
  }

  /// @notice Returns the newest draw id from the accumulator.
  /// @param accumulator The accumulator to get the newest draw id from
  /// @return The newest draw id
  function newestDrawId(Accumulator storage accumulator) internal view returns (uint256) {
    return
      accumulator.drawRingBuffer[
        RingBufferLib.newestIndex(accumulator.ringBufferInfo.nextIndex, MAX_CARDINALITY)
      ];
  }

  /// @notice Retrieves the newest observation from the accumulator.
  /// @param accumulator The accumulator to retrieve the newest observation from
  /// @return The newest observation
  function newestObservation(
    Accumulator storage accumulator
  ) internal view returns (Observation memory) {
    return accumulator.observations[newestDrawId(accumulator)];
  }

  /// @notice Gets the balance that was disbursed between the given start and end draw ids, inclusive.
  /// This function has an intentional limitation on the value of `_endDrawId` to save gas, but
  /// prevents historical disbursement queries that end more than one draw before the last
  /// accumulator observation.
  /// @param _accumulator The accumulator to get the disbursed balance from
  /// @param _startDrawId The start draw id, inclusive
  /// @param _endDrawId The end draw id, inclusive (limitation: cannot be more than one draw before the last observed draw)
  /// @param _alpha The alpha value to use for the exponential weighted average
  /// @return The disbursed balance between the given start and end draw ids, inclusive
  function getDisbursedBetween(
    Accumulator storage _accumulator,
    uint16 _startDrawId,
    uint16 _endDrawId,
    SD59x18 _alpha
  ) internal view returns (uint256) {
    if (_startDrawId > _endDrawId) {
      revert InvalidDrawRange(_startDrawId, _endDrawId);
    }

    RingBufferInfo memory ringBufferInfo = _accumulator.ringBufferInfo;

    if (ringBufferInfo.cardinality == 0) {
      return 0;
    }

    Pair32 memory indexes = computeIndices(ringBufferInfo);
    Pair32 memory drawIds = readDrawIds(_accumulator, indexes);

    /**
            This check intentionally limits the `_endDrawId` to be no more than one draw before the
            latest observation. This allows us to make assumptions on the value of `lastObservationDrawIdOccurringAtOrBeforeEnd` and removes the need to run a additional
            binary search to find it.
         */
    if (_endDrawId < drawIds.second - 1) {
      revert InvalidDisbursedEndDrawId(_endDrawId);
    }

    if (_endDrawId < drawIds.first) {
      return 0;
    }

    /*

        head: residual accrual from observation before start. (if any)
        body: if there is more than one observations between start and current, then take the past _accumulator diff
        tail: accrual between the newest observation and current.  if card > 1 there is a tail (almost always)

        let:
            - s = start draw id
            - e = end draw id
            - o = observation
            - h = "head". residual balance from the last o occurring before s.  head is the disbursed amount between (o, s)
            - t = "tail". the residual balance from the last o occuring before e.  tail is the disbursed amount between (o, e)
            - b = "body". if there are *two* observations between s and e we calculate how much was disbursed. body is (last obs disbursed - first obs disbursed)

        total = head + body + tail


        lastObservationOccurringAtOrBeforeEnd
        firstObservationOccurringAtOrAfterStart

        Like so

           s        e
        o  <h>  o  <t>  o

           s                 e
        o  <h> o   <b>  o  <t>  o

         */

    uint16 lastObservationDrawIdOccurringAtOrBeforeEnd;
    if (_endDrawId >= drawIds.second) {
      // then it must be the end
      lastObservationDrawIdOccurringAtOrBeforeEnd = drawIds.second;
    } else {
      // otherwise it must be the previous one
      lastObservationDrawIdOccurringAtOrBeforeEnd = _accumulator.drawRingBuffer[
        uint16(RingBufferLib.offset(indexes.second, 1, ringBufferInfo.cardinality))
      ];
    }

    uint16 observationDrawIdBeforeOrAtStart;
    uint16 firstObservationDrawIdOccurringAtOrAfterStart;
    // if there is only one observation, or startId is after the oldest record
    if (_startDrawId >= drawIds.second) {
      // then use the last record
      observationDrawIdBeforeOrAtStart = drawIds.second;
    } else if (_startDrawId <= drawIds.first) {
      // if the start is before the newest record
      // then set to the oldest record.
      firstObservationDrawIdOccurringAtOrAfterStart = drawIds.first;
    } else {
      // The start must be between newest and oldest
      // binary search
      (
        ,
        observationDrawIdBeforeOrAtStart,
        ,
        firstObservationDrawIdOccurringAtOrAfterStart
      ) = binarySearch(
        _accumulator.drawRingBuffer,
        indexes.first,
        indexes.second,
        ringBufferInfo.cardinality,
        _startDrawId
      );
    }

    uint256 total;

    // if a "head" exists
    if (
      observationDrawIdBeforeOrAtStart > 0 &&
      firstObservationDrawIdOccurringAtOrAfterStart > 0 &&
      observationDrawIdBeforeOrAtStart != lastObservationDrawIdOccurringAtOrBeforeEnd
    ) {
      Observation memory beforeOrAtStart = _accumulator.observations[
        observationDrawIdBeforeOrAtStart
      ];
      uint16 headStartDrawId = _startDrawId - observationDrawIdBeforeOrAtStart;
      uint16 headEndDrawId = headStartDrawId +
        (firstObservationDrawIdOccurringAtOrAfterStart - _startDrawId);
      uint amount = integrate(_alpha, headStartDrawId, headEndDrawId, beforeOrAtStart.available);
      total += amount;
    }

    Observation memory atOrBeforeEnd;
    // if a "body" exists
    if (
      firstObservationDrawIdOccurringAtOrAfterStart > 0 &&
      firstObservationDrawIdOccurringAtOrAfterStart < lastObservationDrawIdOccurringAtOrBeforeEnd
    ) {
      Observation memory atOrAfterStart = _accumulator.observations[
        firstObservationDrawIdOccurringAtOrAfterStart
      ];
      atOrBeforeEnd = _accumulator.observations[lastObservationDrawIdOccurringAtOrBeforeEnd];
      uint amount = atOrBeforeEnd.disbursed - atOrAfterStart.disbursed;
      total += amount;
    }

    total += _computeTail(
      _accumulator,
      _startDrawId,
      _endDrawId,
      lastObservationDrawIdOccurringAtOrBeforeEnd,
      _alpha
    );

    return total;
  }

  /// @notice Computes the "tail" for the given accumulator and range. The tail is the residual balance from the last observation occurring before the end draw id.
  /// @param accumulator The accumulator to compute for
  /// @param _startDrawId The start draw id, inclusive
  /// @param _endDrawId The end draw id, inclusive
  /// @param _lastObservationDrawIdOccurringAtOrBeforeEnd The last observation draw id occurring at or before the end draw id
  /// @return The total balance of the tail of the range.
  function _computeTail(
    Accumulator storage accumulator,
    uint16 _startDrawId,
    uint16 _endDrawId,
    uint16 _lastObservationDrawIdOccurringAtOrBeforeEnd,
    SD59x18 _alpha
  ) internal view returns (uint256) {
    Observation memory lastObservation = accumulator.observations[
      _lastObservationDrawIdOccurringAtOrBeforeEnd
    ];
    uint16 tailRangeStartDrawId = (
      _startDrawId > _lastObservationDrawIdOccurringAtOrBeforeEnd
        ? _startDrawId
        : _lastObservationDrawIdOccurringAtOrBeforeEnd
    ) - _lastObservationDrawIdOccurringAtOrBeforeEnd;
    uint256 amount = integrate(
      _alpha,
      tailRangeStartDrawId,
      _endDrawId - _lastObservationDrawIdOccurringAtOrBeforeEnd + 1,
      lastObservation.available
    );
    return amount;
  }

  /// @notice Computes the first and last indices of observations for the given ring buffer info.
  /// @param ringBufferInfo The ring buffer info to compute for
  /// @return A pair of indices, where the first is the oldest index and the second is the newest index
  function computeIndices(
    RingBufferInfo memory ringBufferInfo
  ) internal pure returns (Pair32 memory) {
    return
      Pair32({
        first: uint16(
          RingBufferLib.oldestIndex(
            ringBufferInfo.nextIndex,
            ringBufferInfo.cardinality,
            MAX_CARDINALITY
          )
        ),
        second: uint16(
          RingBufferLib.newestIndex(ringBufferInfo.nextIndex, ringBufferInfo.cardinality)
        )
      });
  }

  /// @notice Retrieves the draw ids for the given accumulator observation indices.
  /// @param accumulator The accumulator to retrieve from
  /// @param indices The indices to retrieve
  /// @return A pair of draw ids, where the first is the draw id of the pair's first index and the second is the draw id of the pair's second index
  function readDrawIds(
    Accumulator storage accumulator,
    Pair32 memory indices
  ) internal view returns (Pair32 memory) {
    return
      Pair32({
        first: uint16(accumulator.drawRingBuffer[indices.first]),
        second: uint16(accumulator.drawRingBuffer[indices.second])
      });
  }

  /// @notice Integrates from the given x to infinity for the exponential weighted average.
  /// @param _alpha The exponential weighted average smoothing parameter.
  /// @param _x The x value to integrate from.
  /// @param _k The k value to scale the sum (this is the total available balance).
  /// @return The integration from x to inf of the EWA for the given parameters.
  function integrateInf(SD59x18 _alpha, uint _x, uint _k) internal pure returns (uint256) {
    return uint256(fromSD59x18(computeC(_alpha, _x, _k)));
  }

  /// @notice Integrates from the given start x to end x for the exponential weighted average.
  /// @param _alpha The exponential weighted average smoothing parameter.
  /// @param _start The x value to integrate from.
  /// @param _end The x value to integrate to
  /// @param _k The k value to scale the sum (this is the total available balance).
  /// @return The integration from start to end of the EWA for the given parameters.
  function integrate(
    SD59x18 _alpha,
    uint _start,
    uint _end,
    uint _k
  ) internal pure returns (uint256) {
    int start = unwrap(computeC(_alpha, _start, _k));
    int end = unwrap(computeC(_alpha, _end, _k));
    return uint256(fromSD59x18(sd(start - end)));
  }

  /// @notice Computes the interim value C for the EWA.
  /// @param _alpha The exponential weighted average smoothing parameter.
  /// @param _x The x value to compute for
  /// @param _k The total available balance
  /// @return The value C
  function computeC(SD59x18 _alpha, uint _x, uint _k) internal pure returns (SD59x18) {
    return toSD59x18(int(_k)).mul(_alpha.pow(toSD59x18(int256(_x))));
  }

  /// @notice Binary searches an array of draw ids for the given target draw id.
  /// @param _drawRingBuffer The array of draw ids to search
  /// @param _oldestIndex The oldest index in the ring buffer
  /// @param _newestIndex The newest index in the ring buffer
  /// @param _cardinality The number of items in the ring buffer
  /// @param _targetLastClosedDrawId The target draw id to search for
  /// @return beforeOrAtIndex The index of the observation occurring at or before the target draw id
  /// @return beforeOrAtDrawId The draw id of the observation occurring at or before the target draw id
  /// @return afterOrAtIndex The index of the observation occurring at or after the target draw id
  /// @return afterOrAtDrawId The draw id of the observation occurring at or after the target draw id
  function binarySearch(
    uint16[366] storage _drawRingBuffer,
    uint16 _oldestIndex,
    uint16 _newestIndex,
    uint16 _cardinality,
    uint16 _targetLastClosedDrawId
  )
    internal
    view
    returns (
      uint16 beforeOrAtIndex,
      uint16 beforeOrAtDrawId,
      uint16 afterOrAtIndex,
      uint16 afterOrAtDrawId
    )
  {
    uint16 leftSide = _oldestIndex;
    uint16 rightSide = _newestIndex < leftSide ? leftSide + _cardinality - 1 : _newestIndex;
    uint16 currentIndex;

    while (true) {
      // We start our search in the middle of the `leftSide` and `rightSide`.
      // After each iteration, we narrow down the search to the left or the right side while still starting our search in the middle.
      currentIndex = (leftSide + rightSide) / 2;

      beforeOrAtIndex = uint16(RingBufferLib.wrap(currentIndex, _cardinality));
      beforeOrAtDrawId = _drawRingBuffer[beforeOrAtIndex];

      afterOrAtIndex = uint16(RingBufferLib.nextIndex(currentIndex, _cardinality));
      afterOrAtDrawId = _drawRingBuffer[afterOrAtIndex];

      bool targetAtOrAfter = beforeOrAtDrawId <= _targetLastClosedDrawId;

      // Check if we've found the corresponding Observation.
      if (targetAtOrAfter && _targetLastClosedDrawId <= afterOrAtDrawId) {
        break;
      }

      // If `beforeOrAtTimestamp` is greater than `_target`, then we keep searching lower. To the left of the current index.
      if (!targetAtOrAfter) {
        rightSide = currentIndex - 1;
      } else {
        // Otherwise, we keep searching higher. To the left of the current index.
        leftSide = currentIndex + 1;
      }
    }
  }
}
