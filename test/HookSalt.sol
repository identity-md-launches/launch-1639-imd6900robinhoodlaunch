// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IMD6900RobinhoodLaunch} from "../src/IMD6900RobinhoodLaunch.sol";

/// @dev What script/launch.sh's `hook` step mines with cast, for the tests: the first salt whose CREATE2 address from
///      the locked pool carries exactly its FLAGS and doesn't start with 0x91
library HookSalt {
    function mine(IMD6900RobinhoodLaunch l) internal view returns (bytes32) {
        return mine(l, 0);
    }

    function mine(IMD6900RobinhoodLaunch l, uint256 from) internal view returns (bytes32 s) {
        bytes32 initHash = l.hookInitCodeHash();
        address deployer = address(l.pool());
        uint160 flags = l.FLAGS();
        for (uint256 i = from;; ++i) {
            address a = Create2Address.compute(deployer, bytes32(i), initHash);
            if (uint160(a) & Hooks.ALL_HOOK_MASK == flags && uint160(a) >> 152 != 0x91) return bytes32(i);
        }
    }
}

/// @dev What script/mine.sh mines with cast, for the tests: the first salt whose CREATE2 address for the coin starts
///      with the launch's VANITY (0x6900)
library CoinSalt {
    function mine(IMD6900RobinhoodLaunch l) internal view returns (bytes32 s) {
        bytes32 initHash = l.tokenInitCodeHash();
        uint160 vanity = l.VANITY();
        for (uint256 i;; ++i) {
            address a = Create2Address.compute(address(l), bytes32(i), initHash);
            if (uint160(a) >> 144 == vanity) return bytes32(i);
        }
    }
}

/// @dev The CREATE2 address, hashed in place (no allocation per try: a long search allocating each try runs out of
///      memory before it runs out of gas)
library Create2Address {
    function compute(address deployer, bytes32 salt, bytes32 initHash) internal pure returns (address a) {
        assembly ("memory-safe") {
            let p := mload(0x40) // temporary, beyond the free memory pointer, never persisted
            mstore8(p, 0xff)
            mstore(add(p, 0x01), shl(96, deployer))
            mstore(add(p, 0x15), salt)
            mstore(add(p, 0x35), initHash)
            a := and(keccak256(p, 0x55), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }
}
