module double_or_nothing::game {
    use sui::random::{Self, Random, RandomGenerator};
    use sui::balance::{Self, Balance};
    use sui::coin::{Coin};
    use sui::pay::{keep};
    use sui::package::{Self, Publisher};
    use sui::event::{emit};
    use sui::table::{Self, Table};
    use double_or_nothing::pay_utils::{
        balance_withdraw_all,
        balance_top_up,
        balance_withdraw,
        coin_split_percent_to_coin,
        balance_withdraw_to_coin,
        burn_coin,
        balance_withdraw_all_to_coin,
    };
    use double_or_nothing::random_utils::{weighted_random_choice};


    // ========================= CONSTANTS =========================

    /// 1 AAA
    const INITIAL_MIN_BET_VALUE: u64 = 1_000_000;
    /// 100_000 AAA
    const INITIAL_MAX_BET_VALUE: u64 = 100_000_000_000;
    /// 2%
    const INITIAL_FEE_PERCENTAGE: u64 = 2;
    const INITIAL_BURN_FEE_PERCENTAGE: u64 = 50;
    const INITIAL_BONUS_FREQUENCY: u64 = 25;
    const INITIAL_BONUS_WEIGHTS: vector<u64> = vector[20, 25, 25, 10, 10, 10];
    const INITIAL_BONUS_VALUES: vector<u64> = vector[0, 200_000_000, 600_000_000, 1000_000_000, 2000_000_000, 5000_000_000];
    const INITIAL_TOTAL_BONUS_POOL_WIN_CHANCE: u64 = 1000;
    const INITIAL_LAST_PLAYS_SIZE: u64 = 10;

    // ========================= ERRORS =========================

    const ENotAuthorized: u64 = 0;
    const EInvalidBetValue: u64 = 1;
    const EInvalidPercentage: u64 = 2;
    const EGameBalanceInsufficient: u64 = 3;
    const EInvalidVectorLength: u64 = 4;


    // ========================= STRUCTS =========================

    public struct GAME has drop {}

    public struct GameAdmin has key, store {
        id: UID,
        game: ID,
    }

    public struct Stats has copy, drop, store {
        total_plays: u64,
        total_wins: u64,
        total_losses: u64,
        total_volume: u128,
        total_fees: u128,
        total_burned_fees: u128,

        total_bonus_plays: u64,
        total_bonus_wins: u64,
        total_bonus_losses: u64,
        total_bonus_volume: u128,
    }

    public struct Game<phantom T> has key {
        id: UID,

        // Game settings

        /// Min bet value
        min_bet_value: u64,
        /// Max bet value
        max_bet_value: u64,
        /// Fee percentage. Fee is taken from the bet
        fee_percentage: u64,
        /// Burn fee percentage. Percentage of the fee that is burned
        burn_fee_percentage: u64,
        /// Bonus frequency. Every N plays is a bonus play
        bonus_frequency: u64,
        /// Weights for bonus values random choice
        bonus_weights: vector<u64>,
        /// Values for bonus values random choice
        bonus_values: vector<u64>,
        /// There is 1 in total_bonus_pool_win_chance chance to win the whole bonus pool
        total_bonus_pool_win_chance: u64,

        // Balances
        
        /// Main pool. All bets go here. Prizes are paid from here
        pool: Balance<T>,
        /// Bonus pool. Part of the fee goes here. Bonus prizes are paid from here
        bonus_pool: Balance<T>,

        // Stats

        /// General stats
        stats: Stats,
        /// Stats per address
        stats_per_address: Table<address, Stats>,

        // History

        /// Last plays
        last_plays: vector<Play>,
    }

    // ========================= EVENTS =========================

    public struct Created has copy, drop {
        game: ID,
    }

    public struct Play has copy, drop, store {
        game: ID,
        player: address,
        win: bool,
        bet: u64,
        prize: u64,

        // bonus
        is_bonus_play: bool,
        bonus_win: bool,
        bonus_prize: u64,
    }

    // ========================= INITIALIZATION =========================

    fun init(otw: GAME, ctx: &mut TxContext) {
        let publisher = package::claim(otw, ctx);

        transfer::public_transfer(publisher, ctx.sender());
    }

    // ========================= PUBLIC MUTABLE FUNCTIONS =========================

    // ========================= PUBLISHER FUNCTIONS

    entry fun new<T>(
        cap: &Publisher,
        ctx: &mut TxContext,
    ) {
        assert_publisher(cap);

        let game = Game<T> {
            id: object::new(ctx),
            min_bet_value: INITIAL_MIN_BET_VALUE,
            max_bet_value: INITIAL_MAX_BET_VALUE,
            fee_percentage: INITIAL_FEE_PERCENTAGE,
            burn_fee_percentage: INITIAL_BURN_FEE_PERCENTAGE,
            bonus_frequency: INITIAL_BONUS_FREQUENCY,
            bonus_weights: INITIAL_BONUS_WEIGHTS,
            bonus_values: INITIAL_BONUS_VALUES,
            total_bonus_pool_win_chance: INITIAL_TOTAL_BONUS_POOL_WIN_CHANCE,
            pool: balance::zero(),
            bonus_pool: balance::zero(),
            stats: new_stats(),
            stats_per_address: table::new(ctx),
            last_plays: vector[],
        };

        let id = object::id(&game);

        transfer::share_object(game);

        transfer::transfer(GameAdmin {
            id: object::new(ctx),
            game: id,
        }, ctx.sender());

        emit(Created {
            game: id,
        })
    }

    // ========================= ADMIN FUNCTIONS

    entry fun set_min_bet_value<T>(
        cap: &GameAdmin,
        game: &mut Game<T>,
        value: u64,
    ) {
        game.assert_admin(cap);

        assert!(value < game.max_bet_value, EInvalidBetValue);

        game.min_bet_value = value;
    }

    entry fun set_max_bet_value<T>(
        cap: &GameAdmin,
        game: &mut Game<T>,
        value: u64,
    ) {
        game.assert_admin(cap);

        assert!(value > game.min_bet_value, EInvalidBetValue);

        game.max_bet_value = value;
    }

    entry fun set_fee_percentage<T>(
        cap: &GameAdmin,
        game: &mut Game<T>,
        percentage: u64,
    ) {
        game.assert_admin(cap);

        assert!(percentage <= 100, EInvalidPercentage);

        game.fee_percentage = percentage;
    }

    entry fun set_burn_fee_percentage<T>(
        cap: &GameAdmin,
        game: &mut Game<T>,
        percentage: u64,
    ) {
        game.assert_admin(cap);

        assert!(percentage <= 100, EInvalidPercentage);

        game.burn_fee_percentage = percentage;
    }

    entry fun set_bonus_frequency<T>(
        cap: &GameAdmin,
        game: &mut Game<T>,
        frequency: u64,
    ) {
        game.assert_admin(cap);

        game.bonus_frequency = frequency;
    }

    entry fun set_bonus_weights_and_values<T>(
        cap: &GameAdmin,
        game: &mut Game<T>,
        weights: vector<u64>,
        values: vector<u64>,
    ) {
        game.assert_admin(cap);

        assert!(weights.length() == values.length(), EInvalidVectorLength);

        game.bonus_weights = weights;
        game.bonus_values = values;
    }

    entry fun set_total_bonus_pool_win_chance<T>(
        cap: &GameAdmin,
        game: &mut Game<T>,
        chance: u64,
    ) {
        game.assert_admin(cap);

        game.total_bonus_pool_win_chance = chance;
    }

    entry fun withdraw_pool<T>(
        cap: &GameAdmin,
        game: &mut Game<T>,
        ctx: &mut TxContext,
    ) {
        game.assert_admin(cap);

        balance_withdraw_all(&mut game.pool, ctx)
    }

    entry fun withdraw_bonus_pool<T>(
        cap: &GameAdmin,
        game: &mut Game<T>,
        ctx: &mut TxContext,
    ) {
        game.assert_admin(cap);

        balance_withdraw_all(&mut game.bonus_pool, ctx)
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
        let mut fee = coin_split_percent_to_coin(&mut bet, game.fee_percentage, ctx);
        let fee_value = fee.value();

        // burn half of the fee
        let fee_burn = coin_split_percent_to_coin(&mut fee, game.burn_fee_percentage, ctx);
        burn_coin(fee_burn);
        
        balance_top_up(&mut game.bonus_pool, fee);

        assert!(game.pool.value() >= bet.value(), EGameBalanceInsufficient);
        let bet_value = bet.value();
        let prize_value = bet_value * 2;
        balance_top_up(&mut game.pool, bet);

        let mut rg = random::new_generator(r, ctx);
        let win = rg.generate_bool();

        if (win) {
            balance_withdraw(&mut game.pool, prize_value, ctx)
        };

        let (is_bonus_play, bonus_value)= game.bonus_play(&mut rg, ctx);

        game.stats.update_stats(win, bet_value, fee_value, is_bonus_play, bonus_value);
        game.update_address_stats(ctx.sender(), win, bet_value, fee_value, is_bonus_play, bonus_value);

        let play = Play {
            game: object::id(game),
            player: ctx.sender(),
            win,
            bet: bet_value,
            prize: prize_value,
            is_bonus_play,
            bonus_win: bonus_value > 0,
            bonus_prize: bonus_value,
        };

        game.update_last_plays(play);
        
        emit(play);
    }

    // ========================= PUBLIC VIEW FUNCTIONS =========================

    public fun get_address_stats<T>(
        game: &Game<T>,
        address: address,
    ): Stats {
        game.stats_per_address[address]
    }
    
    // ========================= PRIVATE FUNCTIONS =========================

    // ========================= ASSERT

    fun assert_publisher(cap: &Publisher) {
        assert!(cap.from_module<GAME>(), ENotAuthorized);
    }

    fun assert_admin<T>(game: &Game<T>, cap: &GameAdmin) {
        assert!(object::id(game) == cap.game, ENotAuthorized);
    }

    // ========================= STATS

    fun new_stats(): Stats {
        Stats {
            total_plays: 0,
            total_wins: 0,
            total_losses: 0,
            total_volume: 0,
            total_fees: 0,
            total_burned_fees: 0,
            total_bonus_plays: 0,
            total_bonus_wins: 0,
            total_bonus_losses: 0,
            total_bonus_volume: 0
        }
    }

    fun update_stats(
        stats: &mut Stats,
        win: bool, 
        bet_value: u64, 
        fee_value: u64,
        is_bonus_play: bool,
        bonus_value: u64
    ) {
        stats.total_plays = stats.total_plays + 1;
        if (win) stats.total_wins = stats.total_wins + 1 else stats.total_losses = stats.total_losses + 1;
        stats.total_volume = stats.total_volume + (bet_value as u128);
        stats.total_fees = stats.total_fees + (fee_value as u128);
        stats.total_burned_fees = stats.total_burned_fees + (fee_value as u128) / 2;

        if (is_bonus_play) {
            stats.total_bonus_plays = stats.total_bonus_plays + 1;
            if (bonus_value > 0) stats.total_bonus_wins = stats.total_bonus_wins + 1 else stats.total_bonus_losses = stats.total_bonus_losses + 1;
            stats.total_bonus_volume = stats.total_bonus_volume + (bonus_value as u128);
        }
    }

    fun update_address_stats<T>(
        game: &mut Game<T>,
        address: address,
        win: bool, 
        bet_value: u64, 
        fee_value: u64,
        is_bonus_play: bool,
        bonus_value: u64
    ) {
        let stats_per_address =  &mut game.stats_per_address;
        if (!stats_per_address.contains(address)) {
            stats_per_address.add(address, new_stats());
        };

        stats_per_address[address].update_stats(win, bet_value, fee_value, is_bonus_play, bonus_value);
    }

    // ========================= BONUS

    fun is_bonus_play<T>(game: &Game<T>): bool {
        game.stats.total_plays % game.bonus_frequency == 0
    }

    fun bonus_play<T>(game: &mut Game<T>, rg: &mut RandomGenerator, ctx: &mut TxContext): (bool, u64) {
        let is_bonus_play = is_bonus_play(game);
        
        if (!is_bonus_play) {
            return (is_bonus_play, 0)
        };
        

        // 1 in 1000 chance to win the whole bonus pool, 0.1%
        let total_bonus_pool_win = rg.generate_u64_in_range(0, game.total_bonus_pool_win_chance - 1) == 0;
        
        let bonus_coin;
        if (total_bonus_pool_win) {
            bonus_coin = balance_withdraw_all_to_coin(&mut game.bonus_pool, ctx);
        } else {
            let choiced_value = weighted_random_choice(game.bonus_weights, game.bonus_values, rg);

            bonus_coin = balance_withdraw_to_coin(&mut game.bonus_pool, choiced_value, ctx);
        };
        
        let bonus_value = bonus_coin.value();

        keep(bonus_coin, ctx);

        (is_bonus_play, bonus_value)
    }

    // ========================= PLAYS/HISTORY

    fun update_last_plays<T>(game: &mut Game<T>, play: Play) {
        let last_plays =&mut game.last_plays;
        if (last_plays.length() >= INITIAL_LAST_PLAYS_SIZE) {
            // remove the oldest play
            last_plays.reverse();
            last_plays.pop_back();
            last_plays.reverse();
        };
        last_plays.push_back(play);
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

        let plays_count = 100u16;
        plays_count.do!(|_| {
            ts.next_tx(PLAYER);
            let bet = coin::mint_for_testing<SUI>(ONE_SUI, ts.ctx());
            play(&mut game, &r, bet, ts.ctx());
        });

        assert!(game.stats.total_plays == plays_count as u64);
        assert!(game.stats.total_bonus_plays == plays_count as u64 / game.bonus_frequency);
    
        assert!(game.get_address_stats(PLAYER).total_plays == plays_count as u64);
        assert!(game.get_address_stats(PLAYER).total_bonus_plays == plays_count as u64 / game.bonus_frequency);

        print(&game);
        ts::return_shared(r);
        ts::return_shared(game);
        ts::end(ts);
    }

    #[test]
    fun test_last_plays_vector(){
        let mut ts = ts::begin(ADMIN);
        test_init(&mut ts);

        ts.next_tx(ADMIN);
        test_new(&mut ts);

        ts.next_tx(ADMIN);
        let mut game = ts.take_shared<Game<SUI>>();
        let game_id = object::id(&game);
        print(&game);

        20u8.do!(|i| {
            update_last_plays(&mut game, Play {
                game: game_id,
                player: PLAYER,
                win: true,
                bet: 100,
                prize: i as u64,
                is_bonus_play: false,
                bonus_win: false,
                bonus_prize: 0,
            });
        });

        assert!(game.last_plays.length() == INITIAL_LAST_PLAYS_SIZE);

        print(&game);
        ts::return_shared(game);
        ts::end(ts);
    }

    #[test]
    fun test_total_bonus_pool_win (){
        let mut ts = ts::begin(ADMIN);

        test_init(&mut ts);

        ts.next_tx(ADMIN);
        let r = ts.take_shared<Random>();

        let mut rg = random::new_generator(&r, ts.ctx());

        let mut wins_count = 0;
        1000u64.do!(|_| {
            let total_bonus_pool_win = rg.generate_u64_in_range(0, 999) == 0;
            if (total_bonus_pool_win) {
                wins_count = wins_count + 1;
            }
        });

        print(&b"Total wins: ".to_string());
        print(&wins_count);

        ts::return_shared(r);
        ts.end();
    }

}

