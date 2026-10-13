// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PerpVault} from "../src/perps/PerpVault.sol";
import {IMD6900} from "../src/IMD6900.sol";

/// A stand-in for PerpEngine's vault-facing surface: the token side's inventory and the short-attributed ETH yield
/// pot, credited the way PerpEngine._routeFee credits it (tokYieldEth and tokYieldCumulative up by the same amount).
contract YieldEngineStub {
    address public token;
    uint256 public plvToken;
    uint256 public tokYieldEth;
    uint256 public tokYieldCumulative;

    constructor(address t) {
        token = t;
    }

    function credit() external payable {
        tokYieldEth += msg.value;
        tokYieldCumulative += msg.value;
    }

    function fundTokenFromVault(uint256 amount) external {
        IMD6900(token).transferFrom(msg.sender, address(this), amount);
        plvToken += amount;
    }

    function withdrawPlvTokenTo(uint256 amount, address to) external {
        plvToken -= amount;
        IMD6900(token).transfer(to, amount);
    }

    function withdrawTokYieldTo(uint256 amount, address to) external {
        tokYieldEth -= amount;
        (bool ok,) = to.call{value: amount}("");
        require(ok);
    }

    function totalTokenAssets() external view returns (uint256) {
        return plvToken;
    }

    function freeToken() external view returns (uint256) {
        return plvToken;
    }

    function totalEth() external pure returns (uint256) {
        return 0;
    }

    function freeEth() external pure returns (uint256) {
        return 0;
    }

    function fundFromVault() external payable {}
    function withdrawPlvTo(uint256, address) external {}
}

/// The reviewer's medium finding on the vault's token-side yield accumulator: shares are minted at 1e6 x the token
/// amount, so a 1e18-scaled index could only resolve yield in steps of tokShares / 1e18 wei. With 300M coins staked
/// (3e32 shares) a step was 3e14 wei: the stakers' 20% of a minimum short's open fee (1.48e14 wei) floored to zero and,
/// the watermark advancing regardless, stayed in the engine's pot with no claimant; a 1 wei deposit after every short
/// stripped the stakers of up to a step each time. The index is 1e36-scaled now: a fold's residue is under a wei.
contract PerpVaultYieldTest is Test {
    uint256 constant STAKE = 300_000_000 ether; // 30% of the supply on the token side
    uint256 constant YIELD = 1.48e14; // PerpEngine: 0.01074 ETH sent, 6.9% open fee, 20% of it to the stakers
    address constant STAKER = address(0x57A4E);
    address constant WATCHER = address(0xBAD);

    IMD6900 coin;
    YieldEngineStub engine;
    PerpVault vault;

    function setUp() public {
        coin = new IMD6900(address(this));
        engine = new YieldEngineStub(address(coin));
        vault = new PerpVault(address(engine));
        coin.transfer(STAKER, STAKE);
        vm.prank(STAKER);
        coin.approve(address(vault), STAKE);
        vm.prank(STAKER);
        vault.depositToken(STAKE); // the only staker: every wei of yield from here on is theirs
        vm.deal(address(this), 10 ether);
    }

    function test_AMinimumShortsYieldReachesTheOnlyStaker() public {
        engine.credit{value: YIELD}(); // a short opens: its fee's LP share lands in the pot
        uint256 pending = vault.pendingTokYield(STAKER);
        assertGe(pending, YIELD - 1, "the only staker's yield, to the wei");
        assertLe(pending, YIELD);
        vm.prank(STAKER);
        uint256 paid = vault.claimTokYield();
        assertEq(paid, pending, "the view is what the claim pays");
        assertLe(engine.tokYieldEth(), 1, "nothing of it left in the pot with no claimant");
    }

    function test_FoldingAfterEveryShortStripsNothing() public {
        // a watcher folds the index after each of 50 small credits with a 1 wei deposit (the attack the finding
        // describes): what the staker can claim is still the whole pot, less at most a wei per fold
        coin.transfer(WATCHER, 100);
        vm.prank(WATCHER);
        coin.approve(address(vault), 100);
        uint256 total;
        for (uint256 i; i < 50; i++) {
            engine.credit{value: YIELD}();
            total += YIELD;
            vm.prank(WATCHER);
            vault.depositToken(1);
        }
        uint256 pending = vault.pendingTokYield(STAKER) + vault.pendingTokYield(WATCHER);
        assertGe(pending, total - 50, "the pot is the stakers', not the index's rounding");
        vm.prank(STAKER);
        uint256 paid = vault.claimTokYield();
        assertGe(paid, total - 50 - 1e6, "the watcher's 1-wei stakes earn only their 1e-20 share");
        assertLe(engine.tokYieldEth(), 1e6 + 50, "the pot is paid out");
    }

    function test_TheIndexSurvivesASingleShareAndAWholeSupplyOfYield() public {
        // the other end of the scale: the whole supply staked and a lot of yield, then the stake withdrawn down to a
        // few shares and more yield: no overflow, every wei still claimable
        address whale = address(0x3A1E);
        coin.transfer(whale, coin.balanceOf(address(this)));
        vm.startPrank(whale);
        coin.approve(address(vault), type(uint256).max);
        vault.depositToken(coin.balanceOf(whale));
        vm.stopPrank();
        engine.credit{value: 5 ether}();
        uint256 stakerShares = vault.tokShareOf(STAKER);
        uint256 whaleShares = vault.tokShareOf(whale);
        vm.prank(STAKER);
        (uint256 paidTok,) = vault.withdrawToken(stakerShares - 1);
        assertGt(paidTok, 0);
        vm.prank(whale);
        (uint256 paidWhale,) = vault.withdrawToken(whaleShares - 1);
        assertGt(paidWhale, 0);
        engine.credit{value: 1 ether}();
        vm.prank(STAKER);
        uint256 a = vault.claimTokYield();
        vm.prank(whale);
        uint256 b = vault.claimTokYield();
        assertGe(a + b, 6 ether - 10, "all of it, to a few wei");
    }
}
