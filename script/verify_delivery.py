#!/usr/bin/env python3
"""After the IMD swarm deploys: is what's on chain exactly the delivered source? Run it inside the swarm's delivered
checkout (built: `forge build`), with the launch address the swarm deployed.

    ROBINHOOD_RPC_URL=... python3 script/verify_delivery.py 0x<launch>

Checks, each against this checkout's build (out/): the launch's and its pool's runtime code (and the hook's, once
createHook ran), byte for byte but for their immutables; that the pool's ENGINE_CODE_HASH / VAULT_CODE_HASH are this
build's perps (so `launch.sh perps` from this checkout is accepted); that launch() still refuses a non-0x6900 coin.
"""
import json, os, subprocess, sys

RPC = os.environ.get("ROBINHOOD_RPC_URL") or os.environ.get("RPC") or "https://rpc.mainnet.chain.robinhood.com"
ZERO = "0x" + "0" * 40


def cast(*a):
    """cast, never echoing the RPC URL (it carries a key) on failure: None when the call fails"""
    env = {**os.environ, "FOUNDRY_DISABLE_NIGHTLY_WARNING": "1"}
    r = subprocess.run(["cast", *a, "--rpc-url", RPC], text=True, env=env, capture_output=True)
    return r.stdout.split()[0] if r.returncode == 0 and r.stdout.strip() else None


def artifact(name):
    return json.load(open(f"out/{name}.sol/{name}.json"))


def same_code(name, address):
    a = artifact(name)
    built = bytes.fromhex(a["deployedBytecode"]["object"][2:])
    chain = bytes.fromhex(cast("code", address)[2:])
    mask = bytearray(len(built))
    for refs in (a["deployedBytecode"].get("immutableReferences") or {}).values():
        for r in refs:
            mask[r["start"]:r["start"] + r["length"]] = b"\x01" * r["length"]
    ok = len(built) == len(chain) and all(mask[i] or built[i] == chain[i] for i in range(len(built)))
    print(f"{'OK ' if ok else 'BAD'} {name:24s} {address}: built {len(built)} B, on chain {len(chain)} B")
    return ok


def main():
    if len(sys.argv) != 2: raise SystemExit(__doc__)
    launch = sys.argv[1]
    pool = cast("call", launch, "pool()(address)")
    hook = cast("call", launch, "hook()(address)")
    good = same_code("IMD6900RobinhoodLaunch", launch) & same_code("IMD6900LockedPool", pool)
    if hook != ZERO: good &= same_code("IMD6900Hook", hook)
    else: print("--  IMD6900Hook not created yet (launch.sh hook)")
    for c, const in (("PerpEngine", "ENGINE_CODE_HASH"), ("PerpVault", "VAULT_CODE_HASH")):
        want = cast("call", pool, f"{const}()(bytes32)")
        if want is None or not os.path.exists(f"out/{c}.sol/{c}.json"):
            good = False
            print(f"BAD {c}: no {const} on the deployed pool, or no {c} in this build (a deployment without the perps)")
            continue
        have = subprocess.run(["cast", "keccak", artifact(c)["bytecode"]["object"]], text=True, capture_output=True).stdout.strip()
        ok = want.lower() == have.lower()
        good &= ok
        print(f"{'OK ' if ok else 'BAD'} {c} code hash: the pool wants {want[:18]}…, this build has {have[:18]}…")
    src = open("src/IMD6900RobinhoodLaunch.sol").read()
    ok = "NotVanity" in src and "VANITY" in src
    good &= ok
    print(f"{'OK ' if ok else 'BAD'} launch() still refuses a coin not at 0x6900")
    print("all good: build the Programmable plan and run `perps` from this checkout" if good else "MISMATCH: don't launch from this checkout")
    sys.exit(0 if good else 1)


if __name__ == "__main__":
    main()
