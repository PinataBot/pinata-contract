module pre_market::offer {
    use pre_market::market::{Market};
    use pre_market::utils::{withdraw_balance};
    use whusdce::coin::COIN as USDC;

    use sui::coin::{Self, Coin};
    use sui::balance::{Balance};
    use sui::balance::{Self};
    use sui::event::{emit};
    use sui::clock::Clock;

    // ========================= CONSTANTS =========================

    // ========================= Statuses 
    const ACTIVE: u8 = 0;
    const CANCELLED: u8 = 1;
    const FILLED: u8 = 2;
    const SETTLED: u8 = 3;
    const CLOSED: u8 = 4;

    // ========================= ERRORS =========================

    const EInvalidPrice: u64 = 0;
    const EInvalidAmount: u64 = 1;
    const EInvalidPayment: u64 = 2;
    const EOfferInactive: u64 = 3;
    const EOfferNotFilled: u64 = 4;
    const ENotCreator: u64 = 5;
    const ENotFiller: u64 = 6;
    const EInvalidSettlement: u64 = 7;

    // ========================= STRUCTS =========================

    public struct Offer has key {
        /// Offer ID
        id: UID,
        /// Market ID
        market_id: ID,
        /// Status of the offer. 0 - Active, 1 - Cancelled, 2 - Filled, 3 - Closed
        status: u8,
        /// Is the offer buy or sell
        /// true - buy, false - sell
        is_buy: bool,
        /// Creator of the offer
        creator: address,
        /// Filled by
        filler: Option<address>,
        /// Price of one token in USDC
        price: u64,
        /// Amount of tokens
        amount: u64,
        /// Total value in USDC. price * amount
        /// Creator has to deposit this amount in USDC
        /// Filler has to deposit this amount in USDC
        collateral_value: u64,
        /// Balance of the offer
        /// After the offer is created, the balance is equal to collateral_value
        /// After the offer is filled, the balance is 2 * collateral_value
        /// After the offer is closed, the balance is 0
        balance: Balance<USDC>,
    }

    // ========================= EVENTS =========================

    public struct OfferCreated has copy, drop {
        offer: ID,
    }

    public struct OfferCanceled has copy, drop {
        offer: ID,
    }

    public struct OfferFilled has copy, drop {
        offer: ID,
    }

    public struct OfferSettled has copy, drop {
        offer: ID,
    }

    public struct OfferClosed has copy, drop {
        offer: ID,
    }

    // ========================= PUBLIC FUNCTIONS =========================

    public fun create(
        market: &mut Market,
        is_buy: bool,
        price: u64,
        amount: u64,
        mut coin: Coin<USDC>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        market.assert_active(clock);
        assert!(price > 0, EInvalidPrice);
        assert!(amount > 0, EInvalidAmount);

        let mut offer = Offer {
            id: object::new(ctx),
            market_id: object::id(market),
            status: ACTIVE,
            is_buy,
            creator: ctx.sender(),
            filler: option::none(),
            price,
            amount,
            collateral_value: price * amount,
            balance: balance::zero(),
        };

        let fee = offer.split_fee(market, &mut coin, ctx);
        market.add_offer(object::id(&offer), offer.is_buy, false, offer.collateral_value, fee, ctx);

        coin::put(&mut offer.balance, coin);
        
        emit(OfferCreated { offer: object::id(&offer) });

        transfer::share_object(offer);
    }

    public fun cancel(offer: &mut Offer, ctx: &mut TxContext) {
        offer.assert_active();
        offer.assert_creator(ctx);

        withdraw_balance(&mut offer.balance, ctx);
        offer.status = CANCELLED;
        
        emit(OfferCanceled { offer: object::id(offer) });
    }

    /// Fill the offer with the USDC deposit
    /// After filling the offer, the balance of the offer is 2 * collateral_value
    /// And userts have to wait settlement phase to settle the offer
    public fun fill(
        offer: &mut Offer, 
        market: &mut Market,
        mut coin: Coin<USDC>, 
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        market.assert_active(clock);
        offer.assert_active();

        let fee = offer.split_fee(market, &mut coin, ctx);
        market.add_offer(object::id(offer), !offer.is_buy, true, offer.collateral_value, fee, ctx);

        coin::put(&mut offer.balance, coin);
        offer.filler = option::some(ctx.sender());
        offer.status = FILLED;

        emit(OfferFilled { offer: object::id(offer) });
    }

    /// Settle the offer
    /// After the offer is settled, the balance of the offer is 0
    /// Sender sends coins to the second party and withdraws the USDC deposit from 2 parties
    /// If there are no settlement after settlement phase, the second party can withdraw the USDC deposit from 2 parties
    public fun settle<T>(
        offer: &mut Offer,
        market: &mut Market,
        coin: Coin<T>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        market.assert_settlement(clock);
        offer.assert_filled();

        let recipient: address;
        if (offer.is_buy) {
            offer.assert_filler(ctx);
            recipient = offer.creator;
        } else {
            offer.assert_creator(ctx);
            recipient = *offer.filler.borrow();
        };

        offer.assert_valid_settlement(market, &coin);
        
        transfer::public_transfer(coin, recipient);

        withdraw_balance(&mut offer.balance, ctx);

        offer.status = SETTLED;

        emit(OfferSettled { offer: object::id(offer) });
    }

    /// Close the offer
    /// After the settlement phase, if the offer is not settled, the second party can close the offer
    /// And withdraw the USDC deposit from 2 parties
    public fun close(
        offer: &mut Offer,
        market: &mut Market,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        market.assert_closed(clock);
        offer.assert_filled();

        if (offer.is_buy) {
            offer.assert_creator(ctx);
        } else {
            offer.assert_filler(ctx);
        };

        withdraw_balance(&mut offer.balance, ctx);

        offer.status = CLOSED;

        emit(OfferClosed { offer: object::id(offer) });
    }
    

    // ========================= PRIVATE FUNCTIONS =========================

    fun split_fee(offer: &Offer, market: &Market, coin: &mut Coin<USDC>, ctx: &mut TxContext): Coin<USDC> {        
        let fee_value = offer.collateral_value * market.fee_percentage() / 100;

        assert!(coin.value() == offer.collateral_value + fee_value, EInvalidPayment);

        let fee = coin.split(fee_value, ctx);

        fee
    }

    fun assert_active(offer: &Offer) {
        assert!(offer.status == ACTIVE, EOfferInactive);
    }

    fun assert_filled(offer: &Offer) {
        assert!(offer.status == FILLED, EOfferNotFilled);
    }

    fun assert_creator(offer: &Offer, ctx: &TxContext) {
        assert!(offer.creator == ctx.sender(), ENotCreator);
    }

    fun assert_filler(offer: &Offer, ctx: &TxContext) {
        assert!(offer.filler.is_some() && offer.filler.borrow() == ctx.sender(), ENotFiller);
    }

    fun assert_valid_settlement<T>(offer: &Offer, market: &Market, coin: &Coin<T>) {
        market.assert_coin_type<T>();

        assert!(coin.value() == offer.amount * 10u64.pow(market.coin_decimals()), EInvalidSettlement);
    }
    
    // ========================= TESTS =========================
    #[test_only] use pre_market::market;

    #[test_only] use sui::test_scenario as ts;

    #[test]
    fun test_payment() {
        let sender = @0xA;
        let mut ts = ts::begin(sender);

        market::create_test_market(ts::ctx(&mut ts));
        ts::next_tx(&mut ts, sender);

        let market = ts::take_shared<Market>(&ts);

        // 1 USDC = 10^6
        let price = 1 * 10u64.pow(6);
        let amount = 1000;
        let collateral_value = price * amount;
        // std::debug::print(&collater_value);
        let fee_value = collateral_value * market.fee_percentage() / 100;
        // std::debug::print(&fee_value);
        let coin_value = collateral_value + fee_value;
        // std::debug::print(&coin_value);

        let mut coin = coin::mint_for_testing<USDC>(coin_value, ts::ctx(&mut ts));
        ts::next_tx(&mut ts, sender);
        // std::debug::print(&coin);

        let id = object::new(ts::ctx(&mut ts));
        let offer = Offer {
            id,
            market_id: object::id(&market),
            status: ACTIVE,
            is_buy: true,
            creator: sender,
            filler: option::none(),
            price,
            amount,
            collateral_value: price * amount,
            balance: balance::zero(),
        };
        transfer::share_object(offer);
        ts::next_tx(&mut ts, sender);

        let offer = ts::take_shared<Offer>(&ts);
        let fee = offer.split_fee(&market, &mut coin, ts::ctx(&mut ts));
        ts::next_tx(&mut ts, sender);
        // std::debug::print(&fee);

        assert!(coin.value() == collateral_value);
        assert!(fee.value() == fee_value);
        
        ts::return_shared(market);
        ts::return_shared(offer);
        coin::burn_for_testing(coin);
        coin::burn_for_testing(fee);
        ts::end(ts);
    }

}