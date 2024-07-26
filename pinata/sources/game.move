module pinata::game {
    use sui::balance::{Balance};
    use sui::coin::{Self, Coin};
    use sui::pay::{keep};
    use sui::sui::SUI;
    use sui::package::{Self, Publisher};
    use sui::table::{Self, Table};
    use sui::zklogin_verified_issuer::check_zklogin_issuer;

    const ENotAuthorized :u64 = 0;
    const EGameInactive :u64 = 1;
    const EInvalidPrizeValue :u64 = 2;
    const EInvalidTaps :u64 = 3;
    const EInvalidProof :u64 = 4;

    public struct GAME has drop {}

    public struct Game has key {
        id: UID,
        active: bool,
        prize_value: u64,
        prize_balance: Option<Balance<SUI>>,
        taps: u64,
        taps_per_address: Table<address, u64>,
        winner: Option<address>,
    }

    fun init(otw: GAME, ctx: &mut TxContext) {
        let publisher = package::claim(otw, ctx);

        transfer::public_transfer(publisher, ctx.sender());
    }

    // ========================= PUBLIC MUTABLE FUNCTIONS =========================

    public fun new(cap: &Publisher, taps: u64, coin: Coin<SUI>, ctx: &mut TxContext){
        assert_admin(cap);

        assert!(taps > 0, EInvalidTaps);

        let id = object::new(ctx);

        let prize_value = coin.value();
        assert!(prize_value > 0, EInvalidPrizeValue);

        let prize_balance = coin.into_balance();

        let game = Game {
            id,
            active: true,
            prize_value,
            prize_balance: option::some(prize_balance),
            taps,
            taps_per_address: table::new(ctx),
            winner: option::none(),
        };

        transfer::share_object(game)
    }

    public fun cancel(cap: &Publisher, game: &mut Game, ctx: &mut TxContext){
        assert_admin(cap);
        assert_game_is_active(game);

        game.end();
        game.claim_prize(ctx);
    }

    public fun tap(game: &mut Game, address_seed: u256, ctx: &mut TxContext){
        assert_game_is_active(game);
        assert_sender_zklogin(address_seed, ctx);

        game.taps = game.taps - 1;

        game.update_taps_per_address(ctx);

        if (game.taps == 0) {
            game.end();
            game.claim_prize(ctx);
            game.set_winner(ctx);
        }
    }

    // ========================= PUBLIC VIEW FUNCTIONS =========================

    public fun get_address_taps(game: &Game, address: address): u64 {
        game.taps_per_address[address]
    }


    // ========================= PRIVATE FUNCTIONS =========================

    fun update_taps_per_address(game: &mut Game, ctx: &TxContext){  
        let sender = ctx.sender();
        let taps_per_address = &mut game.taps_per_address;

        if (!taps_per_address.contains(sender)) {
            taps_per_address.add(sender, 0);
        };

        let address_taps = &mut taps_per_address[sender];
        *address_taps = *address_taps + 1;
    }

    fun end(game: &mut Game){
        game.active = false;
    }
    
    fun claim_prize(game: &mut Game, ctx: &mut TxContext){
        let prize_balance = game.prize_balance.extract();
        let prize_coin = coin::from_balance(prize_balance, ctx);

        keep(prize_coin, ctx);
    }

    fun set_winner(game: &mut Game, ctx: &TxContext){
        game.winner = option::some(ctx.sender());
    }

    fun assert_sender_zklogin(address_seed: u256, ctx: &TxContext) {
        let sender = ctx.sender();
        // todo: Find out how we can specify the google client id
        let issuer = std::string::utf8(b"https://accounts.google.com");
        assert!(check_zklogin_issuer(sender, address_seed, &issuer), EInvalidProof);
    }

    fun assert_game_is_active(game: &Game){
        assert!(game.active, EGameInactive);
    }
    
    fun assert_admin(cap: &Publisher){
        assert!(cap.from_module<GAME>(), ENotAuthorized);
    }
}

