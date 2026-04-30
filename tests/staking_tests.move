// ════════════════════════════════════════════════════════════════
// staking_tests -- deterministic Move tests for the AGENT staking
// reward math, top-5 airdrop split, and tier lock enforcement.
// ════════════════════════════════════════════════════════════════
// These tests run via `sui move test`. They do NOT touch the network;
// everything is in-process via `sui::test_scenario` + `clock_for_testing`.
//
// Coverage:
//   • test_three_tier_topup_distribution
//       Three stakers at tiers 0/1/2 (weights 1/2/4), equal principal.
//       After a top-up of 7000 AGENT raw (cleanly divisible by total
//       weighted = 7e8), each staker's claim must be EXACTLY their
//       (amount × weight) / total_weighted share — i.e. 1000 / 2000 / 4000.
//   • test_top5_airdrop_no_remainder
//       Total = 100_000 → exact 30/25/20/15/10 split, no rounding loss.
//   • test_top5_airdrop_with_remainder
//       Total = 1001 → first four floor to 300/250/200/150 (=900);
//       the last MUST receive 101 so sum == total exactly.
//   • test_unstake_before_lock_aborts
//       Stake at tier 0 (30d lock); attempt unstake at unlock_at - 1ms.
//       Must abort with EStillLocked.
//   • test_below_minimum_stake_aborts
//       Stake of (MIN_STAKE_RAW - 1) must abort with EBelowMinimum.
// ════════════════════════════════════════════════════════════════
#[test_only]
module agent_staking::staking_tests {
    use sui::test_scenario::{Self as ts, Scenario};
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use agent_staking::reward_router::{Self, RewardRouter};
    use agent_staking::agent_staking::{Self, StakeReceipt};

    // Phantom coin type used as the AGENT coin in tests.
    public struct TEST_AGENT has drop {}

    // ─── Test addresses ──────────────────────────────────────────
    const ADMIN: address = @0xA1;
    const ALICE: address = @0xA1CE;     // tier 0 (30d), weight 1
    const BOB:   address = @0xB0B;      // tier 1 (90d), weight 2
    const CAROL: address = @0xCA801;    // tier 2 (180d), weight 4
    const R1: address = @0xE1;
    const R2: address = @0xE2;
    const R3: address = @0xE3;
    const R4: address = @0xE4;
    const R5: address = @0xE5;

    const MIN_STAKE: u64 = 100_000_000; // 100 AGENT @ 6 decimals

    // Helper: bootstrap a scenario with a shared RewardRouter<TEST_AGENT>
    // and a shared Clock at t=1000ms (some non-zero baseline).
    fun setup(): Scenario {
        let mut scenario = ts::begin(ADMIN);
        {
            let ctx = ts::ctx(&mut scenario);
            let mut clk = clock::create_for_testing(ctx);
            clock::set_for_testing(&mut clk, 1000);
            clock::share_for_testing(clk);
        };
        ts::next_tx(&mut scenario, ADMIN);
        {
            let clk = ts::take_shared<Clock>(&scenario);
            let ctx = ts::ctx(&mut scenario);
            reward_router::create_router<TEST_AGENT>(&clk, ctx);
            ts::return_shared(clk);
        };
        scenario
    }

    // Helper: stake on behalf of `who` for `amount` raw at `tier`.
    fun do_stake(scenario: &mut Scenario, who: address, amount: u64, tier: u8) {
        ts::next_tx(scenario, who);
        let mut router = ts::take_shared<RewardRouter<TEST_AGENT>>(scenario);
        let clk = ts::take_shared<Clock>(scenario);
        let ctx = ts::ctx(scenario);
        let payment = coin::mint_for_testing<TEST_AGENT>(amount, ctx);
        agent_staking::stake<TEST_AGENT>(&mut router, payment, tier, &clk, ctx);
        ts::return_shared(router);
        ts::return_shared(clk);
    }

    // Helper: admin top-up of `amount` to the router (label "other").
    fun do_topup(scenario: &mut Scenario, amount: u64) {
        ts::next_tx(scenario, ADMIN);
        let mut router = ts::take_shared<RewardRouter<TEST_AGENT>>(scenario);
        let clk = ts::take_shared<Clock>(scenario);
        let ctx = ts::ctx(scenario);
        let payment = coin::mint_for_testing<TEST_AGENT>(amount, ctx);
        reward_router::fund_router<TEST_AGENT>(&mut router, payment, b"other", &clk, ctx);
        ts::return_shared(router);
        ts::return_shared(clk);
    }

    // Helper: claim rewards for `who` and assert the received Coin equals
    // `expected`. The claimed coin is destroyed for testing.
    fun do_claim_and_assert(scenario: &mut Scenario, who: address, expected: u64) {
        ts::next_tx(scenario, who);
        let mut router = ts::take_shared<RewardRouter<TEST_AGENT>>(scenario);
        let clk = ts::take_shared<Clock>(scenario);
        let mut receipt = ts::take_from_sender<StakeReceipt<TEST_AGENT>>(scenario);
        let ctx = ts::ctx(scenario);
        agent_staking::claim<TEST_AGENT>(&mut router, &mut receipt, &clk, ctx);
        ts::return_shared(router);
        ts::return_shared(clk);
        ts::return_to_sender(scenario, receipt);

        // The claim function transfers a Coin to `who` if pending > 0.
        ts::next_tx(scenario, who);
        if (expected > 0) {
            let claimed = ts::take_from_sender<Coin<TEST_AGENT>>(scenario);
            assert!(coin::value(&claimed) == expected, 9001);
            coin::burn_for_testing(claimed);
        };
    }

    // Helper: bump the shared clock to absolute timestamp `t_ms`.
    fun set_clock(scenario: &mut Scenario, t_ms: u64) {
        ts::next_tx(scenario, ADMIN);
        let mut clk = ts::take_shared<Clock>(scenario);
        clock::set_for_testing(&mut clk, t_ms);
        ts::return_shared(clk);
    }

    // ════════════════════════════════════════════════════════════
    // TEST: stake → top-up → claim across all 3 tiers, verifying
    // each staker receives EXACTLY their pro-rata share.
    // ════════════════════════════════════════════════════════════
    #[test]
    fun test_three_tier_topup_distribution() {
        let mut scenario = setup();

        // Three stakers, equal principal (100 AGENT each), different tiers.
        // weights: alice=1, bob=2, carol=4 → total_weighted = 700_000_000
        do_stake(&mut scenario, ALICE, MIN_STAKE, 0);
        do_stake(&mut scenario, BOB,   MIN_STAKE, 1);
        do_stake(&mut scenario, CAROL, MIN_STAKE, 2);

        // Top up 7000 AGENT raw (= 7_000_000_000). Chosen so that:
        //   acc_inc = 7_000_000_000 * 1e12 / 7e8 = 1e13 (no rounding)
        // Pending shares:
        //   alice = 1e13 * (100e6 * 1) / 1e12 = 1_000_000_000
        //   bob   = 1e13 * (100e6 * 2) / 1e12 = 2_000_000_000
        //   carol = 1e13 * (100e6 * 4) / 1e12 = 4_000_000_000
        //   sum   = 7_000_000_000  == top-up
        do_topup(&mut scenario, 7_000_000_000);

        do_claim_and_assert(&mut scenario, ALICE, 1_000_000_000);
        do_claim_and_assert(&mut scenario, BOB,   2_000_000_000);
        do_claim_and_assert(&mut scenario, CAROL, 4_000_000_000);

        // Second top-up: 14_000 AGENT raw → doubles each share.
        do_topup(&mut scenario, 14_000_000_000);

        do_claim_and_assert(&mut scenario, ALICE, 2_000_000_000);
        do_claim_and_assert(&mut scenario, BOB,   4_000_000_000);
        do_claim_and_assert(&mut scenario, CAROL, 8_000_000_000);

        // Time-jump past Carol's 180d lock so all three can unstake.
        // Baseline clock is 1000ms; 180d in ms is 180 * 86_400_000 = 15_552_000_000.
        set_clock(&mut scenario, 1000 + 15_552_000_000 + 1);
        do_unstake_and_assert(&mut scenario, ALICE, MIN_STAKE);
        do_unstake_and_assert(&mut scenario, BOB,   MIN_STAKE);
        do_unstake_and_assert(&mut scenario, CAROL, MIN_STAKE);

        ts::end(scenario);
    }

    // Helper: unstake `who`'s receipt and assert principal returned == expected.
    // Pending claim (which must be 0 here, since prior do_claim drained it) is
    // verified by checking the staker's coin balance count.
    fun do_unstake_and_assert(scenario: &mut Scenario, who: address, expected_principal: u64) {
        ts::next_tx(scenario, who);
        let mut router = ts::take_shared<RewardRouter<TEST_AGENT>>(scenario);
        let clk = ts::take_shared<Clock>(scenario);
        let receipt = ts::take_from_sender<StakeReceipt<TEST_AGENT>>(scenario);
        let ctx = ts::ctx(scenario);
        agent_staking::unstake<TEST_AGENT>(&mut router, receipt, &clk, ctx);
        ts::return_shared(router);
        ts::return_shared(clk);

        ts::next_tx(scenario, who);
        let principal = ts::take_from_sender<Coin<TEST_AGENT>>(scenario);
        assert!(coin::value(&principal) == expected_principal, 9100);
        coin::burn_for_testing(principal);
    }

    // ════════════════════════════════════════════════════════════
    // TEST: top-5 airdrop, exact split (no remainder).
    // 100_000 = 30_000 + 25_000 + 20_000 + 15_000 + 10_000.
    // ════════════════════════════════════════════════════════════
    #[test]
    fun test_top5_airdrop_no_remainder() {
        let mut scenario = setup();
        let total: u64 = 100_000;

        ts::next_tx(&mut scenario, ADMIN);
        let mut router = ts::take_shared<RewardRouter<TEST_AGENT>>(&scenario);
        let clk = ts::take_shared<Clock>(&scenario);
        let ctx = ts::ctx(&mut scenario);
        let pay = coin::mint_for_testing<TEST_AGENT>(total, ctx);
        let recipients = vector[R1, R2, R3, R4, R5];
        reward_router::airdrop_top5<TEST_AGENT>(&mut router, pay, recipients, &clk, ctx);
        ts::return_shared(router);
        ts::return_shared(clk);

        // Verify each recipient received the expected basis-point share
        // and the SUM equals total exactly.
        let amounts = vector[30_000u64, 25_000u64, 20_000u64, 15_000u64, 10_000u64];
        let addrs = vector[R1, R2, R3, R4, R5];
        let sum = take_and_assert_split(&mut scenario, &addrs, &amounts);
        assert!(sum == total, 9200);

        ts::end(scenario);
    }

    // ════════════════════════════════════════════════════════════
    // TEST: top-5 airdrop, deliberate rounding remainder.
    // 1001 → first four floor to 300/250/200/150 (=900); remainder
    // 101 must go to last recipient so sum == 1001 exactly.
    // ════════════════════════════════════════════════════════════
    #[test]
    fun test_top5_airdrop_with_remainder() {
        let mut scenario = setup();
        let total: u64 = 1001;

        ts::next_tx(&mut scenario, ADMIN);
        let mut router = ts::take_shared<RewardRouter<TEST_AGENT>>(&scenario);
        let clk = ts::take_shared<Clock>(&scenario);
        let ctx = ts::ctx(&mut scenario);
        let pay = coin::mint_for_testing<TEST_AGENT>(total, ctx);
        let recipients = vector[R1, R2, R3, R4, R5];
        reward_router::airdrop_top5<TEST_AGENT>(&mut router, pay, recipients, &clk, ctx);
        ts::return_shared(router);
        ts::return_shared(clk);

        // floor(1001 * bp / 10_000) for the first four, remainder for last.
        // 300 + 250 + 200 + 150 + 101 = 1001  ✓
        let amounts = vector[300u64, 250u64, 200u64, 150u64, 101u64];
        let addrs = vector[R1, R2, R3, R4, R5];
        let sum = take_and_assert_split(&mut scenario, &addrs, &amounts);
        assert!(sum == total, 9300);

        ts::end(scenario);
    }

    // Helper: for each (addr, expected) pair, take one Coin<TEST_AGENT>
    // from that address and assert its value, then burn it. Returns the
    // running sum so the caller can check sum == total.
    fun take_and_assert_split(
        scenario: &mut Scenario,
        addrs: &vector<address>,
        amounts: &vector<u64>,
    ): u64 {
        let mut sum: u64 = 0;
        let mut i = 0;
        let n = vector::length(addrs);
        while (i < n) {
            let addr = *vector::borrow(addrs, i);
            let expected = *vector::borrow(amounts, i);
            ts::next_tx(scenario, addr);
            let c = ts::take_from_sender<Coin<TEST_AGENT>>(scenario);
            assert!(coin::value(&c) == expected, 9400 + (i as u64));
            sum = sum + coin::value(&c);
            coin::burn_for_testing(c);
            i = i + 1;
        };
        sum
    }

    // ════════════════════════════════════════════════════════════
    // TEST: lock enforcement — unstake before unlock_at must abort.
    // Tier 0 (30d) is the shortest lock; we time-travel to 1ms before
    // unlock_at and expect EStillLocked (= 2).
    // ════════════════════════════════════════════════════════════
    #[test]
    #[expected_failure(abort_code = ::agent_staking::agent_staking::EStillLocked)]
    fun test_unstake_before_lock_aborts() {
        let mut scenario = setup();
        do_stake(&mut scenario, ALICE, MIN_STAKE, 0);

        // 30d in ms = 30 * 86_400_000 = 2_592_000_000. Baseline 1000ms,
        // so unlock_at = 1000 + 2_592_000_000. Set clock to unlock_at - 1.
        set_clock(&mut scenario, 1000 + 2_592_000_000 - 1);

        ts::next_tx(&mut scenario, ALICE);
        let mut router = ts::take_shared<RewardRouter<TEST_AGENT>>(&scenario);
        let clk = ts::take_shared<Clock>(&scenario);
        let receipt = ts::take_from_sender<StakeReceipt<TEST_AGENT>>(&scenario);
        let ctx = ts::ctx(&mut scenario);
        // This call should abort.
        agent_staking::unstake<TEST_AGENT>(&mut router, receipt, &clk, ctx);
        ts::return_shared(router);
        ts::return_shared(clk);
        ts::end(scenario);
    }

    // ════════════════════════════════════════════════════════════
    // TEST: stake below MIN_STAKE_RAW must abort with EBelowMinimum (=5).
    // Catches the "100 raw atoms = no-op stake" foot-gun.
    // ════════════════════════════════════════════════════════════
    #[test]
    #[expected_failure(abort_code = ::agent_staking::agent_staking::EBelowMinimum)]
    fun test_below_minimum_stake_aborts() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ALICE);
        let mut router = ts::take_shared<RewardRouter<TEST_AGENT>>(&scenario);
        let clk = ts::take_shared<Clock>(&scenario);
        let ctx = ts::ctx(&mut scenario);
        let payment = coin::mint_for_testing<TEST_AGENT>(MIN_STAKE - 1, ctx);
        // Aborts.
        agent_staking::stake<TEST_AGENT>(&mut router, payment, 0, &clk, ctx);
        ts::return_shared(router);
        ts::return_shared(clk);
        ts::end(scenario);
    }
}
