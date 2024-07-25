module pinata::game {
    use sui::balance::{Balance};
    use sui::coin::{Self, Coin};
    use sui::pay::{Self};
    use sui::sui::SUI;
    use sui::package::{Self, Publisher};

    const ENotAuthorized :u64 = 0;
    const EGameInactive :u64 = 1;
    const EInvalidPrizeValue :u64 = 2;
    const EInvalidTaps :u64 = 3;

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
        check_authority(cap);

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
        check_authority(cap);
        check_game_active(game);

        game.active = false;

        claim_prize(game, ctx);
    }

    public fun tap(game: &mut Game, ctx: &mut TxContext){
        check_game_active(game);

        game.taps = game.taps - 1;

        if (game.taps == 0) {
            game.active = false;
            game.winner = option::some(ctx.sender());
            claim_prize(game, ctx);
        }
    }


    fun claim_prize(game: &mut Game, ctx: &mut TxContext){
        let prizeBalance = game.prizeBalance.extract();
        let prizeCoin = coin::from_balance(prizeBalance, ctx);

        pay::keep(prizeCoin, ctx);
    }

    fun check_game_active(game: &Game){
        assert!(game.active, EGameInactive);
    }
    
    fun check_authority(cap: &Publisher){
        assert!(cap.from_module<GAME>(), ENotAuthorized);
    }
}

