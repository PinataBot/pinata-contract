module pre_market::partial_offer {
    use usdc::usdc::USDC;
    use pre_market::market::{Market};
    use pre_market::utils::{withdraw_balance, withdraw_balance_value};

    use sui::coin::{Self, Coin};
    use sui::balance::{Balance};
    use sui::balance::{Self};
    use sui::event::{emit};
    use sui::clock::Clock;
    use sui::vec_map::{Self, VecMap};

    // ========================= CONSTANTS =========================

    const ONE_USDC: u64 = 1_000_000;

    // ========================= Statuses 
    const ACTIVE: u8 = 0;
    const CANCELLED: u8 = 1;
    const PARTIAL_CANCELLED: u8 = 2;
    const FILLED: u8 = 3;
    const PARTIAL_FILLED: u8 = 4;
    const CLOSED: u8 = 5;

    // ========================= ERRORS =========================

    const EInvalidAmount: u64 = 0;
    const EInvalidCollateralValue: u64 = 1;
    const EInvalidPayment: u64 = 2;
    const EOfferInactive: u64 = 3;
    const EOfferNotFilled: u64 = 4;
    const ENotCreator: u64 = 5;
    const ENotFiller: u64 = 6;
    const EInvalidSettlement: u64 = 7;

    // ========================= STRUCTS =========================

    public struct PartialOffer has key {
        /// Offer ID
        id: UID,
        /// Market ID
        market_id: ID,
        /// Status of the offer. 0 - Active, 1 - Cancelled, 2 - Filled, 3 - Closed
        status: u8,
        /// Is the offer buy or sell
        /// true - buy, false - sell
        buy_or_sell: bool,
        /// Creator of the offer
        creator: address,
        /// Filled by
        /// address -> amount
        fillers: VecMap<address, u64>,
        /// Amount of tokens T to buy/sell
        /// Whole amount of the token
        /// Later this amount multiplied by 10^decimals of the token
        amount: u64,
        /// Amount of filled tokens
        filled_amount: u64,
        /// Total value in USDC with 6 decimals
        /// Creator has to deposit this amount in USDC
        /// Filler has to deposit this amount in USDC
        collateral_value: u64,
        /// Balance of the offer
        /// After the offer is created, the balance is equal to collateral_value
        /// After the offer is filled, the balance is 2 * collateral_value
        /// After the offer is closed, the balance is 0
        balance: Balance<USDC>,
        /// Created at timestamp in milliseconds
        created_at_timestamp_ms: u64,
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

    public struct OfferClosed has copy, drop {
        offer: ID,
    }

    // ========================= PUBLIC FUNCTIONS =========================

    entry public fun create(
        market: &mut Market,
        buy_or_sell: bool,
        amount: u64,
        collateral_value: u64,
        mut coin: Coin<USDC>,
        clock: &Clock, 
        ctx: &mut TxContext,
    ) {
        market.assert_active(clock);
        assert_minimal_amount(amount);
        assert_minimal_collateral_value(collateral_value);
        
        let mut offer = PartialOffer {
            id: object::new(ctx),
            market_id: object::id(market),
            status: ACTIVE,
            buy_or_sell,
            creator: ctx.sender(),
            fillers: vec_map::empty(),
            amount,
            filled_amount: 0,
            collateral_value,
            balance: balance::zero(),
            created_at_timestamp_ms: clock.timestamp_ms(),
        };

        let fee = offer.split_fee(market, &mut coin, ctx);
        market.add_offer(object::id(&offer), offer.buy_or_sell, false, offer.collateral_value, offer.amount, fee, ctx);

        coin::put(&mut offer.balance, coin);
        
        emit(OfferCreated { offer: object::id(&offer) });

        transfer::share_object(offer);
    }

    // todo: check if partially filled
    entry public fun cancel(offer: &mut PartialOffer, market: &mut Market, ctx: &mut TxContext) {
        offer.assert_fillable();
        offer.assert_creator(ctx);
        
        if (offer.status == ACTIVE) {
            market.cancel_offer(object::id(offer), offer.buy_or_sell, offer.collateral_value, offer.amount);
        
            withdraw_balance(&mut offer.balance, ctx);
            offer.status = CANCELLED;
        } else {
            let filled_amount = offer.filled_amount;
            let unfilled_amount = offer.amount - filled_amount;

            // collateral value  = 10 USDC, amount = 10, filled_amount = 5
            // unfilled_amount = 10 - 5 = 5
            // unfilled_collateral_value = 10 - 5 * 10 / 10 = 5
            let unfilled_collateral_value = offer.balance.value() - filled_amount * offer.collateral_value / offer.amount;

            market.cancel_offer(object::id(offer), offer.buy_or_sell, unfilled_collateral_value, unfilled_amount);

            withdraw_balance_value(&mut offer.balance, unfilled_collateral_value, ctx);
            offer.status = PARTIAL_CANCELLED;
        };
        
        emit(OfferCanceled { offer: object::id(offer) });
    }

    entry public fun fill(
        offer: &mut PartialOffer, 
        market: &mut Market,
        amount: u64,
        mut coin: Coin<USDC>, 
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        market.assert_active(clock);
        offer.assert_fillable();
        offer.assert_not_creator(ctx);

        assert_minimal_amount(amount);
        assert!(amount <= offer.amount - offer.filled_amount, EInvalidAmount);

        let fee = offer.split_fee_partial(market, &mut coin, amount, ctx);
        market.add_offer(object::id(offer), !offer.buy_or_sell, true, offer.collateral_value, offer.amount, fee, ctx);

        coin::put(&mut offer.balance, coin);
        offer.add_filler(ctx.sender(), amount);
        offer.filled_amount = offer.filled_amount + amount;
        offer.status = if (offer.filled_amount >= offer.amount) { FILLED } else { PARTIAL_FILLED };

        emit(OfferFilled { offer: object::id(offer) });
    }

    /// --- from single_offer
    /// Settle the offer
    /// After the offer is settled, the balance of the offer is 0
    /// Sender sends coins to the second party and withdraws the USDC deposit from 2 parties
    /// If there are no settlement after settlement phase, the second party can withdraw the USDC deposit from 2 parties
    // entry public fun settle_and_close<T>(
    //     offer: &mut PartialOffer,
    //     market: &mut Market,
    //     coin: Coin<T>,
    //     clock: &Clock,
    //     ctx: &mut TxContext
    // ) {
    //     market.assert_settlement(clock);
    //     offer.assert_filled();

    //     let recipient: address;
    //     if (offer.buy_or_sell) {
    //         // Maxim - Buy, Ernest - Sell
    //         // Ernest settles tokens
    //         // Maxim receives tokens
    //         // Ernest receives USDC deposit from 2 parties
    //         offer.assert_filler(ctx);
    //         recipient = offer.creator;
    //     } else {
    //         // Maxim - Sell, Ernest - Buy
    //         // Maxim settles tokens
    //         // Ernest receives tokens
    //         // Maxim receives USDC deposit from 2 parties
    //         offer.assert_creator(ctx);
    //         recipient = offer.fillers.keys()[0];
    //     };

    //     offer.assert_valid_settlement(market, &coin);
        
    //     transfer::public_transfer(coin, recipient);

    //     withdraw_balance(&mut offer.balance, ctx);

    //     offer.status = CLOSED;

    //     market.update_closed_offers(object::id(offer));

    //     emit(OfferClosed { offer: object::id(offer) });
    // }

    // TODO: implement
    entry public fun settle_and_close<T>(
        // offer: &mut Offer,
        // market: &mut Market,
        // coin: Coin<T>,
        // clock: &Clock,
        // ctx: &mut TxContext
    ) {

    }

    /// Close the offer
    /// After the settlement phase, if the offer is not settled, the second party can close the offer
    /// And withdraw the USDC deposit from 2 parties
    entry public fun close(
        offer: &mut PartialOffer,
        market: &mut Market,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        market.assert_closed(clock);
        offer.assert_closable();

        if (offer.buy_or_sell) {
            // Maxim - Buy, Ernest - Sell
            // Ernest doesn't settle tokens
            // Maxim can close the offer and withdraw the USDC deposit from 2 parties
            offer.assert_creator(ctx);
        } else {
            // Maxim - Sell, Ernest - Buy
            // Maxim doesn't settle tokens
            // Ernest can close the offer and withdraw the USDC deposit from 2 parties
            offer.assert_filler(ctx);
        };

        withdraw_balance(&mut offer.balance, ctx);

        offer.status = CLOSED;

        market.update_closed_offers(object::id(offer));
        
        emit(OfferClosed { offer: object::id(offer) });
    }
    

    // ========================= PRIVATE FUNCTIONS =========================

    // 1UDSC: 1_000_000
    // 1_000_000 * 2 / 100 = 20_000
    // 1_000_000 + 20_000 = 1_020_000 
    fun split_fee(offer: &PartialOffer, market: &Market, coin: &mut Coin<USDC>, ctx: &mut TxContext): Coin<USDC> {        
        let fee_value = offer.collateral_value * market.fee_percentage() / 100;

        assert!(coin.value() == offer.collateral_value + fee_value, EInvalidPayment);

        let fee = coin.split(fee_value, ctx);

        fee
    }

    fun split_fee_partial(offer: &PartialOffer, market: &Market, coin: &mut Coin<USDC>, amount: u64, ctx: &mut TxContext): Coin<USDC> {
        let partial_value = offer.collateral_value / offer.amount * amount;
        // ensure that the partial value is not less than the minimal collateral value (1 USDC)
        assert_minimal_collateral_value(partial_value);

        let fee_value = partial_value * market.fee_percentage() / 100;

        // if offer.collateral_value = 10 USDC, offer.amount = 10, amount = 5 => partial_value = 5 USDC, fee_value = 5 * 2 / 100 = 0.1 USDC
        assert!(coin.value() == partial_value + fee_value, EInvalidPayment);

        let fee = coin.split(fee_value, ctx);

        fee
    }

    fun add_filler(offer: &mut PartialOffer, address: address, amount: u64) {
        if (offer.fillers.contains(&address)) {
            let current_amount = offer.fillers.get_mut(&address);
            *current_amount = *current_amount + amount;
        } else {
            offer.fillers.insert(address, amount);
        }
    }

    // ========================= Asserts

    fun assert_active(offer: &PartialOffer) {
        assert!(offer.status == ACTIVE, EOfferInactive);
    }

    fun assert_fillable(offer: &PartialOffer) {
        assert!(offer.status == ACTIVE || offer.status == PARTIAL_FILLED, EOfferInactive);
    }

    fun assert_partial_filled(offer: &PartialOffer) {
        assert!(offer.status == PARTIAL_FILLED, EOfferNotFilled);
    }

    fun assert_filled(offer: &PartialOffer) {
        assert!(offer.status == FILLED, EOfferNotFilled);
    }

    fun assert_closable(offer: &PartialOffer) {
        assert!(offer.status == FILLED || offer.status == PARTIAL_FILLED || offer.status == PARTIAL_CANCELLED, EOfferNotFilled);
    }

    fun assert_creator(offer: &PartialOffer, ctx: &TxContext) {
        assert!(offer.creator == ctx.sender(), ENotCreator);
    }

    fun assert_not_creator(offer: &PartialOffer, ctx: &TxContext) {
        assert!(offer.creator != ctx.sender(), ENotCreator);
    }

    fun assert_filler(offer: &PartialOffer, ctx: &TxContext) {
        assert!(offer.fillers.contains(&ctx.sender()), ENotFiller);
    }

    fun assert_valid_settlement<T>(offer: &PartialOffer, market: &Market, coin: &Coin<T>) {
        market.assert_coin_type<T>();

        assert!(coin.value() == offer.amount * 10u64.pow(market.coin_decimals()), EInvalidSettlement);
    }

    fun assert_minimal_amount(amount: u64) {
        assert!(amount > 0, EInvalidAmount);
    }

    fun assert_minimal_collateral_value(collateral_value: u64) {
        assert!(collateral_value >= ONE_USDC, EInvalidCollateralValue);
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
        let collateral_value = ONE_USDC;
        let amount = 1000;
        std::debug::print(&collateral_value);
        let fee_value = collateral_value * market.fee_percentage() / 100;
        std::debug::print(&fee_value);
        let coin_value = collateral_value + fee_value;
        std::debug::print(&coin_value);

        let mut coin = coin::mint_for_testing<USDC>(coin_value, ts::ctx(&mut ts));
        ts::next_tx(&mut ts, sender);
        // std::debug::print(&coin);

        let id = object::new(ts::ctx(&mut ts));
        let offer = PartialOffer {
            id,
            market_id: object::id(&market),
            status: ACTIVE,
            buy_or_sell: true,
            creator: sender,
            fillers: vec_map::empty(),
            // price,
            amount,
            filled_amount: 0,
            collateral_value,
            balance: balance::zero(),
            created_at_timestamp_ms: 0,
        };
        transfer::share_object(offer);
        ts::next_tx(&mut ts, sender);

        let offer = ts::take_shared<PartialOffer>(&ts);
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