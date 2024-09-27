module double_or_nothing::game {
    use sui::random::{Self, Random, RandomGenerator};
    use sui::balance::{Self, Balance};
    use sui::coin::{Coin};
    use sui::pay::{keep};
    use sui::package::{Self, Publisher};
    use sui::event::{emit};
    use double_or_nothing::pay_utils::{
        balance_withdraw_all,
        balance_top_up,
        balance_withdraw_all_to_coin,
        balance_withdraw,
        coin_split_percent_to_coin,
        balance_split_percent_to_coin
    };
    use double_or_nothing::random_utils::{weighted_random_choice};


    // ========================= CONSTANTS =========================

    const NULL_ADDRESS: address = @0x0;
    /// 1 AAA
    const INITIAL_MIN_BET_VALUE: u64 = 1_000_000;
    /// 100_000 AAA
    const INITIAL_MAX_BET_VALUE: u64 = 100_000_000_000;
    /// 2%
    const INITIAL_FEE_PERCENTAGE: u64 = 2;
    const INITIAL_BONUS_FREQUENCY: u64 = 25;
    const INITIAL_BONUS_WEIGHTS: vector<u64> = vector[60, 25, 10, 5];
    const INITIAL_BONUS_VALUES: vector<u64> = vector[0, 2, 5, 10];

    /// 10%
    const MAX_FEE_PERCENTAGE: u64 = 10;

    // ========================= ERRORS =========================

    const ENotAuthorized: u64 = 0;
    const EInvalidBetValue: u64 = 1;
    const EInvalidFeePercentage: u64 = 2;
    const EGameBalanceInsufficient: u64 = 3;
    const EInvalidVectorLength: u64 = 4;


    // ========================= STRUCTS =========================

    public struct GAME has drop {}

    public struct Game<phantom T> has key {
        id: UID,
        min_bet_value: u64,
        max_bet_value: u64,
        fee_percentage: u64,
        bonus_frequency: u64,
        bonus_weights: vector<u64>,
        bonus_values: vector<u64>,
        pool: Balance<T>,
        fees: Balance<T>,

        // Stats
        total_plays: u64,
        total_wins: u64,
        total_losses: u64,
        total_volume: u128,
        total_fees: u128,

        total_bonus_plays: u64,
        total_bonus_wins: u64,
        total_bonus_losses: u64,
        total_bonus_volume: u128,
    }

    // ========================= EVENTS =========================

    public struct Created has copy, drop {
        game: ID,
    }

    public struct Played has copy, drop {
        game: ID,
        player: address,
        win: bool,
        bet: u64,
        prize: u64,
    }

    public struct BonusPlayed has copy, drop {
        game: ID,
        player: address,
        bonus: u64,
    }

    // ========================= INITIALIZATION =========================

    fun init(otw: GAME, ctx: &mut TxContext) {
        let publisher = package::claim(otw, ctx);

        transfer::public_transfer(publisher, ctx.sender());
    }

    // ========================= PUBLIC MUTABLE FUNCTIONS =========================

    // ========================= ADMIN FUNCTIONS

    entry fun new<T>(
        cap: &Publisher,
        ctx: &mut TxContext,
    ) {
        assert_admin(cap);

        let game = Game<T> {
            id: object::new(ctx),
            min_bet_value: INITIAL_MIN_BET_VALUE,
            max_bet_value: INITIAL_MAX_BET_VALUE,
            fee_percentage: INITIAL_FEE_PERCENTAGE,
            bonus_frequency: INITIAL_BONUS_FREQUENCY,
            bonus_weights: INITIAL_BONUS_WEIGHTS,
            bonus_values: INITIAL_BONUS_VALUES,
            pool: balance::zero(),
            fees: balance::zero(),
            total_plays: 0,
            total_wins: 0,
            total_losses: 0,
            total_volume: 0,
            total_fees: 0,
            total_bonus_plays: 0,
            total_bonus_wins: 0,
            total_bonus_losses: 0,
            total_bonus_volume: 0,
        };

        let id = object::id(&game);

        transfer::share_object(game);

        emit(Created {
            game: id,
        })
    }

    entry fun set_min_bet_value<T>(
        cap: &Publisher,
        game: &mut Game<T>,
        value: u64,
    ) {
        assert_admin(cap);

        assert!(value < game.max_bet_value, EInvalidBetValue);

        game.min_bet_value = value;
    }

    entry fun set_max_bet_value<T>(
        cap: &Publisher,
        game: &mut Game<T>,
        value: u64,
    ) {
        assert_admin(cap);

        assert!(value > game.min_bet_value, EInvalidBetValue);

        game.max_bet_value = value;
    }

    entry fun set_fee_percentage<T>(
        cap: &Publisher,
        game: &mut Game<T>,
        percentage: u64,
    ) {
        assert_admin(cap);

        assert!(percentage <= MAX_FEE_PERCENTAGE, EInvalidFeePercentage);

        game.fee_percentage = percentage;
    }

    entry fun set_bonus_frequency<T>(
        cap: &Publisher,
        game: &mut Game<T>,
        frequency: u64,
    ) {
        assert_admin(cap);

        game.bonus_frequency = frequency;
    }

    entry fun set_bonus_weights_and_values<T>(
        cap: &Publisher,
        game: &mut Game<T>,
        weights: vector<u64>,
        values: vector<u64>,
    ) {
        assert_admin(cap);

        assert!(weights.length() == values.length(), EInvalidVectorLength);

        game.bonus_weights = weights;
        game.bonus_values = values;
    }

    entry fun withdraw_pool<T>(
        cap: &Publisher,
        game: &mut Game<T>,
        ctx: &mut TxContext,
    ) {
        assert_admin(cap);

        balance_withdraw_all(&mut game.pool, ctx)
    }

    entry fun withdraw_fees<T>(
        cap: &Publisher,
        game: &mut Game<T>,
        ctx: &mut TxContext,
    ) {
        assert_admin(cap);

        balance_withdraw_all(&mut game.fees, ctx)
    }

    entry fun burn_fees<T>(
        cap: &Publisher,
        game: &mut Game<T>,
        ctx: &mut TxContext,
    ) {
        assert_admin(cap);

        let fees = balance_withdraw_all_to_coin(&mut game.fees, ctx);

        transfer::public_transfer(fees, NULL_ADDRESS);
    }

    entry fun top_up_pool<T>(
        game: &mut Game<T>,
        coin: Coin<T>,
    ) {
        balance_top_up(&mut game.pool, coin)
    }


    // ========================= PLAYER FUNCTIONS

    entry fun play<T>(
        game: &mut Game<T>,
        r: &Random,
        mut bet: Coin<T>,
        ctx: &mut TxContext,
    ) {
        assert!(bet.value() >= game.min_bet_value, EInvalidBetValue);
        assert!(bet.value() <= game.max_bet_value, EInvalidBetValue);

        // after split, bet will decrease by fee value
        let fee = coin_split_percent_to_coin(&mut bet, game.fee_percentage, ctx);
        let fee_value = fee.value();
        balance_top_up(&mut game.fees, fee);

        assert!(game.pool.value() >= bet.value(), EGameBalanceInsufficient);
        let bet_value = bet.value();
        let prize_value = bet_value * 2;
        balance_top_up(&mut game.pool, bet);

        let mut rg = random::new_generator(r, ctx);
        let win = rg.generate_bool();

        if (win) {
            balance_withdraw(&mut game.pool, prize_value, ctx)
        };

        game.update_stats(win, bet_value, fee_value);

        if (game.is_bonus_play()) {
            game.bonus_play(&mut rg, ctx)
        };

        emit(Played {
            game: object::id(game),
            player: ctx.sender(),
            win: win,
            bet: bet_value,
            prize: prize_value,
        });
    }

    // ========================= PUBLIC VIEW FUNCTIONS =========================

    // ========================= PRIVATE FUNCTIONS =========================

    fun assert_admin(cap: &Publisher) {
        assert!(cap.from_module<GAME>(), ENotAuthorized);
    }

    fun update_stats<T>(game: &mut Game<T>, win: bool, bet_value: u64, fee_value: u64) {
        game.total_plays = game.total_plays + 1;
        if (win) game.total_wins = game.total_wins + 1 else game.total_losses = game.total_losses + 1;
        game.total_volume = game.total_volume + (bet_value as u128);
        game.total_fees = game.total_fees + (fee_value as u128);
    }

    fun update_bonus_stats<T>(game: &mut Game<T>, bonus_value: u64) {
        game.total_bonus_plays = game.total_bonus_plays + 1;
        if (bonus_value > 0) game.total_bonus_wins = game.total_bonus_wins + 1 else game.total_bonus_losses = game.total_bonus_losses + 1;
        game.total_bonus_volume = game.total_bonus_volume + (bonus_value as u128);
    }

    fun is_bonus_play<T>(game: &Game<T>): bool {
        game.total_plays % game.bonus_frequency == 0
    }

    fun bonus_play<T>(game: &mut Game<T>, rg: &mut RandomGenerator, ctx: &mut TxContext) {
        let bonus_percent = weighted_random_choice(game.bonus_weights, game.bonus_values, rg);

        let bonus_coin = balance_split_percent_to_coin(&mut game.fees, bonus_percent, ctx);

        update_bonus_stats(game, bonus_coin.value());

        keep(bonus_coin, ctx);

        emit(BonusPlayed {
            game: object::id(game),
            player: ctx.sender(),
            bonus: bonus_percent,
        });
    }

    // ========================= TESTS =========================


    #[test_only] use std::debug::print;
    #[test_only] use sui::test_scenario as ts;
    #[test_only] use sui::sui::SUI;
    #[test_only] use sui::coin::{Self};

    #[test_only] const ONE_SUI: u64 = 1_000_000_000;
    #[test_only] const ADMIN: address = @0xA;
    #[test_only] const PLAYER: address = @0xB;


    #[test_only]
    fun test_init(ts: &mut ts::Scenario) {
        init(GAME {}, ts.ctx());

        ts.next_tx(@0x0);
        random::create_for_testing(ts.ctx());
    }

    #[test_only]
    fun test_new(ts: &mut ts::Scenario) {
        let publisher = ts.take_from_sender();
        new<SUI>(
            &publisher,
            ts.ctx()
        );

        let pool_coin = coin::mint_for_testing<SUI>(1000 * ONE_SUI, ts.ctx());

        let sender = ts.sender();
        ts.next_tx(sender);
        let mut game = ts.take_shared<Game<SUI>>();
        top_up_pool(&mut game, pool_coin);

        ts::return_shared(game);
        ts.return_to_sender(publisher);
    }

    #[test]
    fun test_play() {
        let mut ts = ts::begin(ADMIN);
        test_init(&mut ts);

        ts.next_tx(ADMIN);
        test_new(&mut ts);

        ts.next_tx(ADMIN);
        let mut game = ts.take_shared<Game<SUI>>();
        print(&game);

        let r = ts.take_shared<Random>();

        500u16.do!(|_| {
            ts.next_tx(PLAYER);
            let bet = coin::mint_for_testing<SUI>(ONE_SUI, ts.ctx());
            play(&mut game, &r, bet, ts.ctx());
        });

        print(&game);
        ts::return_shared(r);
        ts::return_shared(game);
        ts::end(ts);
    }
}

