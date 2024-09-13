module break_aptos_pinata::game {
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::event::{EventHandle, emit_event};
    use aptos_framework::account;
    use aptos_std::table::{Self as TableModule, Table};
    use std::signer::{address_of};
    use std::option::{Option, none, some};

    // ========================= CONSTANTS =========================


    // ========================= ERRORS =========================

    const E_NOT_AUTHORIZED: u64 = 0;
    const E_GAME_INACTIVE: u64 = 1;
    const E_INVALID_PRIZE_BALANCE: u64 = 2;
    const E_INVALID_TAPS: u64 = 3;
    const E_INVALID_PROOF: u64 = 4;
    const E_INVALID_GAME_ID: u64 = 5;

    // ========================= STRUCTS =========================

    struct Game has key, store {
        active: bool,
        prize: Coin<AptosCoin>,
        taps: u64,
        winner: Option<address>,
        initial_prize: u64,
        initial_taps: u64,

        taps_per_address: Table<address, u64>,
    }

    struct GameManager has key {
        games: Table<u64, Game>,
        next_game_id: u64,
        event_handle: EventHandle<GameEvent>,
    }

    #[event]
    struct GameEvent has copy, drop, store {
        game_id: u64,
        event_type: u8,
        // 0: Created, 1: Ended, 2: Cancelled, 3: Tapped
        winner: Option<address>,
        tapper: Option<address>,
    }
    // ========================= INITIALIZATION =========================


    fun init_module(admin: &signer) {
        let event_handle = account::new_event_handle<GameEvent>(admin);
        let games = TableModule::new<u64, Game>();
        let manager = GameManager {
            games,
            next_game_id: 0,
            event_handle,
        };
        move_to(admin, manager);
    }

    // ========================= PUBLIC MUTABLE FUNCTIONS =========================

    public entry fun new(admin: &signer, taps: u64, prize_value: u64) acquires GameManager {
        assert_admin(admin);

        assert!(taps > 0, E_INVALID_TAPS);
        assert!(prize_value > 0, E_INVALID_PRIZE_BALANCE);

        let prize = coin::withdraw<AptosCoin>(admin, prize_value);

        let manager_ref = borrow_global_mut<GameManager>(address_of(admin));
        let game_id = manager_ref.next_game_id;
        manager_ref.next_game_id = game_id + 1;

        let taps_per_address = TableModule::new<address, u64>();

        let game = Game {
            active: true,
            prize,
            taps,
            taps_per_address,
            winner: none(),
            initial_prize: prize_value,
            initial_taps: taps,
        };

        TableModule::add(&mut manager_ref.games, game_id, game);

        emit_event(&mut manager_ref.event_handle, GameEvent {
            game_id,
            event_type: 0, // 0 for GameCreated
            winner: none(),
            tapper: none(),
        });
    }

    public entry fun cancel(admin: &signer, game_id: u64) acquires GameManager {
        assert_admin(admin);

        let manager_ref = borrow_global_mut<GameManager>(address_of(admin));
        assert!(TableModule::contains(&manager_ref.games, game_id), E_INVALID_GAME_ID);

        let game_ref = TableModule::borrow_mut(&mut manager_ref.games, game_id);
        assert!(game_ref.active, E_GAME_INACTIVE);

        emit_event(&mut manager_ref.event_handle, GameEvent {
            game_id,
            event_type: 2, // 2 for GameCancelled
            winner: none(),
            tapper: none(),
        });

        end_game(true, game_ref, &mut manager_ref.event_handle, game_id, address_of(admin));
    }

    public entry fun tap(
        tapper: &signer,
        game_id: u64,
    ) acquires GameManager {
        let manager_ref = borrow_global_mut<GameManager>(get_admin_address());
        assert!(TableModule::contains(&manager_ref.games, game_id), E_INVALID_GAME_ID);

        let game_ref = TableModule::borrow_mut(&mut manager_ref.games, game_id);
        assert!(game_ref.active, E_GAME_INACTIVE);

        emit_event(&mut manager_ref.event_handle, GameEvent {
            game_id,
            event_type: 3, // 3 for Tapped
            winner: none(),
            tapper: some(address_of(tapper)),
        });

        game_ref.taps = game_ref.taps - 1;

        update_taps_per_address(game_ref, address_of(tapper));

        if (game_ref.taps == 0) {
            end_game(false, game_ref, &mut manager_ref.event_handle, game_id, address_of(tapper));
        }
    }

    // ========================= PUBLIC VIEW FUNCTIONS =========================

    #[view]
    public fun get_game(game_id: u64): (
        // active
        bool,
        // prize
        u64,
        // taps
        u64,
        // winner
        Option<address>,
        // initial_prize
        u64,
        // initial_taps
        u64,
    ) acquires GameManager {
        let manager_ref = borrow_global<GameManager>(get_admin_address());
        assert!(TableModule::contains(&manager_ref.games, game_id), E_INVALID_GAME_ID);
        let game = TableModule::borrow(&manager_ref.games, game_id);
        (
            game.active,
            coin::value(&game.prize),
            game.taps,
            game.winner,
            game.initial_prize,
            game.initial_taps,
        )
    }

    #[view]
    public fun get_address_taps(game_id: u64, addr: address): u64 acquires GameManager {
        let manager_ref = borrow_global<GameManager>(get_admin_address());
        assert!(TableModule::contains(&manager_ref.games, game_id), E_INVALID_GAME_ID);
        let game_ref = TableModule::borrow(&manager_ref.games, game_id);
        if (TableModule::contains(&game_ref.taps_per_address, addr)) {
            *TableModule::borrow(&game_ref.taps_per_address, addr)
        } else {
            0
        }
    }

    // ========================= PRIVATE FUNCTIONS =========================
    fun get_admin_address(): address {
        @break_aptos_pinata
    }

    fun assert_admin(signer: &signer) {
        assert!(address_of(signer) == get_admin_address(), E_NOT_AUTHORIZED);
    }

    fun update_taps_per_address(game_ref: &mut Game, tapper_address: address) {
        if (!TableModule::contains(&game_ref.taps_per_address, tapper_address)) {
            TableModule::add(&mut game_ref.taps_per_address, tapper_address, 0);
        };
        let taps = TableModule::borrow_mut(&mut game_ref.taps_per_address, tapper_address);
        *taps = *taps + 1;
    }

    fun end_game(
        cancel: bool,
        game_ref: &mut Game,
        event_handle: &mut EventHandle<GameEvent>,
        game_id: u64,
        recipient: address,
    ) {
        game_ref.active = false;
        if (!cancel) game_ref.winner = some(recipient);

        coin::deposit(recipient, coin::extract(&mut game_ref.prize, game_ref.initial_prize));

        emit_event(event_handle, GameEvent {
            game_id,
            event_type: if (cancel) 2 else 1, // 1 for GameEnded, 2 for GameCancelled
            winner: game_ref.winner,
            tapper: none(),
        });
    }


    // ========================= TESTS =========================


    #[test_only]
    use aptos_framework::account::create_account_for_test;
    #[test_only]
    use aptos_framework::timestamp;
    #[test_only]
    use aptos_framework::aptos_coin;

    #[test_only]
    const ONE_APTOS: u64 = 100000000;

    #[test_only]
    fun setup_test(aptos: &signer, admin: &signer, user: &signer) {
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(aptos);

        // create fake accounts (only for testing purposes) and deposit initial balance

        create_account_for_test(address_of(admin));
        coin::register<AptosCoin>(admin);

        create_account_for_test(address_of(user));
        coin::register<AptosCoin>(user);

        let coins = coin::mint(ONE_APTOS, &mint_cap);
        coin::deposit(address_of(admin), coins);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);

        timestamp::set_time_has_started_for_testing(aptos);
        init_module(admin);
    }
}
