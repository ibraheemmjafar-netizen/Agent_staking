// ════════════════════════════════════════════════════════════════
// agent_staking -- user-facing stake/unstake/claim
// ════════════════════════════════════════════════════════════════
// Each stake produces an OWNED StakeReceipt object that lives in the
// staker's wallet (NOT inside the shared RewardRouter). The receipt:
//   - holds the principal AGENT in escrow as a Balance<T>
//   - records the lock window (staked_at_ms, unlock_at_ms)
//   - records the tier weight (1, 2, or 4) for reward math
//   - snapshots the global accumulator at stake/claim time so claims
//     can compute pending = (acc - claimed_acc) * weight / ACC_SCALE
//
// Tier table (locked by spec):
//   tier 0 = 30d  -> weight 1, target APR ~12%
//   tier 1 = 90d  -> weight 2, target APR ~25%
//   tier 2 = 180d -> weight 4, target APR ~50%
//
// IMPORTANT: APR targets are NOT enforced on-chain. Real yield is whatever
// the dev-funded top-ups + creator-pool 2% slices produce, distributed
// pro-rata by weight. Frontend shows trailing-30d-actual + a "target band"
// derived from the top-up rate.
//
// LEADERBOARD bonus (spec): the "leaderboard rank" used by airdrop_top5 is
//   raw_AGENT * tier_bonus,  where tier_bonus = {30d:1.000, 90d:1.025, 180d:1.050}
// This is an OFF-CHAIN ranking computed by the backend from emitted Stake
// events. The on-chain weight (1/2/4) drives reward distribution; the
// off-chain tier_bonus drives airdrop ranking. Two different scales by
// design — heavy 180d stakers get most of the daily drip but the
// airdrop ranking is ALMOST raw-amount so a few whales don't dominate.
// ════════════════════════════════════════════════════════════════
#[allow(duplicate_alias, unused_use, lint(public_entry))]
module agent_staking::agent_staking {
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::event;
    use sui::clock::{Self, Clock};
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use agent_staking::reward_router::{Self, RewardRouter};

    // ─── ERROR CODES ─────────────────────────────────────────────
    const EInvalidTier:  u64 = 1;
    const EStillLocked:  u64 = 2;
    const EWrongRouter:  u64 = 3;
    const EZeroAmount:   u64 = 4;
    const EBelowMinimum: u64 = 5;

    // ─── CONSTANTS ───────────────────────────────────────────────
    const TIER_30D:  u8 = 0;
    const TIER_90D:  u8 = 1;
    const TIER_180D: u8 = 2;

    const DAY_MS: u64 = 86_400_000;

    // Minimum stake = 100 AGENT (raw = 100 * 10^6). Stops dust spam.
    const MIN_STAKE_RAW: u64 = 100_000_000;

    // ─── OWNED OBJECT ────────────────────────────────────────────
    // SOULBOUND: `key` only, no `store`. The receipt cannot be wrapped or
    // transferred via public_transfer — the off-chain leaderboard indexer
    // assumes the original staker remains the owner. To exit, the staker
    // must call `unstake` (which deletes the receipt and returns
    // principal + final claim).
    public struct StakeReceipt<phantom T> has key {
        id: UID,
        router_id: ID,             // bind to a specific RewardRouter
        owner: address,            // recorded for read-API convenience
        amount_raw: u64,           // staked principal (raw atoms)
        tier: u8,                  // 0/1/2
        weight: u64,               // 1/2/4 (cached for math)
        weighted: u128,            // amount_raw * weight, cached for pending math
        staked_at_ms: u64,
        unlock_at_ms: u64,
        claimed_acc: u128,         // last-seen acc when claim happened
        principal: Balance<T>,     // locked principal escrowed here
    }

    // ─── EVENTS ──────────────────────────────────────────────────
    public struct Staked has copy, drop {
        receipt_id: address,
        router_id: address,
        staker: address,
        amount_raw: u64,
        tier: u8,
        weight: u64,
        unlock_at_ms: u64,
        timestamp_ms: u64,
    }

    public struct Unstaked has copy, drop {
        receipt_id: address,
        router_id: address,
        staker: address,
        amount_raw: u64,
        final_claim: u64,
        timestamp_ms: u64,
    }

    public struct Claimed has copy, drop {
        receipt_id: address,
        router_id: address,
        staker: address,
        amount: u64,
        new_claimed_acc: u128,
        timestamp_ms: u64,
    }

    // ─── USER: STAKE ─────────────────────────────────────────────
    public entry fun stake<T>(
        router: &mut RewardRouter<T>,
        payment: Coin<T>,
        tier: u8,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(tier <= TIER_180D, EInvalidTier);
        let amount = coin::value(&payment);
        assert!(amount > 0, EZeroAmount);
        assert!(amount >= MIN_STAKE_RAW, EBelowMinimum);

        let weight = tier_weight_for(tier);
        let lock_ms = tier_lock_ms_for(tier);
        let now = clock::timestamp_ms(clock);
        let unlock_at = now + lock_ms;

        // Register with router; receive the snapshot accumulator.
        let initial_acc = reward_router::add_stake(router, amount, weight, clock, ctx);

        let staker = tx_context::sender(ctx);
        let router_addr = object::id_address(router);

        let receipt = StakeReceipt<T> {
            id: object::new(ctx),
            router_id: object::id(router),
            owner: staker,
            amount_raw: amount,
            tier,
            weight,
            weighted: (amount as u128) * (weight as u128),
            staked_at_ms: now,
            unlock_at_ms: unlock_at,
            claimed_acc: initial_acc,
            principal: coin::into_balance(payment),
        };

        let receipt_addr = object::uid_to_address(&receipt.id);

        event::emit(Staked {
            receipt_id: receipt_addr,
            router_id: router_addr,
            staker,
            amount_raw: amount,
            tier,
            weight,
            unlock_at_ms: unlock_at,
            timestamp_ms: now,
        });

        // Soulbound: use `transfer::transfer` (only this module can call it
        // on a non-`store` object). Receipt is permanently bound to staker.
        transfer::transfer(receipt, staker);
    }

    // ─── USER: CLAIM (anytime, no lock check) ────────────────────
    public entry fun claim<T>(
        router: &mut RewardRouter<T>,
        receipt: &mut StakeReceipt<T>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(receipt.router_id == object::id(router), EWrongRouter);

        let pending = compute_pending_claim(router, receipt);
        if (pending > 0) {
            let claim_coin = reward_router::withdraw_for_claim(router, pending, clock, ctx);
            transfer::public_transfer(claim_coin, tx_context::sender(ctx));
        };
        let new_acc = reward_router::acc_per_weight(router);
        receipt.claimed_acc = new_acc;

        event::emit(Claimed {
            receipt_id: object::uid_to_address(&receipt.id),
            router_id: object::id_address(router),
            staker: tx_context::sender(ctx),
            amount: pending,
            new_claimed_acc: new_acc,
            timestamp_ms: clock::timestamp_ms(clock),
        });
    }

    // ─── USER: UNSTAKE (after lock expires) ──────────────────────
    // Consumes the receipt: returns principal + any unclaimed reward
    // to the staker, then deletes the receipt UID.
    public entry fun unstake<T>(
        router: &mut RewardRouter<T>,
        receipt: StakeReceipt<T>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let now = clock::timestamp_ms(clock);
        assert!(receipt.unlock_at_ms <= now, EStillLocked);
        assert!(receipt.router_id == object::id(router), EWrongRouter);

        // Compute pending reward BEFORE we destructure the receipt.
        let pending = compute_pending_claim(router, &receipt);

        let staker = tx_context::sender(ctx);
        let receipt_addr = object::uid_to_address(&receipt.id);
        let router_addr = object::id_address(router);

        // Destructure -- moves principal Balance out so we can return it.
        let StakeReceipt {
            id, router_id: _, owner: _, amount_raw, tier: _, weight,
            weighted: _, staked_at_ms: _, unlock_at_ms: _, claimed_acc: _, principal,
        } = receipt;

        // Pay final claim, if any.
        if (pending > 0) {
            let claim_coin = reward_router::withdraw_for_claim(router, pending, clock, ctx);
            transfer::public_transfer(claim_coin, staker);
        };

        // Unregister stake from router.
        reward_router::remove_stake(router, amount_raw, weight, clock, ctx);

        // Return principal to staker.
        let principal_coin = coin::from_balance(principal, ctx);
        transfer::public_transfer(principal_coin, staker);

        // Delete the receipt object.
        object::delete(id);

        event::emit(Unstaked {
            receipt_id: receipt_addr,
            router_id: router_addr,
            staker,
            amount_raw,
            final_claim: pending,
            timestamp_ms: now,
        });
    }

    // ─── READ APIs ───────────────────────────────────────────────
    public fun amount_raw<T>(r: &StakeReceipt<T>): u64 { r.amount_raw }
    public fun tier<T>(r: &StakeReceipt<T>): u8 { r.tier }
    public fun weight<T>(r: &StakeReceipt<T>): u64 { r.weight }
    public fun staked_at_ms<T>(r: &StakeReceipt<T>): u64 { r.staked_at_ms }
    public fun unlock_at_ms<T>(r: &StakeReceipt<T>): u64 { r.unlock_at_ms }
    public fun claimed_acc<T>(r: &StakeReceipt<T>): u128 { r.claimed_acc }
    public fun owner<T>(r: &StakeReceipt<T>): address { r.owner }
    public fun router_id<T>(r: &StakeReceipt<T>): ID { r.router_id }

    // Compute pending reward without mutating state — useful for off-chain
    // simulators (devInspectTransactionBlock against this entry returns the
    // value as a return arg). NOT entry — call as a regular Move call.
    public fun pending_claim<T>(router: &RewardRouter<T>, receipt: &StakeReceipt<T>): u64 {
        compute_pending_claim(router, receipt)
    }

    public fun min_stake_raw(): u64 { MIN_STAKE_RAW }

    // Tier metadata — backend uses these to render UX without hardcoding.
    public fun tier_30d(): u8 { TIER_30D }
    public fun tier_90d(): u8 { TIER_90D }
    public fun tier_180d(): u8 { TIER_180D }

    // ─── INTERNAL ────────────────────────────────────────────────
    // Router accrual: acc += topup * SCALE / total_weighted, where
    // total_weighted = Σ (amount_i * weight_i). Therefore each receipt's
    // pending reward = (acc - claimed_acc) * (amount * weight) / SCALE.
    // The `weighted` field caches amount_raw * weight at stake time.
    fun compute_pending_claim<T>(router: &RewardRouter<T>, r: &StakeReceipt<T>): u64 {
        let acc = reward_router::acc_per_weight(router);
        if (acc <= r.claimed_acc) return 0;
        let delta = acc - r.claimed_acc;
        let pending = (delta * r.weighted) / reward_router::acc_scale();
        pending as u64
    }

    fun tier_weight_for(tier: u8): u64 {
        if (tier == TIER_30D) { 1 }
        else if (tier == TIER_90D) { 2 }
        else { 4 } // TIER_180D
    }

    fun tier_lock_ms_for(tier: u8): u64 {
        if (tier == TIER_30D) { 30 * DAY_MS }
        else if (tier == TIER_90D) { 90 * DAY_MS }
        else { 180 * DAY_MS } // TIER_180D
    }
}
