module pre_market::offer {
    use pre_market::market::{Market};
    use whusdce::coin::COIN as USDC;

    use sui::coin::{Self, Coin};
    use sui::sui::{SUI};
    use sui::balance::{Balance};
    use sui::package::{Self};
    use sui::object::{Self};
    use sui::balance::{Self};
    use sui::pay::{keep};
    
    use std::string::{String};
    use std::type_name::{Self};

    // ========================= CONSTANTS =========================

    // ========================= STATUSES 
    const ACTIVE: u8 = 0;
    const CANCELLED: u8 = 1;
    const FILLED: u8 = 2;
    const CLOSED: u8 = 3;
    

    // ========================= ERRORS =========================

    // ========================= STRUCTS =========================

    public struct Offer has key {
        id: UID,
        market_id: ID,
        status: u8,
        creator: address,
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

    public struct OfferClosed has copy, drop {
        offer: ID,
    }

    // ========================= PUBLIC FUNCTIONS =========================

    //  public fun create_offer(
    //     market: &mut Market,
    //     creator: address,
    //     ctx: &mut TxContext,
    // ) {
    //     // let market = Market::get(market_id);
    //     // assert!(market.status == MarketStatus::Active, "Market is not active");

    //     let offer = Offer {
    //         id: object::new(ctx),
    //         market_id: object::id(market),
    //         filled: false,
    //         creator,
    //     };

    //     transfer::share_object(offer);
    // }

    // entry fun top_up_market(
    //     market: &mut Market,
    //     coin: Coin<USDC>,
    //     ctx: &mut TxContext,
    // ) {
    //     market.balance.join(coin.into_balance());
    // }

    // entry fun widthdaw_market(
    //     market: &mut Market,
    //     ctx: &mut TxContext,
    // ) {
    //     keep(coin::from_balance(market.balance.withdraw_all(), ctx), ctx);
    // }

    // ========================= PRIVATE FUNCTIONS =========================

}