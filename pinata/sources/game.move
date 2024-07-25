module pinata::game {
    use sui::balance::{Balance};
    use sui::coin::{Self, Coin};
    use sui::pay::{Self};
    use sui::sui::SUI;
    use sui::package::{Self, Publisher};
    use sui::zklogin_verified_issuer::check_zklogin_issuer;

    use std::string::{Self};

    const ENotAuthorized :u64 = 0;
    const EGameInactive :u64 = 1;
    const EInvalidPrizeValue :u64 = 2;
    const EInvalidTaps :u64 = 3;
    const EInvalidProof :u64 = 4;

    public struct GAME has drop {}

    public struct Game has key {
        id: UID,
        active: bool,
        prizeValue: u64,
        prizeBalance: Option<Balance<SUI>>,
        taps: u64,
        winner: Option<address>,
    }

    fun init(otw: GAME, ctx: &mut TxContext) {
        let publisher = package::claim(otw, ctx);

        transfer::public_transfer(publisher, ctx.sender());
    }

    public fun new(cap: &Publisher, taps: u64, coin: Coin<SUI>, ctx: &mut TxContext){
        assert_admin(cap);

        assert!(taps > 0, EInvalidTaps);

        let id = object::new(ctx);

        let prizeValue = coin.value();
        assert!(prizeValue > 0, EInvalidPrizeValue);

        let prizeBalance = coin.into_balance();

        let game = Game {
            id,
            active: true,
            prizeValue,
            prizeBalance: option::some(prizeBalance),
            taps,
            winner: option::none(),
        };

        transfer::share_object(game)
    }

    public fun cancel(cap: &Publisher, game: &mut Game, ctx: &mut TxContext){
        assert_admin(cap);
        assert_game_is_active(game);

        end_game(game);
        claim_prize(game, ctx);
    }

    public fun tap(game: &mut Game, address_seed: u256, ctx: &mut TxContext){
        assert_game_is_active(game);
        assert_sender_zklogin(address_seed, ctx);

        game.taps = game.taps - 1;

        if (game.taps == 0) {
            end_game(game);
            claim_prize(game, ctx);
            set_winner(game, ctx);
        }
    }

    fun end_game(game: &mut Game){
        game.active = false;
    }
    
    
    fun claim_prize(game: &mut Game, ctx: &mut TxContext){
        let prizeBalance = game.prizeBalance.extract();
        let prizeCoin = coin::from_balance(prizeBalance, ctx);

        pay::keep(prizeCoin, ctx);
    }

    fun set_winner(game: &mut Game, ctx: &TxContext){
        game.winner = option::some(ctx.sender());
    }

    fun assert_sender_zklogin(address_seed: u256, ctx: &TxContext) {
        let sender = ctx.sender();
        // todo: Find out how we can specify the google client id
        let issuer = string::utf8(b"https://accounts.google.com");
        assert!(check_zklogin_issuer(sender, address_seed, &issuer), EInvalidProof);
    }

    fun assert_game_is_active(game: &Game){
        assert!(game.active, EGameInactive);
    }
    
    fun assert_admin(cap: &Publisher){
        assert!(cap.from_module<GAME>(), ENotAuthorized);
    }
}

