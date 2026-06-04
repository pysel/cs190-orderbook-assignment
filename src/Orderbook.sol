// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IOrderbook} from "./IOrderbook.sol";

/// @dev Minimal ERC20 surface the orderbook needs. The provided `MockERC20`
///      implements all of these methods (plus `mint`).
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

/// @title Orderbook (template)
/// @notice Skeleton to complete. The constructor, immutable
///         token wiring, and the two trivial getters are already done —
///         everything else reverts with `"NotImplemented"`.
///
///         You are free to add additional state, structs, errors, and
///         helper functions. The only hard constraints are:
///         (1) keep the `IOrderbook` ABI exactly as declared in the
///             interface (the grading harness depends on it), and
///         (2) keep `baseToken`/`quoteToken` as immutables set in the
///             constructor.
contract Orderbook is IOrderbook {
    IERC20 public immutable baseToken;
    IERC20 public immutable quoteToken;

    // Escrow. [SOURCE: Lecture: Covenants]
    struct Order {
        uint256 id; 
        address maker; 
        uint256 price; 
        uint256 amount; 
        uint256 escrow; 
    }

    // arrays
    Order[] internal bids; // BUY
    Order[] internal asks; // SELL

    uint256 internal nextOrderId = 1; // [SOURCE: Assignment PDF]

    uint256 internal constant BASE_UNIT = 1e18; // [SOURCE: Assignment PDF]

    /// @dev Suggested events. These are a starting point — your
    ///      implementation may emit a different set, rename them, or omit
    ///      events entirely. Nothing in the grading harness depends on
    ///      these signatures.
    event OrderPlaced(
        uint256 indexed orderId,
        address indexed maker,
        Side side,
        uint256 price,
        uint256 amount
    );
    event OrderFilled(
        uint256 indexed orderId,
        address indexed taker,
        uint256 fillAmount,
        uint256 fillPrice
    );
    event OrderCleared();

    constructor(address _baseToken, address _quoteToken) {
        require(_baseToken != address(0), "baseToken=0");
        require(_quoteToken != address(0), "quoteToken=0");
        require(_baseToken != _quoteToken, "base==quote");
        baseToken = IERC20(_baseToken);
        quoteToken = IERC20(_quoteToken);
    }

    function getBaseToken() external view returns (address) {
        return address(baseToken);
    }

    function getQuoteToken() external view returns (address) {
        return address(quoteToken);
    }

    // Rest [SOURCE: Assignment PDF]
    function placeLimitOrder(Side side, uint256 price, uint256 amount)
        external
        returns (uint256 orderId)
    {
        // guards [SOURCE: AI-suggested]
        require(amount > 0, "amount=0");
        require(price > 0, "price=0");

        orderId = nextOrderId++; // [SOURCE: Assignment PDF]

        if (side == Side.BUY) {
            // lock [SOURCE: Assignment PDF]
            uint256 quoteLocked = amount * price / BASE_UNIT;
            _pullTo(quoteToken, msg.sender, address(this), quoteLocked);
            bids.push(Order({id: orderId, maker: msg.sender, price: price, amount: amount, escrow: quoteLocked}));
        } else {
            // lock [SOURCE: Assignment PDF]
            _pullTo(baseToken, msg.sender, address(this), amount);
            asks.push(Order({id: orderId, maker: msg.sender, price: price, amount: amount, escrow: amount}));
        }

        emit OrderPlaced(orderId, msg.sender, side, price, amount);
    }

    // Match [SOURCE: Assignment PDF]
    function placeMarketOrder(Side side, uint256 amount) external {
        if (side == Side.BUY) {
            _marketBuy(amount);
        } else {
            _marketSell(amount);
        }
    }

    // buy
    function _marketBuy(uint256 amount) internal {
        uint256 remaining = amount;
        // walk [SOURCE: Assignment PDF + AI-suggested]
        while (remaining > 0 && asks.length > 0) {
            uint256 i = _bestAskIndex(); // lowest
            Order storage ask = asks[i];

            // snapshot
            uint256 restAmt = ask.amount;
            address mk = ask.maker;
            uint256 px = ask.price;
            uint256 oid = ask.id;

            // partial [SOURCE: Assignment PDF]
            uint256 fill = remaining < restAmt ? remaining : restAmt;
            bool full = (fill == restAmt);
            // floor [SOURCE: Assignment PDF + TA email] 
            uint256 quoteIn = fill * px / BASE_UNIT;

            // effects [SOURCE: AI-suggested]
            remaining -= fill;
            if (full) {
                _removeAt(asks, i);
            } else {
                ask.amount = restAmt - fill;
                ask.escrow -= fill; 
            }

            // [SOURCE: Assignment PDF]
            _pullTo(quoteToken, msg.sender, mk, quoteIn); // pay
            _send(baseToken, msg.sender, fill); // release
            emit OrderFilled(oid, msg.sender, fill, px);
        }
        // exhausted
    }

    // sell
    function _marketSell(uint256 amount) internal {
        uint256 remaining = amount;
        while (remaining > 0 && bids.length > 0) {
            uint256 i = _bestBidIndex(); // highest
            Order storage bid = bids[i];

            uint256 restAmt = bid.amount;
            address mk = bid.maker;
            uint256 px = bid.price;
            uint256 oid = bid.id;

            uint256 fill = remaining < restAmt ? remaining : restAmt; // partial
            bool full = (fill == restAmt);

            // floor [SOURCE: TA email]
            uint256 quoteOut = fill * px / BASE_UNIT;

            remaining -= fill;
            if (full) {
                _removeAt(bids, i);
            } else {
                bid.amount = restAmt - fill;
                bid.escrow -= quoteOut;
            }

            // [SOURCE: Assignment PDF]
            _pullTo(baseToken, msg.sender, mk, fill); // deliver
            _send(quoteToken, msg.sender, quoteOut); // release
            emit OrderFilled(oid, msg.sender, fill, px);
        }
    }

    // refund [SOURCE: Assignment PDF, Lecture, TA email]
    function clear() external {
        uint256 a = asks.length;
        for (uint256 i = 0; i < a; i++) {
            _send(baseToken, asks[i].maker, asks[i].escrow); // refund
        }
        uint256 b = bids.length;
        for (uint256 i = 0; i < b; i++) {
            _send(quoteToken, bids[i].maker, bids[i].escrow); // refund
        }
        delete asks; 
        delete bids;
        emit OrderCleared();
    }


    function getBidsCount() external view returns (uint256) {
        return bids.length;
    }

    function getAsksCount() external view returns (uint256) {
        return asks.length;
    }

    // midprice [SOURCE: Assignment PDF]
    function getMidPrice() external view returns (uint256) {
        require(bids.length > 0 && asks.length > 0, "empty book");
        uint256 bestBid = bids[_bestBidIndex()].price; // highest
        uint256 bestAsk = asks[_bestAskIndex()].price; // lowest
        return (bestBid + bestAsk) / 2; 
    }

    // oldest [SOURCE: TA email]
    function _bestAskIndex() internal view returns (uint256 best) {
        uint256 bestPx = asks[0].price;
        uint256 bestId = asks[0].id;
        for (uint256 i = 1; i < asks.length; i++) {
            uint256 px = asks[i].price;
            if (px < bestPx || (px == bestPx && asks[i].id < bestId)) {
                bestPx = px;
                bestId = asks[i].id;
                best = i;
            }
        }
    }

    // oldest [SOURCE: TA email]
    function _bestBidIndex() internal view returns (uint256 best) {
        uint256 bestPx = bids[0].price;
        uint256 bestId = bids[0].id;
        for (uint256 i = 1; i < bids.length; i++) {
            uint256 px = bids[i].price;
            if (px > bestPx || (px == bestPx && bids[i].id < bestId)) {
                bestPx = px;
                bestId = bids[i].id;
                best = i;
            }
        }
    }

    // swap-pop [SOURCE: Lecture: MPT + AI-suggested]
    function _removeAt(Order[] storage book, uint256 i) internal {
        uint256 last = book.length - 1;
        if (i != last) {
            book[i] = book[last];
        }
        book.pop();
    }

    // [SOURCE: ERC-20]
    function _pullTo(IERC20 token, address from, address to, uint256 amount) internal {
        require(token.transferFrom(from, to, amount), "transferFrom failed");
    }

    // [SOURCE: ERC-20]
    function _send(IERC20 token, address to, uint256 amount) internal {
        require(token.transfer(to, amount), "transfer failed");
    }
}
