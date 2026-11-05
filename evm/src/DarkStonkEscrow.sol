// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Dark Stonk escrow: a dark pool for memecoins, on EVM chains.
/// @notice Orders sit in escrow with their price and payout wallet hidden behind a
/// keccak256 commitment. A fill reveals them, and the contract checks the reveal
/// against the commitment before anything moves, so the matcher (our server) can
/// decide *which* orders meet but can never move funds at a price the owner didn't
/// commit to. Owners can cancel at any time, even while paused.
///
/// Prices are wei per PRICE_SCALE base units of the coin. Same model as the
/// Solana program, with one difference: a taker's fill is authorised by the
/// matcher's EIP-712 signature instead of a co-signature on the transaction.
///
/// Coins that take a cut of every transfer are welcome: an order books what
/// actually arrived, and a buyer pays only for the coins that reach them.
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

contract DarkStonkEscrow {
    uint256 public constant PRICE_SCALE = 1e18;
    uint16 public constant MAX_FEE_BPS = 100; // 1%
    uint8 public constant SIDE_SELL = 0;
    uint8 public constant SIDE_BUY = 1;

    struct Order {
        address maker;
        uint8 side;
        uint40 createdAt;
        uint40 expiresAt;
        address token;
        uint128 total; // sell: coin base units, buy: wei
        uint128 left;
        bytes32 commitment; // keccak256(abi.encode(price, payout, salt))
    }

    /// One resting order taken, with its reveal.
    struct Take {
        bytes32 order;
        uint256 amount; // coin base units
        uint256 price;
        address payout;
        bytes32 salt;
    }

    bytes32 private constant APPROVAL_TYPEHASH =
        keccak256("Approval(address taker,address to,uint8 side,bytes32 takes,uint256 deadline)");
    bytes32 public immutable DOMAIN_SEPARATOR;

    address public admin;
    address public pendingAdmin;
    address public matcher;
    address public feeWallet;
    uint16 public feeBps;
    bool public paused;

    mapping(bytes32 => Order) public orders;
    /// matcher approvals already spent, so one can't be replayed
    mapping(bytes32 => bool) public spent;

    uint256 private locked = 1;

    event Opened(bytes32 indexed order, address indexed maker, address indexed token, uint8 side, uint256 total, uint40 expiresAt);
    event Cancelled(bytes32 indexed order, address indexed maker, uint256 left);
    event Filled(bytes32 indexed order, address indexed token, uint8 side, address taker, uint256 amount, uint256 price, uint256 cost, uint256 fee);
    event Crossed(bytes32 indexed sellOrder, bytes32 indexed buyOrder, address indexed token, uint256 amount, uint256 price, uint256 cost, uint256 fee);
    event Config(address admin, address matcher, address feeWallet, uint16 feeBps, bool paused);
    event AdminProposed(address pendingAdmin);

    error Paused();
    error ZeroAmount();
    error Expired();
    error Taken();
    error NotMaker();
    error NotAdmin();
    error NotMatcher();
    error BadSide();
    error BadCommitment();
    error BadApproval();
    error TooMuch();
    error DustFill();
    error WrongValue();
    error NoCross();
    error FeeTooHigh();
    error TransferFailed();
    error Reentrant();
    error ZeroAddress();

    modifier nonReentrant() {
        if (locked != 1) revert Reentrant();
        locked = 2;
        _;
        locked = 1;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier live() {
        if (paused) revert Paused();
        _;
    }

    /// Config is set here, once, by whoever deploys: there is no init call to race.
    constructor(address admin_, address matcher_, address feeWallet_, uint16 feeBps_) {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        admin = admin_;
        matcher = matcher_;
        feeWallet = feeWallet_;
        feeBps = feeBps_;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Dark Stonk"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
        emit Config(admin_, matcher_, feeWallet_, feeBps_, false);
    }

    /* ------------------------------------------------------------ admin */

    function setConfig(address matcher_, address feeWallet_, uint16 feeBps_, bool paused_) external onlyAdmin {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        matcher = matcher_;
        feeWallet = feeWallet_;
        feeBps = feeBps_;
        paused = paused_;
        emit Config(admin, matcher_, feeWallet_, feeBps_, paused_);
    }

    /// Two steps, so a typo can't hand the contract to an address nobody holds.
    function proposeAdmin(address next) external onlyAdmin {
        pendingAdmin = next;
        emit AdminProposed(next);
    }

    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert NotAdmin();
        admin = msg.sender;
        pendingAdmin = address(0);
        emit Config(admin, matcher, feeWallet, feeBps, paused);
    }

    /* ------------------------------------------------------------ makers */

    function orderId(address maker, uint64 nonce) public pure returns (bytes32) {
        return keccak256(abi.encode(maker, nonce));
    }

    function commitmentOf(uint256 price, address payout, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(price, payout, salt));
    }

    /// Escrow `amount` of the coin for sale. The coin must be approved to this contract first.
    function openSell(uint64 nonce, address token, uint128 amount, bytes32 commitment, uint40 expiresAt)
        external
        live
        nonReentrant
        returns (bytes32 id)
    {
        if (amount == 0) revert ZeroAmount();
        // a coin that takes a cut of transfers delivers less: the order holds what arrived
        uint256 before = IERC20(token).balanceOf(address(this));
        _pull(token, msg.sender, address(this), amount);
        uint256 arrived = IERC20(token).balanceOf(address(this)) - before;
        if (arrived == 0 || arrived > type(uint128).max) revert ZeroAmount();
        id = _open(nonce, token, SIDE_SELL, uint128(arrived), commitment, expiresAt);
    }

    /// Escrow the ETH sent to buy the coin.
    function openBuy(uint64 nonce, address token, bytes32 commitment, uint40 expiresAt)
        external
        payable
        live
        nonReentrant
        returns (bytes32 id)
    {
        if (msg.value == 0) revert ZeroAmount();
        if (msg.value > type(uint128).max) revert TooMuch();
        id = _open(nonce, token, SIDE_BUY, uint128(msg.value), commitment, expiresAt);
    }

    /// Hand back what's left of the order to its maker. Works while paused.
    function cancel(bytes32 id) external nonReentrant {
        Order memory o = orders[id];
        if (o.maker != msg.sender) revert NotMaker();
        delete orders[id];
        if (o.left > 0) {
            if (o.side == SIDE_SELL) _push(o.token, o.maker, o.left);
            else _sendEth(o.maker, o.left);
        }
        emit Cancelled(id, o.maker, o.left);
    }

    /* ------------------------------------------------------------ takers */

    /// Buy coins out of resting sell orders, paying their committed prices in ETH.
    /// The coins go to `to` (the taker, or a wallet the taker names). Each take is
    /// priced on the coins that reach `to`; ETH sent above the total comes back.
    function takeSells(Take[] calldata takes, address to, uint256 deadline, bytes calldata approval)
        external
        payable
        live
        nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();
        _approve(takes, to, SIDE_SELL, deadline, approval);
        uint256 paid;
        uint256 fees;
        for (uint256 i; i < takes.length; i++) {
            Take calldata t = takes[i];
            Order storage o = orders[t.order];
            _check(o, t, SIDE_SELL);
            if (t.amount > o.left) revert TooMuch();
            address token = o.token;
            _settle(t.order, o, t.amount);
            uint256 got = _pushMeasured(token, to, t.amount);
            uint256 cost = _mulDivUp(got, t.price);
            uint256 fee = (cost * feeBps) / 10_000;
            if (cost <= fee) revert DustFill();
            paid += cost;
            fees += fee;
            _sendEth(t.payout, cost - fee);
            emit Filled(t.order, token, SIDE_SELL, msg.sender, got, t.price, cost, fee);
        }
        if (msg.value < paid) revert WrongValue();
        if (fees > 0) _sendEth(feeWallet, fees);
        _sendEth(msg.sender, msg.value - paid);
    }

    /// Sell coins into resting buy orders at their committed prices, for ETH.
    /// The coin must be approved to this contract first.
    function takeBuys(Take[] calldata takes, uint256 deadline, bytes calldata approval) external live nonReentrant {
        _approve(takes, msg.sender, SIDE_BUY, deadline, approval);
        uint256 owed;
        uint256 fees;
        for (uint256 i; i < takes.length; i++) {
            Take calldata t = takes[i];
            Order storage o = orders[t.order];
            _check(o, t, SIDE_BUY);
            address token = o.token;
            // the buyer pays for the coins that reach them, after any cut the coin takes
            uint256 before = IERC20(token).balanceOf(t.payout);
            _pull(token, msg.sender, t.payout, t.amount);
            uint256 got = IERC20(token).balanceOf(t.payout) - before;
            uint256 cost = (got * t.price) / PRICE_SCALE;
            uint256 fee = (cost * feeBps) / 10_000;
            if (cost <= fee) revert DustFill();
            if (cost > o.left) revert TooMuch();
            _settle(t.order, o, cost);
            owed += cost - fee;
            fees += fee;
            emit Filled(t.order, token, SIDE_BUY, msg.sender, got, t.price, cost, fee);
        }
        _sendEth(msg.sender, owed);
        if (fees > 0) _sendEth(feeWallet, fees);
    }

    /// Two resting orders meet. Settles at the midpoint of the two committed prices.
    function cross(Take calldata sell, Take calldata buy, uint256 amount) external live nonReentrant {
        if (msg.sender != matcher) revert NotMatcher();
        if (amount == 0) revert ZeroAmount();
        Order storage s = orders[sell.order];
        Order storage b = orders[buy.order];
        _check(s, sell, SIDE_SELL);
        _check(b, buy, SIDE_BUY);
        if (s.token != b.token) revert NoCross();
        if (buy.price < sell.price) revert NoCross();
        if (amount > s.left) revert TooMuch();

        uint256 price = (sell.price + buy.price) / 2;
        address token = s.token;
        _settle(sell.order, s, amount);
        // priced on the coins that reach the buyer
        uint256 got = _pushMeasured(token, buy.payout, amount);
        uint256 cost = (got * price) / PRICE_SCALE;
        uint256 fee = (cost * feeBps) / 10_000;
        if (cost <= fee) revert DustFill();
        if (cost > b.left) revert TooMuch();
        _settle(buy.order, b, cost);
        _sendEth(sell.payout, cost - fee);
        if (fee > 0) _sendEth(feeWallet, fee);
        emit Crossed(sell.order, buy.order, token, got, price, cost, fee);
    }

    /* ------------------------------------------------------------ internals */

    function _open(uint64 nonce, address token, uint8 side, uint128 total, bytes32 commitment, uint40 expiresAt)
        private
        returns (bytes32 id)
    {
        if (expiresAt <= block.timestamp) revert Expired();
        id = orderId(msg.sender, nonce);
        if (orders[id].maker != address(0)) revert Taken();
        orders[id] = Order({
            maker: msg.sender,
            side: side,
            createdAt: uint40(block.timestamp),
            expiresAt: expiresAt,
            token: token,
            total: total,
            left: total,
            commitment: commitment
        });
        emit Opened(id, msg.sender, token, side, total, expiresAt);
    }

    /// The order exists on the right side, hasn't expired, and the reveal matches it.
    function _check(Order storage o, Take calldata t, uint8 side) private view {
        if (o.maker == address(0) || o.side != side) revert BadSide();
        if (block.timestamp >= o.expiresAt) revert Expired();
        if (t.amount == 0 || t.price == 0) revert ZeroAmount();
        if (commitmentOf(t.price, t.payout, t.salt) != o.commitment) revert BadCommitment();
    }

    /// Take `used` off what's left; a finished order is deleted.
    function _settle(bytes32 id, Order storage o, uint256 used) private {
        uint128 left = o.left - uint128(used);
        if (left == 0) delete orders[id];
        else o.left = left;
    }

    /// The matcher signed off on exactly these takes, for this taker, once.
    function _approve(Take[] calldata takes, address to, uint8 side, uint256 deadline, bytes calldata sig) private {
        if (takes.length == 0) revert ZeroAmount();
        if (block.timestamp > deadline) revert Expired();
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(APPROVAL_TYPEHASH, msg.sender, to, side, keccak256(abi.encode(takes)), deadline))
            )
        );
        if (spent[digest]) revert BadApproval();
        if (_recover(digest, sig) != matcher) revert BadApproval();
        spent[digest] = true;
    }

    function _recover(bytes32 digest, bytes calldata sig) private pure returns (address) {
        if (sig.length != 65) return address(0);
        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);
        // the low-s half only, so a signature has one valid form
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) return address(0);
        if (v != 27 && v != 28) return address(0);
        return ecrecover(digest, v, r, s);
    }

    function _mulDivUp(uint256 amount, uint256 price) private pure returns (uint256) {
        uint256 p = amount * price;
        return p / PRICE_SCALE + (p % PRICE_SCALE == 0 ? 0 : 1);
    }

    function _sendEth(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// transfer / transferFrom that also accept coins which return nothing
    function _push(address token, address to, uint256 amount) private {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool))) || token.code.length == 0) revert TransferFailed();
    }

    /// send coins out and return how many actually arrived
    function _pushMeasured(address token, address to, uint256 amount) private returns (uint256) {
        uint256 before = IERC20(token).balanceOf(to);
        _push(token, to, amount);
        return IERC20(token).balanceOf(to) - before;
    }

    function _pull(address token, address from, address to, uint256 amount) private {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, amount));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool))) || token.code.length == 0) revert TransferFailed();
    }
}
