// ════════════════════════════════════════════════════════════════
// creator_pool_tests -- end-to-end test for the per-meme creator pool.
// ════════════════════════════════════════════════════════════════
// Covers the full lifecycle:
//   1. create_pool — verifies the 2% AGENT skim is auto-routed to the
//      shared RewardRouter and that agent_for_pool == deposit - skim.
//   2. join_pool — two stakers deposit meme during the pool's run.
//   3. claim_pool — mid-run, one staker pulls accumulated drip; math
//      must match the linear-over-duration formula exactly.
//   4. unstake_pool — at pool end, both stakers recover meme principal
//      plus their final reward share.
//   5. creator_close — sweeps the residual that accrued during periods
//      with zero stakers (here: the first 10% of the pool's duration).
//
// Numbers are picked so all divisions are exact (no rounding loss):
//   AGENT deposit = 1_000_000_000_000   (1M @ 6dec)
//   skim (2%)     =    20_000_000_000   → router.reward_balance after create
//   pool reward A =   980_000_000_000
//   MEME deposit  = 3_000_000_000_000   (3M @ 6dec; satisfies 3× AGENT min)
//   duration      = 86_400_000 ms       (24h, the spec minimum)
//   stakers join at t = 10% of duration → first 10% accrues NOTHING
//                                          (no stakers means no drip)
//   half-claim at t = 50%  → 40% of total reward delivered to stakers
//   unstake    at t = 100% → another 50% delivered (90% total to stakers)
//   creator_close residual = 10% of each side (the un-staked window)
// ════════════════════════════════════════════════════════════════
#[test_only]
module agent_staking::creator_pool_tests {
    use sui::test_scenario::{Self as ts};
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use agent_staking::reward_router::{Self, RewardRouter};
    use agent_staking::creator_pool::{Self, CreatorPool, PoolReceipt};

    // Phantom coin types: A = AGENT side, M = meme side.
    public struct TEST_AGENT has drop {}
    public struct TEST_MEME  has drop {}

    const ADMIN:   address = @0xA1;
    const CREATOR: address = @0xC0DE;
    const ALICE:   address = @0xA1CE;
    const BOB:     address = @0xB0B;

    const T0: u64 = 1_000;
    const DUR: u64 = 86_400_000;

    const AGENT_TOTAL: u64 = 1_000_000_000_000;
    const AGENT_SKIM:  u64 = 20_000_000_000;
    const AGENT_POOL:  u64 = 980_000_000_000;
    const MEME_TOTAL:  u64 = 3_000_000_000_000;

    const STAKE_PER_USER: u64 = 1_000_000_000; // 1k meme @ 6dec each

    #[test]
    fun test_creator_pool_full_lifecycle() {
        let mut scenario = ts::begin(ADMIN);

        // ─── Setup: shared Clock + RewardRouter<TEST_AGENT> ────────
        {
            let ctx = ts::ctx(&mut scenario);
            let mut clk = clock::create_for_testing(ctx);
            clock::set_for_testing(&mut clk, T0);
            clock::share_for_testing(clk);
        };
        ts::next_tx(&mut scenario, ADMIN);
        {
            let clk = ts::take_shared<Clock>(&scenario);
            let ctx = ts::ctx(&mut scenario);
            reward_router::create_router<TEST_AGENT>(&clk, ctx);
            ts::return_shared(clk);
        };

        // ─── 1. create_pool: verify 2% skim flows into router ──────
        ts::next_tx(&mut scenario, CREATOR);
        {
            let mut router = ts::take_shared<RewardRouter<TEST_AGENT>>(&scenario);
            let clk = ts::take_shared<Clock>(&scenario);
            let ctx = ts::ctx(&mut scenario);
            let agent_dep = coin::mint_for_testing<TEST_AGENT>(AGENT_TOTAL, ctx);
            let meme_dep  = coin::mint_for_testing<TEST_MEME>(MEME_TOTAL, ctx);
            creator_pool::create_pool<TEST_AGENT, TEST_MEME>(
                &mut router, agent_dep, meme_dep, DUR, &clk, ctx,
            );
            // 2% skim is in the router's reward_balance. No stakers in
            // the router yet (this is a pure creator-pool test), so the
            // accumulator stays 0 but the AGENT is parked safely.
            assert!(reward_router::reward_balance_value<TEST_AGENT>(&router) == AGENT_SKIM, 1);
            assert!(reward_router::total_topped_up<TEST_AGENT>(&router) == (AGENT_SKIM as u128), 2);
            ts::return_shared(router);
            ts::return_shared(clk);
        };

        // Verify the freshly-shared CreatorPool fields look right.
        ts::next_tx(&mut scenario, CREATOR);
        {
            let pool = ts::take_shared<CreatorPool<TEST_AGENT, TEST_MEME>>(&scenario);
            assert!(creator_pool::total_agent_reward<TEST_AGENT, TEST_MEME>(&pool) == AGENT_POOL, 3);
            assert!(creator_pool::total_meme_reward<TEST_AGENT, TEST_MEME>(&pool) == MEME_TOTAL, 4);
            assert!(creator_pool::agent_reward_left<TEST_AGENT, TEST_MEME>(&pool) == AGENT_POOL, 5);
            assert!(creator_pool::meme_reward_left<TEST_AGENT, TEST_MEME>(&pool) == MEME_TOTAL, 6);
            assert!(creator_pool::ends_at_ms<TEST_AGENT, TEST_MEME>(&pool) == T0 + DUR, 7);
            ts::return_shared(pool);
        };

        // ─── 2. Advance to t = 10% of duration; two stakers join ───
        // No stakers existed for the first 10%, so that drip is forfeit
        // (creator can sweep at the end via creator_close).
        let t_join = T0 + DUR / 10;            // 10% in
        bump_clock(&mut scenario, t_join);

        join_pool_for(&mut scenario, ALICE, STAKE_PER_USER);
        join_pool_for(&mut scenario, BOB,   STAKE_PER_USER);

        // ─── 3. Advance to t = 50%; ALICE claims ───────────────────
        let t_half = T0 + DUR / 2;             // 50% in
        bump_clock(&mut scenario, t_half);

        // From t_join (10%) to t_half (50%) = 40% of duration.
        // agent_drip = AGENT_POOL * 40% = 392_000_000_000
        // meme_drip  = MEME_TOTAL * 40% = 1_200_000_000_000
        // Each of the 2 stakers owns 50% of total_staked_meme, so:
        //   alice's claim = drip / 2 → 196_000_000_000 AGENT, 600_000_000_000 meme
        claim_for(
            &mut scenario, ALICE,
            196_000_000_000,  // expected AGENT
            600_000_000_000,  // expected meme
        );

        // ─── 4. Advance to t = end (100%); both stakers unstake ────
        let t_end = T0 + DUR;
        bump_clock(&mut scenario, t_end);

        // From t_half to t_end = 50% of duration. Drip in this window:
        //   agent = 490_000_000_000, meme = 1_500_000_000_000.
        // ALICE already claimed at 50%, so her unstake reward is just
        // the post-50% drip half = 245e9 AGENT, 750e9 meme. Plus principal.
        unstake_for(
            &mut scenario, ALICE,
            STAKE_PER_USER,    // meme principal back
            245_000_000_000,   // final agent claim
            750_000_000_000,   // final meme claim
        );
        // BOB never claimed, so he collects his half of BOTH the 40%
        // window and the 50% window:
        //   agent = 196e9 + 245e9 = 441e9
        //   meme  = 600e9 + 750e9 = 1_350e9
        unstake_for(
            &mut scenario, BOB,
            STAKE_PER_USER,
            441_000_000_000,
            1_350_000_000_000,
        );

        // ─── 5. creator_close: sweep the un-staked first-10% drip ──
        // Distributed during the pool: 882e9 AGENT, 2_700e9 meme.
        // Residual:                     98e9 AGENT,   300e9 meme.
        ts::next_tx(&mut scenario, CREATOR);
        {
            let mut pool = ts::take_shared<CreatorPool<TEST_AGENT, TEST_MEME>>(&scenario);
            let clk = ts::take_shared<Clock>(&scenario);
            let ctx = ts::ctx(&mut scenario);
            assert!(creator_pool::total_stakers<TEST_AGENT, TEST_MEME>(&pool) == 0, 8);
            creator_pool::creator_close<TEST_AGENT, TEST_MEME>(&mut pool, &clk, ctx);
            ts::return_shared(pool);
            ts::return_shared(clk);
        };
        ts::next_tx(&mut scenario, CREATOR);
        {
            let agent_resid = ts::take_from_sender<Coin<TEST_AGENT>>(&scenario);
            let meme_resid  = ts::take_from_sender<Coin<TEST_MEME>>(&scenario);
            assert!(coin::value(&agent_resid) ==  98_000_000_000, 9);
            assert!(coin::value(&meme_resid)  == 300_000_000_000, 10);

            // Conservation: distributed + swept must equal initial reward.
            let dist_agent: u64 = 196_000_000_000 + 245_000_000_000 + 441_000_000_000;
            let dist_meme:  u64 = 600_000_000_000 + 750_000_000_000 + 1_350_000_000_000;
            assert!(dist_agent + coin::value(&agent_resid) == AGENT_POOL, 11);
            assert!(dist_meme  + coin::value(&meme_resid)  == MEME_TOTAL, 12);

            coin::burn_for_testing(agent_resid);
            coin::burn_for_testing(meme_resid);
        };

        ts::end(scenario);
    }

    // ─── helpers ────────────────────────────────────────────────

    fun bump_clock(scenario: &mut ts::Scenario, t_ms: u64) {
        ts::next_tx(scenario, ADMIN);
        let mut clk = ts::take_shared<Clock>(scenario);
        clock::set_for_testing(&mut clk, t_ms);
        ts::return_shared(clk);
    }

    fun join_pool_for(scenario: &mut ts::Scenario, who: address, amount: u64) {
        ts::next_tx(scenario, who);
        let mut pool = ts::take_shared<CreatorPool<TEST_AGENT, TEST_MEME>>(scenario);
        let clk = ts::take_shared<Clock>(scenario);
        let ctx = ts::ctx(scenario);
        let dep = coin::mint_for_testing<TEST_MEME>(amount, ctx);
        creator_pool::join_pool<TEST_AGENT, TEST_MEME>(&mut pool, dep, &clk, ctx);
        ts::return_shared(pool);
        ts::return_shared(clk);
    }

    fun claim_for(
        scenario: &mut ts::Scenario,
        who: address,
        expected_agent: u64,
        expected_meme: u64,
    ) {
        ts::next_tx(scenario, who);
        let mut pool = ts::take_shared<CreatorPool<TEST_AGENT, TEST_MEME>>(scenario);
        let clk = ts::take_shared<Clock>(scenario);
        let mut receipt = ts::take_from_sender<PoolReceipt<TEST_AGENT, TEST_MEME>>(scenario);
        let ctx = ts::ctx(scenario);
        creator_pool::claim_pool<TEST_AGENT, TEST_MEME>(&mut pool, &mut receipt, &clk, ctx);
        ts::return_shared(pool);
        ts::return_shared(clk);
        ts::return_to_sender(scenario, receipt);

        ts::next_tx(scenario, who);
        if (expected_agent > 0) {
            let c = ts::take_from_sender<Coin<TEST_AGENT>>(scenario);
            assert!(coin::value(&c) == expected_agent, 2001);
            coin::burn_for_testing(c);
        };
        if (expected_meme > 0) {
            let c = ts::take_from_sender<Coin<TEST_MEME>>(scenario);
            assert!(coin::value(&c) == expected_meme, 2002);
            coin::burn_for_testing(c);
        };
    }

    fun unstake_for(
        scenario: &mut ts::Scenario,
        who: address,
        expected_principal: u64,
        expected_agent: u64,
        expected_meme: u64,
    ) {
        ts::next_tx(scenario, who);
        let mut pool = ts::take_shared<CreatorPool<TEST_AGENT, TEST_MEME>>(scenario);
        let clk = ts::take_shared<Clock>(scenario);
        let receipt = ts::take_from_sender<PoolReceipt<TEST_AGENT, TEST_MEME>>(scenario);
        let ctx = ts::ctx(scenario);
        creator_pool::unstake_pool<TEST_AGENT, TEST_MEME>(&mut pool, receipt, &clk, ctx);
        ts::return_shared(pool);
        ts::return_shared(clk);

        ts::next_tx(scenario, who);
        // Final reward coins (if any) come first, principal coin last —
        // but order from the inventory isn't strictly guaranteed, so
        // take by type and accumulate values.
        if (expected_agent > 0) {
            let c = ts::take_from_sender<Coin<TEST_AGENT>>(scenario);
            assert!(coin::value(&c) == expected_agent, 3001);
            coin::burn_for_testing(c);
        };
        // Two Coin<TEST_MEME> objects in the inventory: the meme reward
        // and the meme principal. They may be returned in either order
        // by take_from_sender, so consume both and assert their sum
        // equals (reward + principal).
        let m1 = ts::take_from_sender<Coin<TEST_MEME>>(scenario);
        let m2 = ts::take_from_sender<Coin<TEST_MEME>>(scenario);
        let total_meme_back = coin::value(&m1) + coin::value(&m2);
        assert!(total_meme_back == expected_principal + expected_meme, 3002);
        coin::burn_for_testing(m1);
        coin::burn_for_testing(m2);
    }
}
