// ════════════════════════════════════════════════════════════════
// creator_pool -- per-meme creator-funded reward pools
// ════════════════════════════════════════════════════════════════
// A meme-coin creator can spin up a CreatorPool by depositing AGENT + meme.
// Stakers (anyone) deposit the same meme into the pool to earn a pro-rata
// share of BOTH sides over the pool's lifetime. After the pool ends,
// stakers unstake and recover their meme principal + final rewards.
//
// SPEC RULES (locked):
//   • min AGENT side : 500_000 AGENT       (= 500_000_000_000 raw, 6 decimals)
//   • min MEME  side : max(1_000_000 meme, 3 × AGENT_human) at 6 decimals
//   • min duration   : 24h
//   • 2% AGENT slice -> reward_router (auto-routed at create_pool, label "creator_pool_2pct")
//     [meme side does NOT get skimmed -- AGENT stakers don't accumulate
//      arbitrary memes they didn't sign up for; full meme side stays
//      with meme stakers]
//   • drip model     : linear over duration_ms based on time elapsed × stake share
//   • staker lock    : MUST stay until pool ends (no early exit)
//   • leftover funds : if total_staked_meme=0 during a period, that period's
//                      drip is skipped (creator can sweep at end via creator_close)
//
// MATH (Synthetix-style accumulators per side):
//   On any state-changing call we first run accrue:
//     now = min(clock_ms, ends_at_ms)
//     elapsed = now - last_accrual_ms
//     if elapsed > 0 AND total_staked_meme > 0:
//       agent_drip = total_agent_reward * elapsed / duration_ms
//       meme_drip  = total_meme_reward  * elapsed / duration_ms
//       agent_acc += agent_drip * SCALE / total_staked_meme
//       meme_acc  += meme_drip  * SCALE / total_staked_meme
//     last_accrual_ms = now
//   On claim:
//     pending_a = (agent_acc - r.claimed_agent_acc) * r.staked_meme / SCALE
//     pending_m = (meme_acc  - r.claimed_meme_acc)  * r.staked_meme / SCALE
//     r.claimed_agent_acc = agent_acc
//     r.claimed_meme_acc  = meme_acc
// ════════════════════════════════════════════════════════════════
#[allow(duplicate_alias, lint(public_entry))]
module agent_staking::creator_pool {
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::event;
    use sui::clock::{Self, Clock};
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use agent_staking::reward_router::{Self, RewardRouter};

    // ─── ERROR CODES ─────────────────────────────────────────────
    const EAgentTooLow:        u64 = 1;
    const EMemeTooLow:         u64 = 2;
    const EDurationTooShort:   u64 = 3;
    const EWrongPool:          u64 = 4;
    const EPoolNotEnded:       u64 = 5;
    const EPoolEnded:          u64 = 6;
    const EZeroAmount:         u64 = 7;
    const ENotCreator:         u64 = 8;
    const EStakersStillIn:     u64 = 9;
    const EBelowMinStake:      u64 = 10;

    // ─── CONSTANTS (spec-locked) ─────────────────────────────────
    const MIN_DURATION_MS:    u64 = 86_400_000;            // 24h
    const MIN_AGENT_RAW:      u64 = 500_000_000_000;       // 500k AGENT @ 6 decimals
    const MIN_MEME_RAW_FLOOR: u64 = 1_000_000_000_000;     // 1M meme @ 6 decimals
    const SKIM_BPS:           u64 = 200;                   // 2% in basis points
    const BPS_DENOM:          u64 = 10_000;
    const MIN_POOL_STAKE_RAW: u64 = 1_000_000;             // 1 meme @ 6 decimals (anti-dust)

    // ─── SHARED OBJECT (one per pool) ────────────────────────────
    public struct CreatorPool<phantom A, phantom M> has key {
        id: UID,
        creator: address,
        started_at_ms: u64,
        ends_at_ms: u64,
        duration_ms: u64,

        // Reward sides (post-2%-skim for AGENT; full deposit for meme).
        agent_reward_balance: Balance<A>,
        meme_reward_balance: Balance<M>,
        total_agent_reward: u64,        // initial post-skim AGENT reward (immutable after create)
        total_meme_reward: u64,         // initial meme reward (immutable after create)

        // Stakers' deposited meme (kept separate from reward side).
        staked_meme: Balance<M>,
        total_staked_meme: u64,
        total_stakers: u64,

        // Accumulators (scaled by reward_router::acc_scale()).
        agent_acc: u128,
        meme_acc: u128,
        last_accrual_ms: u64,
    }

    // ─── OWNED OBJECT (one per staker per pool) ──────────────────
    // SOULBOUND: `key` only, no `store`. Cannot be transferred via
    // public_transfer. Staker must call `unstake_pool` (after pool ends)
    // to recover their meme principal + final reward.
    public struct PoolReceipt<phantom A, phantom M> has key {
        id: UID,
        pool_id: ID,
        owner: address,
        staked_meme: u64,
        joined_at_ms: u64,
        claimed_agent_acc: u128,
        claimed_meme_acc: u128,
    }

    // ─── EVENTS ──────────────────────────────────────────────────
    public struct PoolCreated has copy, drop {
        pool_id: address,
        creator: address,
        agent_total_raw: u64,
        agent_skim_raw: u64,
        agent_reward_raw: u64,
        meme_total_raw: u64,
        duration_ms: u64,
        started_at_ms: u64,
        ends_at_ms: u64,
    }

    public struct PoolJoined has copy, drop {
        pool_id: address,
        receipt_id: address,
        staker: address,
        staked_meme: u64,
        timestamp_ms: u64,
    }

    public struct PoolClaimed has copy, drop {
        pool_id: address,
        receipt_id: address,
        staker: address,
        agent_amount: u64,
        meme_amount: u64,
        timestamp_ms: u64,
    }

    public struct PoolUnstaked has copy, drop {
        pool_id: address,
        receipt_id: address,
        staker: address,
        meme_returned: u64,
        final_agent: u64,
        final_meme: u64,
        timestamp_ms: u64,
    }

    public struct PoolClosed has copy, drop {
        pool_id: address,
        creator: address,
        agent_swept: u64,
        meme_swept: u64,
        timestamp_ms: u64,
    }

    // ─── CREATOR: CREATE POOL ────────────────────────────────────
    // duration_ms must be ≥ 24h. AGENT deposit ≥ 500k. Meme deposit ≥
    // max(1M meme, 3 × AGENT_human). 2% of AGENT is auto-routed to the
    // staker reward router with the "creator_pool_2pct" label.
    public entry fun create_pool<A, M>(
        router: &mut RewardRouter<A>,
        mut agent_deposit: Coin<A>,
        meme_deposit: Coin<M>,
        duration_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let agent_raw = coin::value(&agent_deposit);
        let meme_raw = coin::value(&meme_deposit);
        assert!(duration_ms >= MIN_DURATION_MS, EDurationTooShort);
        assert!(agent_raw >= MIN_AGENT_RAW, EAgentTooLow);

        // Meme floor = max(1M, 3 × AGENT). Both at 6 decimals so units match.
        let meme_min_u128 = {
            let three_x = (agent_raw as u128) * 3;
            if (three_x > (MIN_MEME_RAW_FLOOR as u128)) three_x else (MIN_MEME_RAW_FLOOR as u128)
        };
        assert!((meme_raw as u128) >= meme_min_u128, EMemeTooLow);

        // 2% AGENT slice -> reward_router.
        let skim_amount = ((agent_raw as u128) * (SKIM_BPS as u128) / (BPS_DENOM as u128)) as u64;
        let agent_for_pool = agent_raw - skim_amount;
        let skim_coin = coin::split(&mut agent_deposit, skim_amount, ctx);
        reward_router::deposit_external_skim(router, skim_coin, clock, ctx);

        let now = clock::timestamp_ms(clock);
        let ends_at = now + duration_ms;
        let creator = tx_context::sender(ctx);

        let pool = CreatorPool<A, M> {
            id: object::new(ctx),
            creator,
            started_at_ms: now,
            ends_at_ms: ends_at,
            duration_ms,
            agent_reward_balance: coin::into_balance(agent_deposit),
            meme_reward_balance: coin::into_balance(meme_deposit),
            total_agent_reward: agent_for_pool,
            total_meme_reward: meme_raw,
            staked_meme: balance::zero<M>(),
            total_staked_meme: 0,
            total_stakers: 0,
            agent_acc: 0,
            meme_acc: 0,
            last_accrual_ms: now,
        };

        event::emit(PoolCreated {
            pool_id: object::uid_to_address(&pool.id),
            creator,
            agent_total_raw: agent_raw,
            agent_skim_raw: skim_amount,
            agent_reward_raw: agent_for_pool,
            meme_total_raw: meme_raw,
            duration_ms,
            started_at_ms: now,
            ends_at_ms: ends_at,
        });

        transfer::share_object(pool);
    }

    // ─── STAKER: JOIN POOL ───────────────────────────────────────
    // Deposits meme into the pool and mints a PoolReceipt. The staker
    // CANNOT withdraw until the pool ends (enforced in unstake_pool).
    // Calling join after pool end is rejected (no point — no more drip).
    public entry fun join_pool<A, M>(
        pool: &mut CreatorPool<A, M>,
        deposit: Coin<M>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let now = clock::timestamp_ms(clock);
        assert!(now < pool.ends_at_ms, EPoolEnded);
        let amount = coin::value(&deposit);
        assert!(amount > 0, EZeroAmount);
        assert!(amount >= MIN_POOL_STAKE_RAW, EBelowMinStake);

        // Accrue first so the new joiner snapshots the up-to-date acc and
        // doesn't claim drip from before they joined.
        accrue(pool, clock);

        balance::join(&mut pool.staked_meme, coin::into_balance(deposit));
        pool.total_staked_meme = pool.total_staked_meme + amount;
        pool.total_stakers = pool.total_stakers + 1;

        let staker = tx_context::sender(ctx);
        let receipt = PoolReceipt<A, M> {
            id: object::new(ctx),
            pool_id: object::id(pool),
            owner: staker,
            staked_meme: amount,
            joined_at_ms: now,
            claimed_agent_acc: pool.agent_acc,
            claimed_meme_acc: pool.meme_acc,
        };

        event::emit(PoolJoined {
            pool_id: object::uid_to_address(&pool.id),
            receipt_id: object::uid_to_address(&receipt.id),
            staker,
            staked_meme: amount,
            timestamp_ms: now,
        });

        // Soulbound: this module can call `transfer::transfer` because the
        // PoolReceipt is `key`-only. End-users cannot transfer the receipt.
        transfer::transfer(receipt, staker);
    }

    // ─── STAKER: CLAIM (anytime, no lock check) ──────────────────
    public entry fun claim_pool<A, M>(
        pool: &mut CreatorPool<A, M>,
        receipt: &mut PoolReceipt<A, M>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(receipt.pool_id == object::id(pool), EWrongPool);
        accrue(pool, clock);

        let (pending_a, pending_m) = compute_pending(pool, receipt);
        let staker = tx_context::sender(ctx);

        if (pending_a > 0) {
            let coin_a = coin::take(&mut pool.agent_reward_balance, pending_a, ctx);
            transfer::public_transfer(coin_a, staker);
        };
        if (pending_m > 0) {
            let coin_m = coin::take(&mut pool.meme_reward_balance, pending_m, ctx);
            transfer::public_transfer(coin_m, staker);
        };

        receipt.claimed_agent_acc = pool.agent_acc;
        receipt.claimed_meme_acc = pool.meme_acc;

        event::emit(PoolClaimed {
            pool_id: object::uid_to_address(&pool.id),
            receipt_id: object::uid_to_address(&receipt.id),
            staker,
            agent_amount: pending_a,
            meme_amount: pending_m,
            timestamp_ms: clock::timestamp_ms(clock),
        });
    }

    // ─── STAKER: UNSTAKE (after pool ends) ───────────────────────
    // Returns staked meme + final claim, then deletes receipt.
    public entry fun unstake_pool<A, M>(
        pool: &mut CreatorPool<A, M>,
        receipt: PoolReceipt<A, M>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let now = clock::timestamp_ms(clock);
        assert!(now >= pool.ends_at_ms, EPoolNotEnded);
        assert!(receipt.pool_id == object::id(pool), EWrongPool);

        accrue(pool, clock);
        let (pending_a, pending_m) = compute_pending(pool, &receipt);

        let staker = tx_context::sender(ctx);
        let receipt_addr = object::uid_to_address(&receipt.id);

        let PoolReceipt {
            id, pool_id: _, owner: _, staked_meme,
            joined_at_ms: _, claimed_agent_acc: _, claimed_meme_acc: _,
        } = receipt;

        if (pending_a > 0) {
            let coin_a = coin::take(&mut pool.agent_reward_balance, pending_a, ctx);
            transfer::public_transfer(coin_a, staker);
        };
        if (pending_m > 0) {
            let coin_m = coin::take(&mut pool.meme_reward_balance, pending_m, ctx);
            transfer::public_transfer(coin_m, staker);
        };

        // Return principal meme.
        let principal_b = balance::split(&mut pool.staked_meme, staked_meme);
        let principal_coin = coin::from_balance(principal_b, ctx);
        transfer::public_transfer(principal_coin, staker);

        if (pool.total_staked_meme >= staked_meme) {
            pool.total_staked_meme = pool.total_staked_meme - staked_meme;
        } else {
            pool.total_staked_meme = 0;
        };
        if (pool.total_stakers > 0) {
            pool.total_stakers = pool.total_stakers - 1;
        };

        object::delete(id);

        event::emit(PoolUnstaked {
            pool_id: object::uid_to_address(&pool.id),
            receipt_id: receipt_addr,
            staker,
            meme_returned: staked_meme,
            final_agent: pending_a,
            final_meme: pending_m,
            timestamp_ms: now,
        });
    }

    // ─── CREATOR: SWEEP RESIDUAL (after pool end + all stakers out) ───
    // If a pool ran with periods of zero stake, the corresponding drip
    // never accrued and remains in the reward balances. Creator can
    // reclaim ONLY after pool ends AND every staker has unstaked.
    // (Receipts are owned objects; we can't iterate them on-chain, so
    // we use total_stakers==0 as the safety check.)
    public entry fun creator_close<A, M>(
        pool: &mut CreatorPool<A, M>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let sender = tx_context::sender(ctx);
        assert!(sender == pool.creator, ENotCreator);
        let now = clock::timestamp_ms(clock);
        assert!(now >= pool.ends_at_ms, EPoolNotEnded);
        assert!(pool.total_stakers == 0, EStakersStillIn);

        // Sweep both reward balances.
        let agent_left = balance::value(&pool.agent_reward_balance);
        let meme_left = balance::value(&pool.meme_reward_balance);

        if (agent_left > 0) {
            let coin_a = coin::take(&mut pool.agent_reward_balance, agent_left, ctx);
            transfer::public_transfer(coin_a, sender);
        };
        if (meme_left > 0) {
            let coin_m = coin::take(&mut pool.meme_reward_balance, meme_left, ctx);
            transfer::public_transfer(coin_m, sender);
        };

        event::emit(PoolClosed {
            pool_id: object::uid_to_address(&pool.id),
            creator: sender,
            agent_swept: agent_left,
            meme_swept: meme_left,
            timestamp_ms: now,
        });
    }

    // ─── READ APIs ───────────────────────────────────────────────
    public fun creator<A, M>(p: &CreatorPool<A, M>): address { p.creator }
    public fun started_at_ms<A, M>(p: &CreatorPool<A, M>): u64 { p.started_at_ms }
    public fun ends_at_ms<A, M>(p: &CreatorPool<A, M>): u64 { p.ends_at_ms }
    public fun duration_ms<A, M>(p: &CreatorPool<A, M>): u64 { p.duration_ms }
    public fun total_agent_reward<A, M>(p: &CreatorPool<A, M>): u64 { p.total_agent_reward }
    public fun total_meme_reward<A, M>(p: &CreatorPool<A, M>): u64 { p.total_meme_reward }
    public fun agent_reward_left<A, M>(p: &CreatorPool<A, M>): u64 { balance::value(&p.agent_reward_balance) }
    public fun meme_reward_left<A, M>(p: &CreatorPool<A, M>): u64 { balance::value(&p.meme_reward_balance) }
    public fun total_staked_meme<A, M>(p: &CreatorPool<A, M>): u64 { p.total_staked_meme }
    public fun total_stakers<A, M>(p: &CreatorPool<A, M>): u64 { p.total_stakers }
    public fun agent_acc<A, M>(p: &CreatorPool<A, M>): u128 { p.agent_acc }
    public fun meme_acc<A, M>(p: &CreatorPool<A, M>): u128 { p.meme_acc }
    public fun last_accrual_ms<A, M>(p: &CreatorPool<A, M>): u64 { p.last_accrual_ms }

    public fun receipt_pool_id<A, M>(r: &PoolReceipt<A, M>): ID { r.pool_id }
    public fun receipt_staked_meme<A, M>(r: &PoolReceipt<A, M>): u64 { r.staked_meme }
    public fun receipt_owner<A, M>(r: &PoolReceipt<A, M>): address { r.owner }
    public fun receipt_joined_at_ms<A, M>(r: &PoolReceipt<A, M>): u64 { r.joined_at_ms }

    // Off-chain simulator helper (call via devInspectTransactionBlock).
    public fun pending_for<A, M>(
        pool: &CreatorPool<A, M>,
        receipt: &PoolReceipt<A, M>,
    ): (u64, u64) {
        compute_pending(pool, receipt)
    }

    public fun min_agent_raw(): u64 { MIN_AGENT_RAW }
    public fun min_meme_raw_floor(): u64 { MIN_MEME_RAW_FLOOR }
    public fun min_duration_ms(): u64 { MIN_DURATION_MS }
    public fun skim_bps(): u64 { SKIM_BPS }
    public fun min_pool_stake_raw(): u64 { MIN_POOL_STAKE_RAW }

    // ─── INTERNAL ────────────────────────────────────────────────
    // Bring accumulators forward to NOW (capped at ends_at_ms). Drip is
    // skipped during periods with no stakers — that AGENT/meme stays in
    // the balance and is sweepable by creator_close.
    fun accrue<A, M>(pool: &mut CreatorPool<A, M>, clock: &Clock) {
        let raw_now = clock::timestamp_ms(clock);
        let now = if (raw_now > pool.ends_at_ms) pool.ends_at_ms else raw_now;
        if (now <= pool.last_accrual_ms) return;
        let elapsed = now - pool.last_accrual_ms;
        if (pool.total_staked_meme > 0 && pool.duration_ms > 0) {
            let scale = reward_router::acc_scale();
            let ts_meme = pool.total_staked_meme as u128;
            let dur = pool.duration_ms as u128;

            let agent_drip = ((pool.total_agent_reward as u128) * (elapsed as u128)) / dur;
            let meme_drip  = ((pool.total_meme_reward  as u128) * (elapsed as u128)) / dur;

            if (agent_drip > 0) {
                pool.agent_acc = pool.agent_acc + (agent_drip * scale / ts_meme);
            };
            if (meme_drip > 0) {
                pool.meme_acc = pool.meme_acc + (meme_drip * scale / ts_meme);
            };
        };
        pool.last_accrual_ms = now;
    }

    fun compute_pending<A, M>(pool: &CreatorPool<A, M>, r: &PoolReceipt<A, M>): (u64, u64) {
        let scale = reward_router::acc_scale();
        let staked = r.staked_meme as u128;

        let pa = if (pool.agent_acc > r.claimed_agent_acc) {
            ((pool.agent_acc - r.claimed_agent_acc) * staked / scale) as u64
        } else { 0 };

        let pm = if (pool.meme_acc > r.claimed_meme_acc) {
            ((pool.meme_acc - r.claimed_meme_acc) * staked / scale) as u64
        } else { 0 };

        (pa, pm)
    }
}
