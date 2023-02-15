// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import "forge-std/Test.sol";

import { TierCalculationLib } from "src/libraries/TierCalculationLib.sol";
import { SD59x18, sd, unwrap } from "prb-math/SD59x18.sol";
import { UD60x18, ud } from "prb-math/UD60x18.sol";

contract TierCalculationLibTest is Test {

    function testGetTierOdds() public {
        assertEq(unwrap(TierCalculationLib.getTierOdds(0, 4, 365)), 2739726027397260);
        assertEq(unwrap(TierCalculationLib.getTierOdds(1, 4, 365)), 19579642462506911);
        assertEq(unwrap(TierCalculationLib.getTierOdds(2, 4, 365)), 139927275620255366);
        assertEq(unwrap(TierCalculationLib.getTierOdds(3, 4, 365)), 1e18);
    }

    function testEstimatePrizeFrequencyInDraws() public {
        assertEq(TierCalculationLib.estimatePrizeFrequencyInDraws(0, 4, 365), 366);
        assertEq(TierCalculationLib.estimatePrizeFrequencyInDraws(1, 4, 365), 52);
        assertEq(TierCalculationLib.estimatePrizeFrequencyInDraws(2, 4, 365), 8);
        assertEq(TierCalculationLib.estimatePrizeFrequencyInDraws(3, 4, 365), 1);
    }

    function testPrizeCount() public {
        assertEq(TierCalculationLib.prizeCount(0), 1);
    }

    function testCalculateWinningZoneWithTierOdds() public {
        assertEq(TierCalculationLib.calculateWinningZone(1000, sd(0.333e18), sd(1e18), 1), 333);
    }

    function testCalculateWinningZoneWithVaultPortion() public {
        assertEq(TierCalculationLib.calculateWinningZone(1000, sd(1e18), sd(0.444e18), 1), 444);
    }

    function testCalculateWinningZoneWithPrizeCount() public {
        assertEq(TierCalculationLib.calculateWinningZone(1000, sd(1e18), sd(1e18), 5), 5000);
    }

    function testComputeNextExchangeRateDelta() public {
        (UD60x18 deltaExchangeRate, uint256 remainder) = TierCalculationLib.computeNextExchangeRateDelta(900, 7);
        assertEq(UD60x18.unwrap(deltaExchangeRate), 7777777777777777);
        assertEq(remainder, 1);
    }

    function testEstimatedClaimCount() public {
        // 2: 4.002739726
        // 3: 16.2121093
        // 4: 66.31989471
        // 5: 271.5303328
        // 6: 1109.21076
        // 7: 4518.562795
        // 8: 18359.91762
        // 9: 74437.0802
        // 10: 301242.1839
        // 11: 1217269.1
        // 12: 4912623.73
        // 13: 19805539.61
        // 14: 79777192.14
        // 15: 321105957.4
        // 16: 1291645055

        assertEq(TierCalculationLib.estimatedClaimCount(2, 365), 4);
        assertEq(TierCalculationLib.estimatedClaimCount(3, 365), 16);
        assertEq(TierCalculationLib.estimatedClaimCount(4, 365), 66);
        assertEq(TierCalculationLib.estimatedClaimCount(5, 365), 270);
        assertEq(TierCalculationLib.estimatedClaimCount(6, 365), 1108);
        assertEq(TierCalculationLib.estimatedClaimCount(7, 365), 4517);
        assertEq(TierCalculationLib.estimatedClaimCount(8, 365), 18358);
        assertEq(TierCalculationLib.estimatedClaimCount(9, 365), 74435);
        assertEq(TierCalculationLib.estimatedClaimCount(10, 365), 301239);
        assertEq(TierCalculationLib.estimatedClaimCount(11, 365), 1217266);
        assertEq(TierCalculationLib.estimatedClaimCount(12, 365), 4912619);
        assertEq(TierCalculationLib.estimatedClaimCount(13, 365), 19805536);
        assertEq(TierCalculationLib.estimatedClaimCount(14, 365), 79777187);
        assertEq(TierCalculationLib.estimatedClaimCount(15, 365), 321105952);
        assertEq(TierCalculationLib.estimatedClaimCount(16, 365), 1291645048);
    }

    function testCanaryPrizeCount() public {
        assertEq(TierCalculationLib.canaryPrizeCount(2, 10, 0, 100), 2);
        assertEq(TierCalculationLib.canaryPrizeCount(3, 10, 0, 100), 8);
        assertEq(TierCalculationLib.canaryPrizeCount(4, 10, 0, 100), 31);
        assertEq(TierCalculationLib.canaryPrizeCount(5, 10, 0, 100), 122);
        assertEq(TierCalculationLib.canaryPrizeCount(6, 10, 0, 100), 476);
        assertEq(TierCalculationLib.canaryPrizeCount(7, 10, 0, 100), 1869);
        assertEq(TierCalculationLib.canaryPrizeCount(8, 10, 0, 100), 7362);
        assertEq(TierCalculationLib.canaryPrizeCount(9, 10, 0, 100), 29095);
        assertEq(TierCalculationLib.canaryPrizeCount(10, 10, 0, 100), 115239);
        assertEq(TierCalculationLib.canaryPrizeCount(11, 10, 0, 100), 457216);
        assertEq(TierCalculationLib.canaryPrizeCount(12, 10, 0, 100), 1816376);
        assertEq(TierCalculationLib.canaryPrizeCount(13, 10, 0, 100), 7223167);
        assertEq(TierCalculationLib.canaryPrizeCount(14, 10, 0, 100), 28747343);
        assertEq(TierCalculationLib.canaryPrizeCount(15, 10, 0, 100), 114485055);
    }

}