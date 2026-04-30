// ════════════════════════════════════════════════════════════════
// reward_router -- central reward distribution engine
// ════════════════════════════════════════════════════════════════
// Shared on-chain object that:
//   1. Holds AGENT rewards waiting to be claimed by stakers
//   2. Tracks the global accumulator (Synthetix-style "acc per share")
//   3. Tracks total weighted stake (sum of amount * tier_weight)
//   4. Accepts admin top-ups with a labeled source (transparency feed)
//   5. Accepts admin top-5 leaderboard airdrops (30/25/20/15/10 split)
//
// Other modules in this package call into the router via public(package)
// helpers to register/unregister stakes and withdraw claims:
//   - agent_staking::stake     -> add_stake(...)
//   - agent_staking::unstake   -> remove_stake(...) + withdraw_for_claim(...)
//   - agent_staking::claim     -> withdraw_for_claim(...)
//   - creator_pool::create_pool -> deposit_external_skim(...)   (the 2% slice)
//
// MATH (Synthetix-style accumulator, scaled by ACC_SCALE=1e12):
//   On top-up of `amount`:
//     if total_weighted > 0:
//       acc += (amount * ACC_SCALE) / total_weighted
//     reward_balance += amount
//   On stake of (amount, weight):
//     pending_claim_for_existing = none (new stake uses CURRENT acc as snapshot)
//     total_weighted += amount * weight
//   On claim (computed in agent_staking::_pending_claim):
//     pending = (acc - claimed_acc) * (amount * weight) / ACC_SCALE
//     claimed_acc = acc
//     transfer pending from reward_balance to staker
// ════════════════════════════════════════════════════════════════
#[allow(duplicate_alias, lint(public_entry), implicit_const_copy, unused_mut_parameter)]
module agent_staking::reward_router {
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::event;
    use sui::clock::{Self, Clock};
    use sui::object::{Self, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use std::vector;

    // ─── ERROR CODES ─────────────────────────────────────────────
    const ENotAdmin:           u64 = 1;
    const EInvalidLabel:       u64 = 2;
    const EInsufficientReward: u64 = 3;
    const ETop5Length:         u64 = 4;
    const EZeroAmount:         u64 = 5;

    // ─── CONSTANTS ───────────────────────────────────────────────
    // ACC_SCALE = 1e12. Picked so that even a 1-wei top-up against a
    // 1-trillion-weighted-stake pool produces a non-zero acc delta of 1.
    // u128 max ~ 3.4e38, so even billions of years of top-ups are safe.
    const ACC_SCALE: u128 = 1_000_000_000_000;

    // Whitelisted source labels for fund_router (transparency feed).
    // Anything else aborts with EInvalidLabel so the feed never has garbage.
    const LABEL_LAUNCH_FEE:      vector<u8> = b"launch_fee";
    const LABEL_BOT_LP:          vector<u8> = b"bot_lp";
    const LABEL_ARENA_FEE:       vector<u8> = b"arena_fee";
    const LABEL_AIRDROP_RESERVE: vector<u8> = b"airdrop_reserve";
    const LABEL_OTHER:           vector<u8> = b"other";
    const LABEL_CREATOR_2PCT:    vector<u8> = b"creator_pool_2pct"; // emitted by creator_pool

    // Top-5 airdrop split (basis points; 10_000 = 100%).
    const SPLIT_BPS_1: u64 = 3000; // rank 1: 30%
    const SPLIT_BPS_2: u64 = 2500; // rank 2: 25%
    const SPLIT_BPS_3: u64 = 2000; // rank 3: 20%
    const SPLIT_BPS_4: u64 = 1500; // rank 4: 15%
    const SPLIT_BPS_5: u64 = 1000; // rank 5: 10%

    // ─── SHARED OBJECT ───────────────────────────────────────────
    public struct RewardRouter<phantom T> has key {
        id: UID,
        admin: address,
        reward_balance: Balance<T>,        // unclaimed rewards
        total_weighted_stake: u128,        // sum of (amount * tier_weight) across all stakes
        acc_reward_per_weight: u128,       // accumulator scaled by ACC_SCALE
        total_stakers_count: u64,
        total_staked_raw: u128,            // sum of raw amounts (display only)
        total_topped_up: u128,             // lifetime top-ups (display only)
        total_airdropped: u128,            // lifetime airdrops (display only)
    }

    // ─── EVENTS ──────────────────────────────────────────────────
    public struct RouterCreated has copy, drop {
        router_id: address,
        admin: address,
        timestamp_ms: u64,
    }

    public struct RouterFunded has copy, drop {
        router_id: address,
        amount: u64,
        source_label: vector<u8>,
        funded_by: address,
        new_acc: u128,
        timestamp_ms: u64,
    }

    public struct Top5Airdropped has copy, drop {
        router_id: address,
        total_amount: u64,
        recipients: vector<address>,
        amounts: vector<u64>,
        funded_by: address,
        timestamp_ms: u64,
    }

    public struct StakeRegistered has copy, drop {
        router_id: address,
        staker: address,
        amount_raw: u64,
        weight: u64,
        weighted_added: u128,
        timestamp_ms: u64,
    }

    public struct StakeUnregistered has copy, drop {
        router_id: address,
        staker: address,
        amount_raw: u64,
        weight: u64,
        timestamp_ms: u64,
    }

    public struct RewardsClaimed has copy, drop {
        router_id: address,
        staker: address,
        amount: u64,
        timestamp_ms: u64,
    }

    // ─── INIT: anyone can create a router; caller becomes admin ──
    // Type T is bound at TX-build time via typeArguments. For AGENT staking,
    // pass typeArguments = ['0x5613...::agent::AGENT'].
    public entry fun create_router<T>(clock: &Clock, ctx: &mut TxContext) {
        let router = RewardRouter<T> {
            id: object::new(ctx),
            admin: tx_context::sender(ctx),
            reward_balance: balance::zero<T>(),
            total_weighted_stake: 0,
            acc_reward_per_weight: 0,
            total_stakers_count: 0,
            total_staked_raw: 0,
            total_topped_up: 0,
            total_airdropped: 0,
        };
        event::emit(RouterCreated {
            router_id: object::uid_to_address(&router.id),
            admin: tx_context::sender(ctx),
            timestamp_ms: clock::timestamp_ms(clock),
        });
        transfer::share_object(router);
    }

    // ─── ADMIN: TOP-UP ───────────────────────────────────────────
    // Adds `payment` to the reward pool with a transparency label.
    // Bumps the global accumulator if there are any stakers; otherwise
    // the reward sits in reward_balance until the first stake is created.
    // (The first-ever staker effectively gets nothing from pre-stake top-ups —
    // those top-ups are claimable only AFTER more stake comes in. This is
    // intentional: prevents a phantom "1-wei first staker" from sniping the
    // entire treasury.)
    public entry fun fund_router<T>(
        router: &mut RewardRouter<T>,
        payment: Coin<T>,
        source_label: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(tx_context::sender(ctx) == router.admin, ENotAdmin);
        assert!(is_valid_label(&source_label), EInvalidLabel);
        let amount = coin::value(&payment);
        assert!(amount > 0, EZeroAmount);

        if (router.total_weighted_stake > 0) {
            let inc = ((amount as u128) * ACC_SCALE) / router.total_weighted_stake;
            router.acc_reward_per_weight = router.acc_reward_per_weight + inc;
        };

        balance::join(&mut router.reward_balance, coin::into_balance(payment));
        router.total_topped_up = router.total_topped_up + (amount as u128);

        event::emit(RouterFunded {
            router_id: object::uid_to_address(&router.id),
            amount,
            source_label,
            funded_by: tx_context::sender(ctx),
            new_acc: router.acc_reward_per_weight,
            timestamp_ms: clock::timestamp_ms(clock),
        });
    }

    // ─── ADMIN: TOP-5 AIRDROP ────────────────────────────────────
    // Splits `payment` into 30/25/20/15/10 and sends to recipients[0..4].
    // Backend pre-computes the leaderboard (by raw_AGENT × tier_bonus where
    // tier_bonus ∈ {1.000, 1.025, 1.050}) and passes the top-5 addresses in
    // descending order. Last recipient gets the remainder so rounding never
    // leaves dust trapped in `payment`.
    public entry fun airdrop_top5<T>(
        router: &mut RewardRouter<T>,
        mut payment: Coin<T>,
        recipients: vector<address>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(tx_context::sender(ctx) == router.admin, ENotAdmin);
        assert!(vector::length(&recipients) == 5, ETop5Length);
        let total = coin::value(&payment);
        assert!(total > 0, EZeroAmount);

        let bps = vector[SPLIT_BPS_1, SPLIT_BPS_2, SPLIT_BPS_3, SPLIT_BPS_4, SPLIT_BPS_5];
        let mut amounts = vector::empty<u64>();
        let mut i = 0;
        while (i < 4) {
            let bp = *vector::borrow(&bps, i);
            let amt: u64 = (((total as u128) * (bp as u128)) / 10_000u128) as u64;
            let recipient = *vector::borrow(&recipients, i);
            let coin_part = coin::split(&mut payment, amt, ctx);
            transfer::public_transfer(coin_part, recipient);
            vector::push_back(&mut amounts, amt);
            i = i + 1;
        };
        // Last recipient: hand them the remainder of `payment` directly so we
        // don't lose 1-2 wei to bps rounding.
        let last = *vector::borrow(&recipients, 4);
        let remainder = coin::value(&payment);
        vector::push_back(&mut amounts, remainder);
        transfer::public_transfer(payment, last);

        router.total_airdropped = router.total_airdropped + (total as u128);

        event::emit(Top5Airdropped {
            router_id: object::uid_to_address(&router.id),
            total_amount: total,
            recipients,
            amounts,
            funded_by: tx_context::sender(ctx),
            timestamp_ms: clock::timestamp_ms(clock),
        });
    }

    // ─── ADMIN: ROTATE ADMIN ─────────────────────────────────────
    public entry fun set_admin<T>(router: &mut RewardRouter<T>, new_admin: address, ctx: &mut TxContext) {
        assert!(tx_context::sender(ctx) == router.admin, ENotAdmin);
        router.admin = new_admin;
    }

    // ════════════════════════════════════════════════════════════
    // PACKAGE-INTERNAL API (called by agent_staking + creator_pool)
    // ════════════════════════════════════════════════════════════
    // These are NOT admin-gated; the calling modules enforce their own
    // logic (e.g. agent_staking holds the user's principal in escrow before
    // calling add_stake, so no one can inflate weight without locking funds).

    // Register a new stake. Returns the current accumulator value so the
    // calling module can snapshot it onto the StakeReceipt — this is what
    // prevents the new staker from claiming pre-existing top-ups.
    public(package) fun add_stake<T>(
        router: &mut RewardRouter<T>,
        amount_raw: u64,
        weight: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): u128 {
        let weighted = (amount_raw as u128) * (weight as u128);
        router.total_weighted_stake = router.total_weighted_stake + weighted;
        router.total_stakers_count = router.total_stakers_count + 1;
        router.total_staked_raw = router.total_staked_raw + (amount_raw as u128);

        event::emit(StakeRegistered {
            router_id: object::uid_to_address(&router.id),
            staker: tx_context::sender(ctx),
            amount_raw,
            weight,
            weighted_added: weighted,
            timestamp_ms: clock::timestamp_ms(clock),
        });

        router.acc_reward_per_weight
    }

    // Unregister a stake at unstake time.
    public(package) fun remove_stake<T>(
        router: &mut RewardRouter<T>,
        amount_raw: u64,
        weight: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let weighted = (amount_raw as u128) * (weight as u128);
        router.total_weighted_stake = if (router.total_weighted_stake >= weighted) {
            router.total_weighted_stake - weighted
        } else { 0 };
        if (router.total_stakers_count > 0) {
            router.total_stakers_count = router.total_stakers_count - 1;
        };
        router.total_staked_raw = if (router.total_staked_raw >= (amount_raw as u128)) {
            router.total_staked_raw - (amount_raw as u128)
        } else { 0 };

        event::emit(StakeUnregistered {
            router_id: object::uid_to_address(&router.id),
            staker: tx_context::sender(ctx),
            amount_raw,
            weight,
            timestamp_ms: clock::timestamp_ms(clock),
        });
    }

    // Withdraw `amount` from reward_balance for a claim. Returns Coin<T>
    // which the caller transfers to the staker.
    public(package) fun withdraw_for_claim<T>(
        router: &mut RewardRouter<T>,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<T> {
        assert!(balance::value(&router.reward_balance) >= amount, EInsufficientReward);
        let coin_out = coin::take(&mut router.reward_balance, amount, ctx);
        event::emit(RewardsClaimed {
            router_id: object::uid_to_address(&router.id),
            staker: tx_context::sender(ctx),
            amount,
            timestamp_ms: clock::timestamp_ms(clock),
        });
        coin_out
    }

    // External top-up path used by creator_pool for the 2% AGENT slice.
    // Same math as fund_router but skips the admin check (creator_pool
    // enforces its own rules at create_pool time).
    public(package) fun deposit_external_skim<T>(
        router: &mut RewardRouter<T>,
        payment: Coin<T>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let amount = coin::value(&payment);
        assert!(amount > 0, EZeroAmount);

        if (router.total_weighted_stake > 0) {
            let inc = ((amount as u128) * ACC_SCALE) / router.total_weighted_stake;
            router.acc_reward_per_weight = router.acc_reward_per_weight + inc;
        };

        balance::join(&mut router.reward_balance, coin::into_balance(payment));
        router.total_topped_up = router.total_topped_up + (amount as u128);

        event::emit(RouterFunded {
            router_id: object::uid_to_address(&router.id),
            amount,
            source_label: LABEL_CREATOR_2PCT,
            funded_by: tx_context::sender(ctx),
            new_acc: router.acc_reward_per_weight,
            timestamp_ms: clock::timestamp_ms(clock),
        });
    }

    // ─── READ APIs ───────────────────────────────────────────────
    public fun admin<T>(r: &RewardRouter<T>): address { r.admin }
    public fun reward_balance_value<T>(r: &RewardRouter<T>): u64 { balance::value(&r.reward_balance) }
    public fun total_weighted_stake<T>(r: &RewardRouter<T>): u128 { r.total_weighted_stake }
    public fun total_staked_raw<T>(r: &RewardRouter<T>): u128 { r.total_staked_raw }
    public fun total_stakers<T>(r: &RewardRouter<T>): u64 { r.total_stakers_count }
    public fun total_topped_up<T>(r: &RewardRouter<T>): u128 { r.total_topped_up }
    public fun total_airdropped<T>(r: &RewardRouter<T>): u128 { r.total_airdropped }
    public fun acc_per_weight<T>(r: &RewardRouter<T>): u128 { r.acc_reward_per_weight }
    public fun acc_scale(): u128 { ACC_SCALE }

    // ─── HELPERS ─────────────────────────────────────────────────
    fun is_valid_label(label: &vector<u8>): bool {
        label == &LABEL_LAUNCH_FEE
            || label == &LABEL_BOT_LP
            || label == &LABEL_ARENA_FEE
            || label == &LABEL_AIRDROP_RESERVE
            || label == &LABEL_OTHER
            || label == &LABEL_CREATOR_2PCT
    }
}
