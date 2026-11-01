"""
Z3 proofs for the CL vault share math (src/cl_vault/cl_vault.cairo).

Model. The vault is a set of components, each holding an amount H of something that shares are
pro-rata claims on:
  * a range: H = liquidity L of one Ekubo position; tokens per liquidity unit at the current price
    are the rational a/b (a >= 0, b > 0). Ekubo rounds token amounts UP when adding liquidity and
    DOWN when removing it (liquidity_delta_to_amount_delta).
  * an idle balance: H = token balance I (rate 1).
Share supply S >= 1000 (dead shares). Every component is treated independently with the same s, so
properties proven per component hold for the whole vault (sums of per-component inequalities).
Properties are proven for ANY s >= 0, so the share-scaling loop in _convert_to_shares needs no model.

Rounding as implemented:
  deposit:  range liquidity  x = mul_div_ceil(L, s, S)   (ceil)       [_user_amounts_for_shares]
            range tokens     ceil(x * a / b)                          [Ekubo, adding liquidity]
            idle tokens      ceil(I * s / S)                          [ceil_div]
  withdraw: range liquidity  w = floor(s * L / S)                     [_convert_to_liquidity]
            range tokens     floor(w * a / b)                         [Ekubo, removing liquidity]
            idle tokens      floor(I * s / S)                         [_withdraw]

Ekubo may mint more liquidity than x for the paid amounts (min_liquidity = x), which only
strengthens P2.

History: with x rounded DOWN (floor) Z3 finds a P2 counterexample (L=1, S=1001, s=2 -> x=0: shares
for no liquidity). The contract now rounds x UP; the floor variant is kept as a negative check.

Run: python formal/share_math.py   (z3-solver 4.13.4). Exit 0 iff every property is PROVEN and the
pre-fix floor variant still yields a counterexample.
"""
import sys
from z3 import Int, Solver, And, Or, Not, Implies, unsat, sat

DEAD = 1000


def floor_div(s, q, num, den):
    """q == floor(num / den) for den > 0"""
    s.add(q * den <= num, num < (q + 1) * den)


def ceil_div(s, q, num, den):
    """q == ceil(num / den) for den > 0"""
    s.add(q * den >= num, (q - 1) * den < num)


def check(name, build, timeout_ms=60000):
    s = Solver()
    s.set("timeout", timeout_ms)
    goal = build(s)
    s.add(Not(goal))
    r = s.check()
    if r == unsat:
        print(f"PROVEN   {name}")
        return True
    if r == sat:
        print(f"COUNTEREXAMPLE {name}: {s.model()}")
    else:
        print(f"UNKNOWN  {name} ({s.reason_unknown()})")
    return False


def expect_counterexample(name, build, timeout_ms=60000):
    s = Solver()
    s.set("timeout", timeout_ms)
    s.add(Not(build(s)))
    if s.check() == sat:
        print(f"CEX OK   {name}: {s.model()}")
        return True
    print(f"MISSING  {name}: expected a counterexample")
    return False


def base(s):
    S, s_, L, a, b = Int("S"), Int("s"), Int("L"), Int("a"), Int("b")
    s.add(S >= DEAD, s_ >= 0, L >= 0, a >= 0, b >= 1)
    return S, s_, L, a, b


# --- range component -------------------------------------------------------------------------

def range_deposit(s, x_rounding):
    S, sh, L, a, b = base(s)
    x = Int("x")  # liquidity the depositor adds
    if x_rounding == "floor":
        floor_div(s, x, L * sh, S)
    else:
        ceil_div(s, x, L * sh, S)
    paid = Int("paid")
    ceil_div(s, paid, x * a, b)
    return S, sh, L, a, b, x, paid


def p1_range(x_rounding):
    def build(s):
        S, sh, L, a, b, x, paid = range_deposit(s, x_rounding)
        # withdraw the same shares at the same price from the post-deposit state
        w, got = Int("w"), Int("got")
        floor_div(s, w, sh * (L + x), S + sh)
        floor_div(s, got, w * a, b)
        return got <= paid
    return build


def p2_range(x_rounding):
    def build(s):
        S, sh, L, a, b, x, paid = range_deposit(s, x_rounding)
        # liquidity per share does not decrease:  (L + x) / (S + s) >= L / S
        return (L + x) * S >= L * (S + sh)
    return build


def p3_range(s):
    S, sh, L, a, b = base(s)
    s.add(sh <= S - DEAD)  # dead shares can never be redeemed
    w = Int("w")
    floor_div(s, w, sh * L, S)
    # remaining liquidity per share does not decrease:  (L - w) / (S - s) >= L / S
    return (L - w) * S >= L * (S - sh)


def p4_range(s):
    # two users + dead shares partition S; their withdrawable liquidity sums to <= L
    S, sh, L, a, b = base(s)
    s2 = Int("s2")
    s.add(s2 >= 0, sh + s2 + DEAD == S)
    w1, w2, wd = Int("w1"), Int("w2"), Int("wd")
    floor_div(s, w1, sh * L, S)
    floor_div(s, w2, s2 * L, S)
    floor_div(s, wd, DEAD * L, S)
    return w1 + w2 + wd <= L


# --- idle component --------------------------------------------------------------------------

def idle_deposit(s):
    S, sh, I = Int("S"), Int("s"), Int("I")
    s.add(S >= DEAD, sh >= 0, I >= 0)
    c = Int("c")
    ceil_div(s, c, I * sh, S)
    return S, sh, I, c


def p1_idle(s):
    S, sh, I, c = idle_deposit(s)
    got = Int("got")
    floor_div(s, got, sh * (I + c), S + sh)
    return got <= c


def p2_idle(s):
    S, sh, I, c = idle_deposit(s)
    return (I + c) * S >= I * (S + sh)


def p3_idle(s):
    S, sh, I = Int("S"), Int("s"), Int("I")
    s.add(S >= DEAD, sh >= 0, sh <= S - DEAD, I >= 0)
    g = Int("g")
    floor_div(s, g, I * sh, S)
    return (I - g) * S >= I * (S - sh)


# --- i129 helpers (src/ekubo.cairo, tick_distance in cl_vault.cairo) -------------------------

from z3 import If, Bool, BoolVal

P = 2**251 + 17 * 2**192 + 1  # Starknet field prime
TWO127 = 2**127


def i129_value(mag, sign):
    # sign with mag 0 is +0
    return If(And(sign, mag != 0), -mag, mag)


def mk_i129(s, n):
    mag, sign = Int(f"{n}_mag"), Bool(f"{n}_sign")
    s.add(mag >= 0, mag < 2**128)
    return mag, sign


def p_tick_distance(s):
    am, asg = mk_i129(s, "a")
    bm, bsg = mk_i129(s, "b")
    # tick_distance as implemented
    same = Or(asg == bsg, am == 0, bm == 0)
    dist = If(same, If(am >= bm, am - bm, bm - am), am + bm)
    va, vb = i129_value(am, asg), i129_value(bm, bsg)
    return dist == If(va >= vb, va - vb, vb - va)


def p_i129_lt(s):
    am, asg = mk_i129(s, "a")
    bm, bsg = mk_i129(s, "b")
    an = And(asg, am != 0)
    bn = And(bsg, bm != 0)
    lt = If(an != bn, an, If(an, am > bm, am < bm))
    return lt == (i129_value(am, asg) < i129_value(bm, bsg))


def p_i129_store_roundtrip(s):
    # pack: felt = sign ? -mag : mag  (mod P), requires mag < 2**127
    # unpack: if felt >= 2**127 (as u256) -> (P - felt, true) else (felt, false); mag 0 -> +0
    m, sg = Int("m"), Bool("sg")
    s.add(m >= 0, m < TWO127)
    felt = If(And(sg, m != 0), P - m, m)  # canonical representative in [0, P)
    um = If(felt >= TWO127, P - felt, felt)
    us = And(felt >= TWO127, um != 0)
    return i129_value(um, us) == i129_value(m, sg)


if __name__ == "__main__":
    results = [
        check("P1 range: deposit->withdraw never profitable", p1_range("ceil")),
        check("P2 range: deposit never dilutes holders", p2_range("ceil")),
        check("P3 range: withdraw never dilutes remaining holders", p3_range),
        check("P4 range: sum of claims <= liquidity", p4_range),
        check("P1 idle: deposit->withdraw never profitable", p1_idle),
        check("P2 idle: deposit never dilutes holders", p2_idle),
        check("P3 idle: withdraw never dilutes remaining holders", p3_idle),
        check("i129 tick_distance == |a - b|", p_tick_distance),
        check("i129 lt matches integer order", p_i129_lt),
        check("i129 StorePacking unpack(pack(x)) == x (|x| < 2^127)", p_i129_store_roundtrip),
        expect_counterexample("pre-fix: range liquidity rounded down dilutes holders", p2_range("floor")),
    ]
    sys.exit(0 if all(results) else 1)
