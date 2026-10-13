// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IMD6900LockedPool} from "../src/IMD6900LockedPool.sol";
import {IMD6900RobinhoodLaunch} from "../src/IMD6900RobinhoodLaunch.sol";
import {LaunchedFixture, IERC20View} from "./Invariants.t.sol";
import {Refuser, Trader} from "./IMD6900RobinhoodLaunch.t.sol";

/// The inputs the happy path never sends: zero, one over, the wrong caller, the same call twice, a payee that
/// refuses. Every test here is a failure path or an edge the launch must hold at.
contract EdgesTest is LaunchedFixture {
    using StateLibrary for IPoolManager;

    address constant STRANGER = address(0xBAD);

    function setUp() public {
        _deployAndLaunch();
    }

    /*                               THE SPLIT                               */

    function test_SetPayeesRefusesBadLists() public {
        address[] memory to = new address[](2);
        uint16[] memory bps = new uint16[](2);
        (to[0], bps[0], to[1], bps[1]) = (POT, 5_000, address(0x1), 5_000);
        vm.prank(STRANGER);
        vm.expectRevert(IMD6900RobinhoodLaunch.NotTimelock.selector);
        L.setPayees(to, bps);
        // a zero payee
        to[1] = address(0);
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadPayees.selector);
        L.setPayees(to, bps);
        // shares that don't sum to 100%
        (to[1], bps[1]) = (address(0x1), 4_999);
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadPayees.selector);
        L.setPayees(to, bps);
        bps[1] = 5_001;
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadPayees.selector);
        L.setPayees(to, bps);
        // lengths that differ
        uint16[] memory one = new uint16[](1);
        one[0] = 10_000;
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadPayees.selector);
        L.setPayees(to, one);
        // none
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadPayees.selector);
        L.setPayees(new address[](0), new uint16[](0));
        // one too many
        address[] memory nine = new address[](9);
        uint16[] memory nineBps = new uint16[](9);
        for (uint256 i; i < 9; ++i) {
            (nine[i], nineBps[i]) = (address(uint160(i + 1)), i == 8 ? 2_000 : 1_000);
        }
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadPayees.selector);
        L.setPayees(nine, nineBps);
        // exactly eight is fine
        address[] memory eight = new address[](8);
        uint16[] memory eightBps = new uint16[](8);
        for (uint256 i; i < 8; ++i) {
            (eight[i], eightBps[i]) = (address(uint160(i + 1)), i == 7 ? 3_000 : 1_000);
        }
        vm.prank(TL);
        L.setPayees(eight, eightBps);
        (address[] memory got, uint16[] memory gotBps) = L.payees();
        assertEq(got.length, 8);
        assertEq(gotBps[7], 3_000);
        // the default comes back only as an explicit list; a one-payee list is fine too
        address[] memory single = new address[](1);
        single[0] = POT;
        vm.prank(TL);
        L.setPayees(single, one);
        (got,) = L.payees();
        assertEq(got.length, 1);
    }

    function test_ASplitWithNothingToPayIsANoOp() public {
        assertEq(L.split(), 0);
        assertEq(L.imdBucket(), 0);
    }

    /// Every ETH-landing address the timelock sets refuses zero, and the perps' refuses the launch itself (it would
    /// loop the fee into the split)
    function test_LandingAddressesRefuseZeroAndSelf() public {
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadPayees.selector);
        L.setPerpFeeTo(address(0));
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadPayees.selector);
        L.setPerpFeeTo(address(L));
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadPayees.selector);
        L.setImdBurn(address(0));
        vm.prank(STRANGER);
        vm.expectRevert(IMD6900RobinhoodLaunch.NotTimelock.selector);
        L.setPerpFeeTo(STRANGER);
        vm.prank(STRANGER);
        vm.expectRevert(IMD6900RobinhoodLaunch.NotTimelock.selector);
        L.setImdKeeper(STRANGER);
        vm.prank(STRANGER);
        vm.expectRevert(IMD6900LockedPool.OnlyTimelock.selector);
        pool.setCoinFeeTo(STRANGER);
    }

    /// The perps' fees are forwarded, never kept: a pot that refuses them makes the flush revert rather than leave
    /// the ETH in the launch
    function test_PerpFeesAreNeverKeptWhenThePotRefuses() public {
        Refuser r = new Refuser();
        vm.prank(TL);
        L.setPerpFeeTo(address(r));
        vm.deal(address(this), 1 ether);
        vm.expectRevert();
        L.addPerpFees{value: 1 ether}();
        assertEq(address(L).balance, 0, "nothing of the perps' fee stayed in the launch");
        r.setOpen(true);
        L.addPerpFees{value: 1 ether}();
        assertEq(address(r).balance, 1 ether);
        assertEq(address(L).balance, 0);
    }

    /// Recovering more than what is free cancels the bookings (the owed shares, $IMD's bucket), never leaves them
    /// claiming ETH that is gone
    function test_RecoveringEthClampsTheBookings() public {
        Refuser r = new Refuser();
        address[] memory to = new address[](2);
        uint16[] memory bps = new uint16[](2);
        (to[0], bps[0], to[1], bps[1]) = (address(r), 5_000, L.imdBurn(), 5_000);
        vm.prank(TL);
        L.setPayees(to, bps);
        vm.deal(address(this), 2 ether);
        (bool ok,) = address(L).call{value: 2 ether}("");
        assertTrue(ok);
        L.split();
        assertEq(L.owedTotal(), 1 ether, "the refuser's share is owed");
        assertEq(L.imdBucket(), 1 ether, "$IMD's share is set aside");
        vm.prank(STRANGER);
        vm.expectRevert(IMD6900RobinhoodLaunch.NotTimelock.selector);
        L.recoverEth(STRANGER, 1);
        vm.prank(TL);
        L.recoverEth(TL, 1.5 ether);
        assertEq(L.owedTotal(), 0, "the owed book is cancelled when it can't be covered");
        assertEq(L.owed(address(r)), 0);
        assertEq(L.imdBucket(), 0.5 ether, "the bucket clamps to what is left");
        vm.prank(TL);
        L.recoverEth(TL, 0);
        assertEq(address(L).balance, 0);
        assertEq(L.imdBucket(), 0);
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.NoEth.selector);
        L.recoverEth(TL, 0);
    }

    function test_BurnImdWithNothingSetAside() public {
        vm.prank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.NoEth.selector);
        L.burnImd(0);
    }

    /*                              THE CLAIMS                               */

    function test_ClaimFailurePaths() public {
        vm.startPrank(A);
        imdstr.approve(address(L), AA);
        vm.expectRevert(IMD6900RobinhoodLaunch.ZeroAmount.selector);
        L.claim(0, AA, _proof(0));
        vm.expectRevert(IMD6900RobinhoodLaunch.BadProof.selector);
        L.claim(1, AA + 1, _proof(0)); // another allowance than the snapshot's
        vm.expectRevert(IMD6900RobinhoodLaunch.BadProof.selector);
        L.claim(1, AA, _proof(1)); // someone else's proof
        vm.expectRevert(IMD6900RobinhoodLaunch.OverClaim.selector);
        L.claim(AA + 1, AA, _proof(0));
        L.claim(AA - 1, AA, _proof(0));
        L.claim(1, AA, _proof(0)); // the last wei, in a second call
        vm.expectRevert(IMD6900RobinhoodLaunch.OverClaim.selector);
        L.claim(1, AA, _proof(0));
        vm.stopPrank();
        assertEq(L.claimedBy(A), AA);
        assertEq(IERC20View(coin).balanceOf(A), AA);
        assertEq(imdstr.balanceOf(address(L)), AA);
        // B can't claim with A's leaf
        vm.prank(B);
        imdstr.approve(address(L), BB);
        vm.prank(B);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadProof.selector);
        L.claim(1, AA, _proof(0));
    }

    function test_ReleasingTheUnclaimedTwiceOrEarlyIsRefused() public {
        vm.prank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.ClaimsOpen.selector);
        L.releaseUnclaimed(address(0));
        vm.warp(L.claimDeadline());
        vm.prank(STRANGER);
        vm.expectRevert();
        L.releaseUnclaimed(address(0));
        uint256 supply = IERC20View(coin).totalSupply();
        vm.prank(OWNER);
        L.releaseUnclaimed(address(0));
        assertEq(supply - IERC20View(coin).totalSupply(), AA + BB + CC, "the whole reserve burned");
        assertEq(L.claimReserve(), 0);
        vm.prank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.AlreadyReleased.selector);
        L.releaseUnclaimed(address(0));
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.AlreadyReleased.selector);
        L.endClaims();
    }

    function test_ReleaseImdstrRefusesOverHeld() public {
        vm.prank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.ZeroAmount.selector);
        L.releaseImdstr(0, OWNER); // nothing held yet
        vm.prank(A);
        imdstr.approve(address(L), 5);
        vm.prank(A);
        L.claim(5, AA, _proof(0));
        vm.prank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.ZeroAmount.selector);
        L.releaseImdstr(6, OWNER);
        vm.prank(STRANGER);
        vm.expectRevert();
        L.releaseImdstr(5, STRANGER);
        vm.prank(OWNER);
        L.releaseImdstr(0, OWNER);
        assertEq(imdstr.balanceOf(OWNER), 5);
    }

    /*                        THE HELD COINS                                 */

    function test_ReleaseExcessRefusesSelfOverHeldAndStrangers() public {
        uint256 held = L.excessHeld();
        assertGt(held, 0);
        vm.prank(STRANGER);
        vm.expectRevert(IMD6900RobinhoodLaunch.NotTimelock.selector);
        L.releaseExcess(1, STRANGER);
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadTo.selector);
        L.releaseExcess(1, address(L));
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.ZeroAmount.selector);
        L.releaseExcess(held + 1, TL);
        vm.prank(TL);
        L.releaseExcess(held - 1, TL);
        assertEq(L.excessHeld(), 1);
        uint256 supply = IERC20View(coin).totalSupply();
        vm.prank(TL);
        L.releaseExcess(0, address(0)); // the last wei, burned
        assertEq(L.excessHeld(), 0);
        assertEq(supply - IERC20View(coin).totalSupply(), 1);
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.ZeroAmount.selector);
        L.releaseExcess(0, TL);
        // the claims' reserve is never the timelock's to release
        assertEq(IERC20View(coin).balanceOf(address(L)), L.claimReserve());
    }

    function test_SellHeldRefusesOverHeldAndBelowTheFloor() public {
        uint256 held = L.excessHeld();
        vm.prank(STRANGER);
        vm.expectRevert(IMD6900RobinhoodLaunch.NotTimelock.selector);
        L.sellHeld(1, 0, STRANGER);
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.ZeroAmount.selector);
        L.sellHeld(held + 1, 0, TL);
        vm.prank(TL);
        vm.expectRevert(abi.encodeWithSelector(IMD6900RobinhoodLaunch.Short.selector, 0));
        L.sellHeld(1, 1, TL); // one wei of coin sells for no ETH at all: short of a 1 wei floor
        pool.collect(); // the opening buy's fee out of the way, so the pool's balance moves by the sale alone
        uint256 poolBefore = address(PM).balance;
        vm.prank(TL);
        uint256 eth = L.sellHeld(0, 0, TL);
        assertGt(eth, 0);
        assertEq(TL.balance, eth, "the ETH went where told");
        assertEq(poolBefore - address(PM).balance, eth, "and came out of the pool");
        assertLt(L.excessHeld(), held, "what sold left the held coins");
        assertEq(IERC20View(coin).balanceOf(address(L)), L.claimReserve() + L.excessHeld());
    }

    /*                              THE POOL                                 */

    function test_ThePoolsEntryPointsAreTheLaunchersAndTheManagers() public {
        vm.expectRevert(IMD6900LockedPool.OnlyLauncher.selector);
        pool.createHook(bytes32(0));
        vm.expectRevert(IMD6900LockedPool.OnlyLauncher.selector);
        pool.open(coin, 1 << 96, 1);
        vm.expectRevert(IMD6900LockedPool.OnlyPoolManager.selector);
        pool.unlockCallback(abi.encode(uint8(1), uint128(0)));
        vm.expectRevert(IMD6900RobinhoodLaunch.OnlyPoolManager.selector);
        L.unlockCallback(abi.encode(uint8(0), uint256(1)));
        vm.expectRevert(IMD6900LockedPool.NotRefunded.selector);
        pool.feeCheckpoint();
        vm.expectRevert(IMD6900LockedPool.NoCheckpoint.selector);
        pool.feeRefund(address(this));
        // the launch itself can't open the pool again
        vm.prank(address(L));
        vm.expectRevert(IMD6900LockedPool.AlreadyOpen.selector);
        pool.open(coin, 1 << 96, 1);
        vm.prank(address(L));
        vm.expectRevert(IMD6900LockedPool.HookAlreadySet.selector);
        pool.createHook(bytes32(0));
    }

    function test_TheFeeGoesToZeroAndNoLower() public {
        vm.prank(TL);
        pool.lowerFee(0);
        assertEq(pool.fee(), 0);
        vm.prank(TL);
        vm.expectRevert(IMD6900LockedPool.NotLower.selector);
        pool.lowerFee(0);
        // and the zero-fee pool trades
        Trader t = new Trader(PM);
        vm.deal(address(t), 1 ether);
        t.swap(pool.poolKey(), true, -0.5 ether);
        assertGt(IERC20View(coin).balanceOf(address(t)), 0);
        (uint256 eth,) = pool.collect();
        assertEq(eth, 0, "a zero-fee pool earns nothing");
    }

    /// forge-config: default.fuzz.runs = 200
    function testFuzz_LowerFeeKeepsThePositionWholeAtAnyLowerFee(uint24 newFee) public {
        newFee = uint24(bound(newFee, 0, 44_399));
        uint128 before = pool.liquidity();
        PoolId oldId = pool.poolId();
        vm.prank(TL);
        uint128 after_ = pool.lowerFee(newFee);
        assertEq(pool.fee(), newFee);
        assertEq(pool.liquidity(), after_);
        assertEq(PM.getLiquidity(pool.poolId()), after_, "in the new pool");
        assertEq(PM.getLiquidity(oldId), 0, "nothing left in the old");
        assertGe(uint256(after_), uint256(before) * 999_999 / 1_000_000, "the whole position, to the rounding");
        assertLe(after_, before);
    }

    /// forge-config: default.fuzz.runs = 200
    function testFuzz_NeverAHigherFee(uint24 newFee) public {
        newFee = uint24(bound(newFee, 44_400, type(uint24).max));
        vm.prank(TL);
        vm.expectRevert(IMD6900LockedPool.NotLower.selector);
        pool.lowerFee(newFee);
    }

    /// forge-config: default.fuzz.runs = 200
    function testFuzz_ClaimsNeverExceedTheSnapshot(uint256 first, uint256 second) public {
        first = bound(first, 1, AA);
        second = bound(second, 1, AA);
        vm.startPrank(A);
        imdstr.approve(address(L), AA);
        L.claim(first, AA, _proof(0));
        if (first + second > AA) {
            vm.expectRevert(IMD6900RobinhoodLaunch.OverClaim.selector);
            L.claim(second, AA, _proof(0));
        } else {
            L.claim(second, AA, _proof(0));
        }
        vm.stopPrank();
        assertLe(L.claimedBy(A), AA);
        assertEq(IERC20View(coin).balanceOf(A), L.claimedBy(A));
        assertEq(imdstr.balanceOf(address(L)), L.claimedBy(A));
    }

    /// forge-config: default.fuzz.runs = 200
    function testFuzz_TheCoinsAddressIsTheCreate2Address(bytes32 salt) public view {
        bytes32 h = keccak256(abi.encodePacked(bytes1(0xff), address(L), salt, L.tokenInitCodeHash()));
        assertEq(L.tokenAddress(salt), address(uint160(uint256(h))));
    }

    /// forge-config: default.fuzz.runs = 100
    function testFuzz_ASplitPaysProRataAndKeepsTheBurnShare(uint96 amount) public {
        amount = uint96(bound(amount, 1, 100 ether));
        vm.deal(address(this), amount);
        (bool ok,) = address(L).call{value: amount}("");
        assertTrue(ok);
        uint256 potBefore = POT.balance;
        L.split();
        assertEq(POT.balance - potBefore, uint256(amount) * 9_000 / 10_000, "90% to the pot");
        assertEq(L.imdBucket(), uint256(amount) * 1_000 / 10_000, "10% set aside for $IMD");
        assertLe(address(L).balance - L.imdBucket(), 1, "nothing but a wei of rounding stays, for the next split");
        assertLe(L.split(), 1, "nothing but that wei to split twice");
    }
}
