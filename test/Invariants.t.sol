// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IMD6900Hook} from "../src/IMD6900Hook.sol";
import {IMD6900LockedPool} from "../src/IMD6900LockedPool.sol";
import {IMD6900RobinhoodLaunch} from "../src/IMD6900RobinhoodLaunch.sol";
import {PerpEngine} from "../src/perps/PerpEngine.sol";
import {PerpVault} from "../src/perps/PerpVault.sol";
import {HookSalt, CoinSalt} from "./HookSalt.sol";
import {MockImdstr, Trader, Refuser} from "./IMD6900RobinhoodLaunch.t.sol";

interface IERC20View {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @dev What every invariant suite here launches: the PoolManager, the launch (from its artifact, as the other suites
///      do), the hook at a mined salt, the coin at 0x6900, the pool opened at 19.18 ETH with the 2.81 ETH opening buy,
///      the excess held for the timelock, three claimants in the snapshot.
abstract contract LaunchedFixture is Test {
    using StateLibrary for IPoolManager;

    address constant OWNER = address(0xA11CE);
    address constant TL = address(0x71E10C);
    address constant POT = 0xc39e650a24985C2bBA9FD83C81041B8f3E3f9EDd;
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant BUY = 2.81 ether;
    uint256 constant OPEN_MC = 19.18 ether;

    address constant A = address(0xA);
    address constant B = address(0xB);
    address constant C = address(0xC);
    uint256 constant AA = 40_000_000 ether;
    uint256 constant BB = 20_000_000 ether;
    uint256 constant CC = 3_935_747 ether;

    IPoolManager PM;
    IMD6900RobinhoodLaunch L;
    IMD6900Hook hook;
    IMD6900LockedPool pool;
    MockImdstr imdstr;
    address coin;
    bytes32[] leaves;

    function _deployAndLaunch() internal {
        PM = IPoolManager(address(new PoolManager(address(this))));
        imdstr = new MockImdstr();
        L = IMD6900RobinhoodLaunch(
            payable(vm.deployCode(
                    "IMD6900RobinhoodLaunch.sol:IMD6900RobinhoodLaunch", abi.encode(OWNER, PM, address(imdstr), TL)
                ))
        );
        hook = L.createHook(HookSalt.mine(L));
        pool = L.pool();
        imdstr.mint(A, AA);
        imdstr.mint(B, BB);
        imdstr.mint(C, CC);
        leaves.push(_leaf(A, AA));
        leaves.push(_leaf(B, BB));
        leaves.push(_leaf(C, CC));
        vm.prank(OWNER);
        L.setClaims(_root(), AA + BB + CC, block.timestamp + 100 days);
        bytes32 salt = CoinSalt.mine(L);
        address expected = L.tokenAddress(salt);
        vm.deal(OWNER, BUY);
        vm.prank(OWNER);
        (coin,) = L.launch{value: BUY}(salt, expected, _sqrtPrice(OPEN_MC), 0, address(L));
    }

    function _sqrtPrice(uint256 mc) internal pure returns (uint160) {
        return uint160(_sqrt(FullMath.mulDiv(SUPPLY, 1 << 192, mc)));
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) (y, z) = (z, (x / z + z) / 2);
    }

    function _leaf(address a, uint256 amt) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a, amt))));
    }

    function _hash(bytes32 x, bytes32 y) internal pure returns (bytes32) {
        return x < y ? keccak256(abi.encodePacked(x, y)) : keccak256(abi.encodePacked(y, x));
    }

    function _root() internal view returns (bytes32) {
        return _hash(_hash(leaves[0], leaves[1]), leaves[2]);
    }

    function _proof(uint256 i) internal view returns (bytes32[] memory p) {
        if (i == 2) {
            p = new bytes32[](1);
            p[0] = _hash(leaves[0], leaves[1]);
        } else {
            p = new bytes32[](2);
            p[0] = leaves[i == 0 ? 1 : 0];
            p[1] = leaves[2];
        }
    }
}

/*                                                                                                              */
/*                                   THE LAUNCH, THE POOL AND THE SPLIT                                         */
/*                                                                                                              */

/// @dev Drives the launched system with bounded inputs from several actors: claimants, traders, the timelock, and
///      anyone's harvest. Every call that may legitimately revert is tried; what went through is counted.
contract LaunchHandler is Test {
    using StateLibrary for IPoolManager;

    IPoolManager immutable PM;
    IMD6900RobinhoodLaunch immutable L;
    IMD6900LockedPool immutable pool;
    MockImdstr immutable imdstr;
    address immutable coin;
    address immutable TL;
    address immutable OWNER;
    Refuser public immutable refuser;

    address[3] public claimants;
    uint256[3] public allowances;
    bytes32[][3] proofs;
    Trader[3] public traders;
    address public constant SINK = address(0x5111C); // where released coins and recovered ETH land

    // ghosts
    uint256 public ghostClaimed;
    uint256 public ghostEthIn; // ETH that entered the launch outside the launch itself (fees, gifts)
    uint256 public ghostSplitPaid;
    uint256 public ghostRecovered;
    uint256 public ghostSold;
    uint256 public ghostReleased;
    uint256 public ghostMoves;
    uint256 public ghostTrades;
    uint256 public ghostClaims;
    uint256 public ghostHarvests;
    uint256 public ghostSplitCalls;
    uint256 public ghostImdstrReleased;
    uint256 public ghostCoinBurned;
    uint24 public ghostLastFee;
    bool public ghostEnded;
    bool public ghostPayeesSet;

    constructor(
        IPoolManager pm,
        IMD6900RobinhoodLaunch l,
        address coin_,
        MockImdstr imdstr_,
        address tl,
        address owner_,
        address[3] memory cs,
        uint256[3] memory as_,
        bytes32[][3] memory ps
    ) {
        (PM, L, coin, imdstr, TL, OWNER) = (pm, l, coin_, imdstr_, tl, owner_);
        pool = l.pool();
        for (uint256 i; i < 3; ++i) {
            (claimants[i], allowances[i]) = (cs[i], as_[i]);
        }
        proofs[0] = ps[0];
        proofs[1] = ps[1];
        proofs[2] = ps[2];
        for (uint256 i; i < 3; ++i) {
            traders[i] = new Trader(pm);
            vm.deal(address(traders[i]), 50 ether);
        }
        refuser = new Refuser();
        ghostLastFee = pool.fee();
    }

    /*                                 ACTORS                                 */

    function claim(uint256 who, uint256 amount) external {
        who = bound(who, 0, 2);
        address a = claimants[who];
        uint256 left = allowances[who] - L.claimedBy(a);
        amount = bound(amount, 0, left + 1); // zero and one-over included
        vm.prank(a);
        imdstr.approve(address(L), amount);
        vm.prank(a);
        try L.claim(amount, allowances[who], proofs[who]) {
            ghostClaimed += amount;
            ++ghostClaims;
            assertLe(amount, left, "a claim over the allowance went through");
            assertGt(amount, 0, "a zero claim went through");
        } catch {}
    }

    function buy(uint256 who, uint256 eth) external {
        who = bound(who, 0, 2);
        eth = bound(eth, 0.001 ether, 3 ether);
        Trader t = traders[who];
        if (address(t).balance < eth) vm.deal(address(t), eth);
        try t.swap(pool.poolKey(), true, -int256(eth)) {
            ++ghostTrades;
        } catch {}
    }

    function sell(uint256 who, uint256 part) external {
        who = bound(who, 0, 2);
        Trader t = traders[who];
        uint256 bal = IERC20View(coin).balanceOf(address(t));
        if (bal == 0) return;
        uint256 amount = bound(part, 1, bal);
        try t.swap(pool.poolKey(), false, -int256(amount)) {
            ++ghostTrades;
        } catch {}
    }

    /// @dev Harvest = collect + split; the two legs are taken apart so the ledger sees what came in and what went out
    function harvest() external {
        uint256 supplyBefore = IERC20View(coin).totalSupply();
        uint256 balBefore = address(L).balance;
        try pool.collect() {
            ghostCoinBurned += supplyBefore - IERC20View(coin).totalSupply();
            ghostEthIn += address(L).balance - balBefore;
        } catch {
            return;
        }
        balBefore = address(L).balance;
        try L.split() {
            ++ghostHarvests;
            _accountSplit(balBefore);
        } catch {}
    }

    function split() external {
        uint256 balBefore = address(L).balance;
        try L.split() {
            ++ghostSplitCalls;
            _accountSplit(balBefore);
        } catch {}
    }

    function collect() external {
        uint256 supplyBefore = IERC20View(coin).totalSupply();
        uint256 balBefore = address(L).balance;
        try pool.collect() {
            ghostCoinBurned += supplyBefore - IERC20View(coin).totalSupply();
            ghostEthIn += address(L).balance - balBefore;
        } catch {}
    }

    function gift(uint256 eth) external {
        eth = bound(eth, 1, 1 ether);
        vm.deal(address(this), eth);
        (bool ok,) = address(L).call{value: eth}("");
        if (ok) ghostEthIn += eth;
    }

    /*                               THE TIMELOCK                             */

    function sellHeld(uint256 part) external {
        uint256 held = L.excessHeld();
        if (held == 0) return;
        uint256 amount = bound(part, 1, held);
        uint256 heldBefore = held;
        vm.prank(TL);
        try L.sellHeld(amount, 0, SINK) returns (uint256) {
            ghostSold += heldBefore - L.excessHeld();
        } catch {}
    }

    function releaseExcess(uint256 part, bool burn) external {
        uint256 held = L.excessHeld();
        if (held == 0) return;
        uint256 amount = bound(part, 1, held);
        uint256 supplyBefore = IERC20View(coin).totalSupply();
        vm.prank(TL);
        try L.releaseExcess(amount, burn ? address(0) : SINK) {
            ghostReleased += amount;
            ghostCoinBurned += supplyBefore - IERC20View(coin).totalSupply();
        } catch {}
    }

    function endClaims() external {
        vm.prank(TL);
        try L.endClaims() {
            ghostEnded = true;
        } catch {}
    }

    function recoverEth(uint256 part) external {
        uint256 bal = address(L).balance;
        if (bal == 0) return;
        uint256 amount = bound(part, 1, bal);
        vm.prank(TL);
        try L.recoverEth(SINK, amount) {
            ghostRecovered += amount;
        } catch {}
    }

    function lowerFee(uint24 newFee) external {
        newFee = uint24(bound(newFee, 0, pool.fee()));
        uint256 balBefore = address(L).balance;
        uint256 supplyBefore = IERC20View(coin).totalSupply();
        vm.prank(TL);
        try pool.lowerFee(newFee) {
            ++ghostMoves;
            ghostEthIn += address(L).balance - balBefore; // the old pool's fees, paid out like a collect
            ghostCoinBurned += supplyBefore - IERC20View(coin).totalSupply();
        } catch {}
    }

    /// @dev The payees: the default pair, or the refuser (refusing or not) beside the pot
    function setPayees(uint256 mode) external {
        mode = bound(mode, 0, 3);
        refuser.setOpen(mode % 2 == 1);
        address[] memory to = new address[](2);
        uint16[] memory bps = new uint16[](2);
        (to[0], bps[0]) = (POT_(), 5_000);
        (to[1], bps[1]) = (mode < 2 ? address(refuser) : L.imdBurn(), 5_000);
        vm.prank(TL);
        L.setPayees(to, bps);
        ghostPayeesSet = true;
    }

    function releaseImdstr(uint256 part) external {
        uint256 held = imdstr.balanceOf(address(L));
        if (held == 0) return;
        uint256 amount = bound(part, 1, held);
        vm.prank(OWNER);
        try L.releaseImdstr(amount, SINK) {
            ghostImdstrReleased += amount;
        } catch {}
    }

    function warp(uint256 by) external {
        vm.warp(block.timestamp + bound(by, 1, 30 days));
    }

    /*                                INTERNAL                                */

    function _accountSplit(uint256 balBefore) internal {
        // what left the launch in this split: it went to payees (the pot, the refuser)
        uint256 after_ = address(L).balance;
        if (balBefore > after_) ghostSplitPaid += balBefore - after_;
    }

    function POT_() internal view returns (address) {
        return L.POT_BRIDGE();
    }

    function holders() external view returns (address[] memory h) {
        h = new address[](9);
        h[0] = address(L);
        h[1] = address(pool);
        h[2] = address(PM);
        h[3] = address(traders[0]);
        h[4] = address(traders[1]);
        h[5] = address(traders[2]);
        h[6] = claimants[0];
        h[7] = claimants[1];
        h[8] = claimants[2];
    }

    receive() external payable {}
}

/// forge-config: default.invariant.runs = 48
/// forge-config: default.invariant.depth = 40
/// forge-config: default.invariant.fail-on-revert = false
contract LaunchInvariantsTest is LaunchedFixture {
    using StateLibrary for IPoolManager;

    LaunchHandler h;
    uint128 openingLiquidity;

    function setUp() public {
        _deployAndLaunch();
        address[3] memory cs = [A, B, C];
        uint256[3] memory as_ = [AA, BB, CC];
        bytes32[][3] memory ps = [_proof(0), _proof(1), _proof(2)];
        h = new LaunchHandler(PM, L, coin, imdstr, TL, OWNER, cs, as_, ps);
        openingLiquidity = pool.liquidity();
        targetContract(address(h));
    }

    /// The handler isn't vacuous: its claims, trades, splits and the timelock's moves go through
    function test_TheHandlerDrivesTheLaunch() public {
        h.claim(0, AA);
        assertEq(h.ghostClaims(), 1, "A's claim didn't go through");
        h.claim(0, 1); // over the allowance now: refused, not counted
        assertEq(h.ghostClaims(), 1);
        h.buy(0, 1 ether);
        h.sell(0, IERC20View(coin).balanceOf(address(h.traders(0))));
        assertEq(h.ghostTrades(), 2, "the trades didn't go through");
        h.setPayees(0); // the refuser, refusing
        h.harvest();
        assertEq(h.ghostHarvests(), 1);
        assertGt(L.owedTotal(), 0, "the refuser's share isn't owed");
        h.sellHeld(L.excessHeld());
        assertGt(h.ghostSold(), 0, "the sale didn't go through");
        h.lowerFee(33_300);
        assertEq(h.ghostMoves(), 1, "the move didn't go through");
        h.endClaims();
        assertTrue(h.ghostEnded());
        h.recoverEth(address(L).balance);
        assertGt(h.ghostRecovered(), 0);
        assertEq(L.owedTotal(), 0, "recovering everything cancels the owed book");
    }

    /// The coins the launch holds are exactly the claims' reserve plus what it holds for the timelock: a claim, a
    /// sale, a release or the end of the claims moves them, nothing else, and nothing leaves unaccounted.
    function invariant_TheLaunchHoldsTheReserveAndTheExcess() public view {
        assertEq(
            IERC20View(coin).balanceOf(address(L)),
            L.claimReserve() + L.excessHeld(),
            "coins held != claims reserve + excess held"
        );
    }

    /// Claims never exceed the list, each claimant never exceeds the snapshot, and the IMDSTR taken in equals the
    /// coins claimed out (less what the owner sent home).
    function invariant_ClaimsAreOneForOneAndBounded() public view {
        assertLe(L.claimedTotal(), L.claimTotal(), "claimed over the list");
        assertEq(L.claimedTotal(), h.ghostClaimed(), "claimed total drifted from the claims made");
        assertLe(L.claimedBy(A), AA);
        assertLe(L.claimedBy(B), BB);
        assertLe(L.claimedBy(C), CC);
        assertEq(
            imdstr.balanceOf(address(L)) + h.ghostImdstrReleased(), L.claimedTotal(), "IMDSTR in != IMD6900 claimed"
        );
    }

    /// Once the claims end (by the deadline or the timelock), they never reopen
    function invariant_EndedClaimsStayEnded() public {
        if (!L.unclaimedReleased()) return;
        assertEq(L.claimReserve(), 0, "a reserve after the claims ended");
        vm.prank(A);
        imdstr.approve(address(L), 1);
        vm.prank(A);
        vm.expectRevert(IMD6900RobinhoodLaunch.AlreadyReleased.selector);
        L.claim(1, AA, _proof(0));
    }

    /// The launch's ETH always covers what it has set aside ($IMD's bucket) and what it owes a payee that refused
    function invariant_TheLaunchCoversItsBookings() public view {
        assertGe(address(L).balance, L.imdBucket() + L.owedTotal(), "booked more ETH than held");
        assertEq(
            L.owed(address(h.refuser())) + L.owed(L.POT_BRIDGE()) + L.owed(L.imdBurn()), L.owedTotal(), "owed book"
        );
    }

    /// The coin's supply only ever falls (burns), and every coin is somewhere we can name: the pool, the launch, the
    /// traders, the claimants, the sink
    function invariant_TheCoinIsConserved() public view {
        uint256 supply = IERC20View(coin).totalSupply();
        assertLe(supply, SUPPLY, "supply grew");
        assertEq(supply, SUPPLY - h.ghostCoinBurned(), "supply fell by other than the burns we saw");
        address[] memory hs = h.holders();
        uint256 sum = IERC20View(coin).balanceOf(h.SINK());
        for (uint256 i; i < hs.length; ++i) {
            sum += IERC20View(coin).balanceOf(hs[i]);
        }
        assertEq(sum, supply, "coins held by someone we can't name");
    }

    /// The fee is static per pool and only ever moves down; the liquidity stays whole (to the rounding of a move) and
    /// in the pool the locked pool names, never anywhere else
    function invariant_TheFeeOnlyFallsAndTheLiquidityStays() public view {
        uint24 fee = pool.fee();
        assertLe(fee, 44_400, "the fee rose over the opening fee");
        PoolId id = pool.poolId();
        uint128 inPool = PM.getLiquidity(id);
        assertEq(inPool, pool.liquidity(), "the pool's liquidity != the locked pool's record");
        assertGe(uint256(inPool), uint256(openingLiquidity) * 999_999 / 1_000_000, "liquidity lost in a move");
        (uint160 p,,,) = PM.getSlot0(id);
        assertGt(p, 0, "the current pool isn't initialized");
    }

    /// After the launch, ETH leaves only through the split, the $IMD buys, the timelock's recovery or the sale's
    /// proceeds: what came in less what went out is what is held
    function invariant_EthIsAccounted() public view {
        // the launch's balance = ETH in (fees, gifts) - split out - recovered. The sale's ETH never lands here (it
        // goes to the sink straight from the unlock).
        uint256 expected = h.ghostEthIn() - h.ghostSplitPaid() - h.ghostRecovered();
        assertEq(address(L).balance, expected, "ETH held drifted from the ledger");
    }
}

/*                                                                                                              */
/*                                        THE PERPS ENGINE AND VAULT                                            */
/*                                                                                                              */

/// @dev Drives the perps: traders open longs and shorts and close them, stakers deposit and withdraw on both sides,
///      outside traders move the price (which trips the hook's pre-trade sweep), time passes, fees are flushed.
contract PerpsHandler is Test {
    IPoolManager immutable PM;
    IMD6900LockedPool immutable pool;
    PerpEngine immutable engine;
    PerpVault immutable vault;
    IMD6900RobinhoodLaunch immutable L;
    address immutable coin;
    address immutable TL;

    address[3] public perpTraders = [address(0xA1), address(0xA2), address(0xA3)];
    address[2] public stakers = [address(0x57A1), address(0x57A2)];
    Trader[2] public spot;
    uint256[] public ids;

    uint256 public ghostOpens;
    uint256 public ghostCloses;
    uint256 public ghostSpotTrades;
    uint256 public ghostDeposits;
    uint256 public ghostWithdrawals;
    uint256 public ghostLiquidations;
    uint256 public ghostFlushed;
    uint256 public ghostEthStaked;
    uint256 public ghostEthUnstaked;

    constructor(IPoolManager pm, IMD6900RobinhoodLaunch l, PerpEngine e, PerpVault v, address coin_, address tl) {
        (PM, L, engine, vault, coin, TL) = (pm, l, e, v, coin_, tl);
        pool = l.pool();
        for (uint256 i; i < 2; ++i) {
            spot[i] = new Trader(pm);
            vm.deal(address(spot[i]), 30 ether);
        }
        for (uint256 i; i < 3; ++i) {
            vm.deal(perpTraders[i], 10 ether);
        }
        for (uint256 i; i < 2; ++i) {
            vm.deal(stakers[i], 30 ether);
        }
    }

    function openLong(uint256 who, uint256 collateral, uint8 lev) external {
        who = bound(who, 0, 2);
        collateral = bound(collateral, 0.005 ether, 0.3 ether);
        lev = uint8(bound(lev, 1, 6)); // 6: over the maximum, must be refused
        address t = perpTraders[who];
        if (t.balance < collateral) vm.deal(t, collateral);
        uint256 before = engine.openCount();
        vm.prank(t);
        try engine.openLong{value: collateral}(lev, 0) returns (uint256 id) {
            ids.push(id);
            ++ghostOpens;
            assertLe(lev, engine.maxLeverage(), "a long over the maximum leverage opened");
            assertFalse(engine.isLiquidatable(id), "a long born liquidatable");
            _countLiquidations(before + 1);
        } catch {}
    }

    function openShort(uint256 who, uint256 collateral, uint8 lev) external {
        who = bound(who, 0, 2);
        collateral = bound(collateral, 0.005 ether, 0.3 ether);
        lev = uint8(bound(lev, 1, 6));
        address t = perpTraders[who];
        if (t.balance < collateral) vm.deal(t, collateral);
        uint256 before = engine.openCount();
        vm.prank(t);
        try engine.openShort{value: collateral}(lev, 0) returns (uint256 id) {
            ids.push(id);
            ++ghostOpens;
            assertLe(lev, engine.maxLeverage(), "a short over the maximum leverage opened");
            assertFalse(engine.isLiquidatable(id), "a short born liquidatable");
            _countLiquidations(before + 1);
        } catch {}
    }

    function close(uint256 which) external {
        if (ids.length == 0) return;
        which = bound(which, 0, ids.length - 1);
        uint256 id = ids[which];
        (, address trader,,,,,,) = _position(id);
        if (trader == address(0)) return; // closed or liquidated already
        uint256 before = engine.openCount();
        vm.prank(trader);
        try engine.close(id, 0) {
            ++ghostCloses;
            _countLiquidations(before - 1);
        } catch {}
    }

    /// @dev Someone else can't close a trader's position
    function closeAsStranger(uint256 which, uint256 who) external {
        if (ids.length == 0) return;
        which = bound(which, 0, ids.length - 1);
        uint256 id = ids[which];
        (, address trader,,,,,,) = _position(id);
        if (trader == address(0)) return;
        address s = perpTraders[bound(who, 0, 2)];
        if (s == trader) s = address(0xDEAD1);
        vm.prank(s);
        try engine.close(id, 0) {
            assertTrue(false, "a stranger closed someone else's position");
        } catch {}
    }

    function liquidate(uint256 which) external {
        if (ids.length == 0) return;
        which = bound(which, 0, ids.length - 1);
        uint256 id = ids[which];
        (, address trader,,,,,,) = _position(id);
        if (trader == address(0)) return;
        bool liq = engine.isLiquidatable(id);
        uint256 before = engine.openCount();
        try engine.liquidate(id) {
            assertTrue(liq, "a healthy position was liquidated by a keeper");
            _countLiquidations(before - 1);
        } catch {}
    }

    function spotBuy(uint256 who, uint256 eth) external {
        who = bound(who, 0, 1);
        eth = bound(eth, 0.01 ether, 4 ether);
        Trader t = spot[who];
        if (address(t).balance < eth) vm.deal(address(t), eth);
        uint256 before = engine.openCount();
        try t.swap(pool.poolKey(), true, -int256(eth)) {
            ++ghostSpotTrades;
            _countLiquidations(before);
        } catch {}
    }

    function spotSell(uint256 who, uint256 part) external {
        who = bound(who, 0, 1);
        Trader t = spot[who];
        uint256 bal = IERC20View(coin).balanceOf(address(t));
        if (bal == 0) return;
        uint256 amount = bound(part, 1, bal);
        uint256 before = engine.openCount();
        try t.swap(pool.poolKey(), false, -int256(amount)) {
            ++ghostSpotTrades;
            _countLiquidations(before);
        } catch {}
    }

    function depositEth(uint256 who, uint256 eth) external {
        who = bound(who, 0, 1);
        eth = bound(eth, 0.001 ether, 5 ether);
        address s = stakers[who];
        if (s.balance < eth) vm.deal(s, eth);
        vm.prank(s);
        try vault.depositEth{value: eth}() {
            ++ghostDeposits;
            ghostEthStaked += eth;
        } catch {}
    }

    function withdrawEth(uint256 who, uint256 part) external {
        who = bound(who, 0, 1);
        address s = stakers[who];
        uint256 shares = vault.ethShareOf(s);
        if (shares == 0) return;
        uint256 amount = bound(part, 1, shares);
        uint256 before = s.balance;
        vm.prank(s);
        try vault.withdrawEth(amount) returns (uint256 paid, uint256) {
            ++ghostWithdrawals;
            ghostEthUnstaked += paid;
            assertEq(s.balance - before, paid, "paid != received");
        } catch {}
    }

    function claimPendingEth(uint256 who) external {
        who = bound(who, 0, 1);
        address s = stakers[who];
        uint256 before = s.balance;
        vm.prank(s);
        try vault.claimPendingEth() returns (uint256 paid) {
            ghostEthUnstaked += paid;
            assertEq(s.balance - before, paid, "claimed != received");
        } catch {}
    }

    function depositToken(uint256 who, uint256 part) external {
        who = bound(who, 0, 1);
        Trader t = spot[who];
        uint256 bal = IERC20View(coin).balanceOf(address(t));
        if (bal == 0) return;
        uint256 amount = bound(part, 1, bal);
        vm.prank(address(t));
        IERC20View(coin).approve(address(vault), amount);
        vm.prank(address(t));
        try vault.depositToken(amount) {
            ++ghostDeposits;
        } catch {}
    }

    function withdrawToken(uint256 who, uint256 part) external {
        who = bound(who, 0, 1);
        address s = address(spot[who]);
        uint256 shares = vault.tokShareOf(s);
        if (shares == 0) return;
        uint256 amount = bound(part, 1, shares);
        vm.prank(s);
        try vault.withdrawToken(amount) {
            ++ghostWithdrawals;
        } catch {}
    }

    function flushFees() external {
        uint256 potBefore = L.perpFeeTo().balance;
        try engine.flushFees() returns (uint256 amount) {
            ghostFlushed += amount;
            assertEq(L.perpFeeTo().balance - potBefore, amount, "the engine's fees didn't all reach the pot");
        } catch {}
    }

    function poke(uint256 by) external {
        vm.warp(block.timestamp + bound(by, 1, 6 hours));
        engine.poke();
    }

    function lowerFee(uint24 newFee) external {
        newFee = uint24(bound(newFee, 0, pool.fee()));
        bool open = engine.openCount() != 0;
        vm.prank(TL);
        try pool.lowerFee(newFee) {
            assertFalse(open, "the fee moved with perps open");
        } catch {}
    }

    function _countLiquidations(uint256 expectedWithoutLiq) internal {
        uint256 now_ = engine.openCount();
        if (now_ < expectedWithoutLiq) ghostLiquidations += expectedWithoutLiq - now_;
    }

    function _position(uint256 id)
        internal
        view
        returns (uint256, address, bool, uint256, uint256, uint256, uint256, uint256)
    {
        (address trader,,,,,,,) = engine.positions(id);
        return (0, trader, false, 0, 0, 0, 0, 0);
    }

    receive() external payable {}
}

/// forge-config: default.invariant.runs = 32
/// forge-config: default.invariant.depth = 40
/// forge-config: default.invariant.fail-on-revert = false
contract PerpsInvariantsTest is LaunchedFixture {
    using StateLibrary for IPoolManager;

    PerpEngine engine;
    PerpVault vault;
    PerpsHandler h;
    uint128 openingLiquidity;

    function setUp() public {
        _deployAndLaunch();
        vm.deal(address(this), 1 ether);
        (address e, address v) = pool.createPerps{value: 0.05 ether}(
            vm.getCode("PerpEngine.sol:PerpEngine"), vm.getCode("PerpVault.sol:PerpVault")
        );
        (engine, vault) = (PerpEngine(payable(e)), PerpVault(payable(v)));
        pool.collect();
        h = new PerpsHandler(PM, L, engine, vault, coin, TL);
        openingLiquidity = pool.liquidity();
        targetContract(address(h));
    }

    /// The brief's claim under test: liquidation inside the hook's sweep never leaves bad debt on the stakers
    function invariant_NoBadDebt() public view {
        assertEq(engine.unabsorbedEth(), 0, "bad debt beyond insurance and the whole PLV");
    }

    /// The engine holds every wei it books: the stakers' free ETH, the insurance, the token side's yield, the fees it
    /// owes the pot, and the payouts it owes traders
    function invariant_TheEngineHoldsWhatItBooks() public view {
        uint256 booked =
            engine.plv() + engine.insuranceEth() + engine.tokYieldEth() + engine.feesOwed() + engine.payoutOwedTotal();
        assertGe(address(engine).balance, booked, "the engine books more ETH than it holds");
    }

    /// The engine holds the token it lends and the token its longs hold
    function invariant_TheEngineHoldsItsToken() public view {
        assertGe(
            IERC20View(coin).balanceOf(address(engine)),
            engine.plvToken() + engine.longSizeToken(),
            "the engine books more token than it holds"
        );
    }

    /// The open book is consistent and bounded
    function invariant_TheOpenBookIsBounded() public view {
        uint256[] memory open = engine.openIds();
        assertEq(open.length, engine.openCount(), "openCount != open ids");
        assertLe(open.length, engine.MAX_OPEN_POSITIONS());
        if (open.length == 0) {
            assertEq(engine.longOiEth(), 0, "long OI with no longs");
            assertEq(engine.longSizeToken(), 0, "long size with no longs");
            assertEq(engine.shortOiToken(), 0, "short OI with no shorts");
        }
    }

    /// The vault's shares never claim more than the engine's ETH side owns
    function invariant_TheVaultIsBackedByTheEngine() public view {
        assertLe(vault.pendingEth(), engine.totalEth() + 1, "queued exits beyond the engine's ETH side");
        if (vault.ethShares() == 0) {
            // no stakers: nothing but dust may be attributed to the ETH side
            assertLe(vault.assetsEth(), engine.totalEth());
        }
    }

    /// The pool stays whole under perps trading, and the fee never moves while they are open
    function invariant_ThePoolStaysWholeUnderThePerps() public view {
        PoolId id = pool.poolId();
        assertEq(PM.getLiquidity(id), pool.liquidity(), "the pool's liquidity != the locked pool's record");
        assertGe(uint256(PM.getLiquidity(id)), uint256(openingLiquidity) * 999_999 / 1_000_000);
        assertLe(pool.fee(), 44_400);
        if (pool.fee() != 44_400) assertEq(engine.openCount(), 0, "the fee moved under open positions");
    }

    /// The handler isn't vacuous: with stakers in, its longs and shorts open, close and get liquidated
    function test_TheHandlerDrivesThePerps() public {
        h.depositEth(0, 5 ether); // every input in its handler's bound (bound wraps, it doesn't clamp)
        assertEq(h.ghostDeposits(), 1);
        assertEq(engine.plv(), 5 ether);
        h.openLong(0, 0.1 ether, 5);
        assertEq(h.ghostOpens(), 1, "the handler's long didn't open");
        h.openLong(1, 0.1 ether, 6);
        assertEq(h.ghostOpens(), 1, "6x opened");
        h.closeAsStranger(0, 1);
        h.close(0);
        assertEq(h.ghostCloses(), 1, "the handler's close didn't close");
        h.spotBuy(0, 2 ether);
        h.depositToken(0, IERC20View(coin).balanceOf(address(h.spot(0))));
        assertGt(engine.plvToken(), 0, "the token side isn't staked");
        h.openShort(2, 0.1 ether, 2);
        assertEq(h.ghostOpens(), 2, "the handler's short didn't open");
        h.openLong(0, 0.1 ether, 5);
        h.spotBuy(1, 3 ether);
        h.flushFees();
        assertGt(h.ghostFlushed(), 0, "no fees to flush");
        assertEq(engine.feesOwed(), 0);
    }

    /// The launch holds nothing of the perps' fees: every wei the engine flushes goes straight on to the pot
    function invariant_PerpFeesNeverStayInTheLaunch() public view {
        assertGe(L.perpFeeTo().balance, h.ghostFlushed(), "flushed fees didn't reach the pot");
    }
}
