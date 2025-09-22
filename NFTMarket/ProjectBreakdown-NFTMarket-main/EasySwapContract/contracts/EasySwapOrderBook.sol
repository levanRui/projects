// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {LibTransferSafeUpgradeable, IERC721} from "./libraries/LibTransferSafeUpgradeable.sol";
import {Price} from "./libraries/RedBlackTreeLibrary.sol";
import {LibOrder, OrderKey} from "./libraries/LibOrder.sol";
import {LibPayInfo} from "./libraries/LibPayInfo.sol";

import {IEasySwapOrderBook} from "./interface/IEasySwapOrderBook.sol";
import {IEasySwapVault} from "./interface/IEasySwapVault.sol";

import {OrderStorage} from "./OrderStorage.sol";
import {OrderValidator} from "./OrderValidator.sol";
import {ProtocolManager} from "./ProtocolManager.sol";

contract EasySwapOrderBook is
    IEasySwapOrderBook,
    Initializable,
    ContextUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    OrderStorage,
    ProtocolManager,
    OrderValidator
{
    using LibTransferSafeUpgradeable for address;
    using LibTransferSafeUpgradeable for IERC721;

    event LogMake(
        OrderKey orderKey,
        LibOrder.Side indexed side,
        LibOrder.SaleKind indexed saleKind,
        address indexed maker,
        LibOrder.Asset nft,
        Price price,
        uint64 expiry,
        uint64 salt
    );

    event LogCancel(OrderKey indexed orderKey, address indexed maker);

    event LogMatch(
        OrderKey indexed makeOrderKey,
        OrderKey indexed takeOrderKey,
        LibOrder.Order makeOrder,
        LibOrder.Order takeOrder,
        uint128 fillPrice
    );

    event LogWithdrawETH(address recipient, uint256 amount);
    event BatchMatchInnerError(uint256 offset, bytes msg);
    event LogSkipOrder(OrderKey orderKey, uint64 salt);

    modifier onlyDelegateCall() {
        _checkDelegateCall();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable state-variable-assignment
    address private immutable self = address(this);

    address private _vault; //存储的是 "金库" 合约（EasySwapVault）的地址
    /**
        在_makeOrderTry函数中，通过IEasySwapVault(_vault)将该地址转换为对应的合约接口实例，进而调用金库合约的depositNFT和depositETH等方法，实现创建订单时的资产托管功能。
        简单说，_vault就是指向负责管理交易资产（NFT 和 ETH）的金库合约的地址引用，是整个交易系统中资产安全托管的关键指向。
     */

    /**
     * @notice Initialize contracts.
     * @param newProtocolShare Default protocol fee.
     * @param newVault easy swap vault address.
     */
    function initialize(
        uint128 newProtocolShare,
        address newVault,
        string memory EIP712Name,
        string memory EIP712Version
    ) public initializer {
        __EasySwapOrderBook_init(
            newProtocolShare,
            newVault,
            EIP712Name,
            EIP712Version
        );
    }

    function __EasySwapOrderBook_init(
        uint128 newProtocolShare,
        address newVault,
        string memory EIP712Name,
        string memory EIP712Version
    ) internal onlyInitializing {
        __EasySwapOrderBook_init_unchained(
            newProtocolShare,
            newVault,
            EIP712Name,
            EIP712Version
        );
    }

    function __EasySwapOrderBook_init_unchained(
        uint128 newProtocolShare,
        address newVault,
        string memory EIP712Name,
        string memory EIP712Version
    ) internal onlyInitializing {
        __Context_init();
        __Ownable_init(_msgSender());
        __ReentrancyGuard_init();
        __Pausable_init();

        __OrderStorage_init();
        __ProtocolManager_init(newProtocolShare);
        __OrderValidator_init(EIP712Name, EIP712Version);

        setVault(newVault);
    }

    /**
     * @notice Create multiple orders and transfer related assets.
     * @dev If Side=List, you need to authorize the EasySwapVault contract first (creating a List order will transfer the NFT to the order pool).
     * @dev If Side=Bid, you need to pass {value}: the price of the bid (similarly, creating a Bid order will transfer ETH to the order pool).
     * @dev order.maker needs to be msg.sender.
     * @dev order.price cannot be 0.
     * @dev order.expiry needs to be greater than block.timestamp, or 0.
     * @dev order.salt cannot be 0.
     * @param newOrders Multiple order structure data.
     * @return newOrderKeys The unique id of the order is returned in order, if the id is empty, the corresponding order was not created correctly.
     */
    function makeOrders(
        LibOrder.Order[] calldata newOrders
    )
        external
        payable
        override
        whenNotPaused
        nonReentrant
        returns (OrderKey[] memory newOrderKeys)
    {
        uint256 orderAmount = newOrders.length;
        newOrderKeys = new OrderKey[](orderAmount); // 初始化返回的newOrderKeys数组（长度与输入订单数量一致）

        uint128 ETHAmount; // total eth amount
        //循环处理每个订单
        for (uint256 i = 0; i < orderAmount; ++i) {
            uint128 buyPrice; // the price of bid order
            /**
                仅当订单方向为Bid（买入）时，才计算总价格buyPrice：
                单价（unwrap后的值） × NFT数量（nft.amount）。
                卖单（Ask）通常不需要预先支付 ETH，因此不计算buyPrice。
             */
            if (newOrders[i].side == LibOrder.Side.Bid) {
                buyPrice = Price.unwrap(newOrders[i].price) * newOrders[i].nft.amount;
            }
            //调用内部函数_makeOrderTry尝试创建订单，返回OrderKey（订单唯一标识）
            OrderKey newOrderKey = _makeOrderTry(newOrders[i], buyPrice);
            newOrderKeys[i] = newOrderKey;
            if (OrderKey.unwrap(newOrderKey) !=OrderKey.unwrap(LibOrder.ORDERKEY_SENTINEL)) {
                //订单创建成功
                ETHAmount += buyPrice;
            }
        }
        // 如果发送的ETH超过实际需要的总金额(ETHAmount)，将剩余部分返回给发送者
        if (msg.value > ETHAmount) {
            // return the remaining eth，if the eth is not enough, the transaction will be reverted
            _msgSender().safeTransferETH(msg.value - ETHAmount);
        }
        //隐含逻辑：若msg.value < ETHAmount（ETH 不足），交易会在_makeOrderTry中回滚（注释提到 “if the eth is not enough, the transaction will be reverted”），确保资金不足以创建订单时不会部分执行
    }

    /**
     * @dev Cancels multiple orders by their order keys.
     * @param orderKeys The array of order keys to cancel.
     */
    function cancelOrders(
        OrderKey[] calldata orderKeys
    )
        external
        override
        whenNotPaused
        nonReentrant
        returns (bool[] memory successes)
    {
        successes = new bool[](orderKeys.length);

        for (uint256 i = 0; i < orderKeys.length; ++i) {
            bool success = _cancelOrderTry(orderKeys[i]);
            successes[i] = success;
        }
    }

    /**
     * @notice Cancels multiple orders by their order keys.
     * @dev newOrder's saleKind, side, maker, and nft must match the corresponding order of oldOrderKey, otherwise it will be skipped; only the price can be modified.
     * @dev newOrder's expiry and salt can be regenerated.
     * @param editDetails The edit details of oldOrderKey and new order info
     * @return newOrderKeys The unique id of the order is returned in order, if the id is empty, the corresponding order was not edit correctly.
     */
    function editOrders(
        LibOrder.EditDetail[] calldata editDetails
    )
        external
        payable
        override
        whenNotPaused
        nonReentrant
        returns (OrderKey[] memory newOrderKeys)
    {
        newOrderKeys = new OrderKey[](editDetails.length);

        uint256 bidETHAmount;
        for (uint256 i = 0; i < editDetails.length; ++i) {
            (OrderKey newOrderKey, uint256 bidPrice) = _editOrderTry(
                editDetails[i].oldOrderKey,
                editDetails[i].newOrder
            );
            bidETHAmount += bidPrice;
            newOrderKeys[i] = newOrderKey;
        }

        if (msg.value > bidETHAmount) {
            _msgSender().safeTransferETH(msg.value - bidETHAmount);
        }
    }

    function matchOrder(
        LibOrder.Order calldata sellOrder,
        LibOrder.Order calldata buyOrder
    ) external payable override whenNotPaused nonReentrant {
        uint256 costValue = _matchOrder(sellOrder, buyOrder, msg.value);
        if (msg.value > costValue) {
            _msgSender().safeTransferETH(msg.value - costValue);
        }
    }
    //预创建订单(批量)
    /**
     * @dev Matches multiple orders atomically.
     * @dev If buying NFT, use the "valid sellOrder order" and construct a matching buyOrder order for order matching:
     * @dev    buyOrder.side = Bid, buyOrder.saleKind = FixedPriceForItem, buyOrder.maker = msg.sender,
     * @dev    nft and price values are the same as sellOrder, buyOrder.expiry > block.timestamp, buyOrder.salt != 0;
     * @dev If selling NFT, use the "valid buyOrder order" and construct a matching sellOrder order for order matching:
     * @dev    sellOrder.side = List, sellOrder.saleKind = FixedPriceForItem, sellOrder.maker = msg.sender,
     * @dev    nft and price values are the same as buyOrder, sellOrder.expiry > block.timestamp, sellOrder.salt != 0;
     * @param matchDetails Array of `MatchDetail` structs containing the details of sell and buy order to be matched.
     */
    /// @custom:oz-upgrades-unsafe-allow delegatecall
    function matchOrders(
        LibOrder.MatchDetail[] calldata matchDetails
    )
        external
        payable
        override
        whenNotPaused
        nonReentrant
        returns (bool[] memory successes)
    {
        successes = new bool[](matchDetails.length);

        uint128 buyETHAmount;

        for (uint256 i = 0; i < matchDetails.length; ++i) {
            LibOrder.MatchDetail calldata matchDetail = matchDetails[i];
            (bool success, bytes memory data) = address(this).delegatecall(
                abi.encodeWithSignature(
                    "matchOrderWithoutPayback((uint8,uint8,address,(uint256,address,uint96),uint128,uint64,uint64),(uint8,uint8,address,(uint256,address,uint96),uint128,uint64,uint64),uint256)",
                    matchDetail.sellOrder,
                    matchDetail.buyOrder,
                    msg.value - buyETHAmount
                )
            );

            if (success) {
                successes[i] = success;
                if (matchDetail.buyOrder.maker == _msgSender()) {
                    // buy order
                    uint128 buyPrice;
                    buyPrice = abi.decode(data, (uint128));
                    // Calculate ETH the buyer has spent
                    buyETHAmount += buyPrice;
                }
            } else {
                emit BatchMatchInnerError(i, data);
            }
        }

        if (msg.value > buyETHAmount) {
            // return the remaining eth
            _msgSender().safeTransferETH(msg.value - buyETHAmount);
        }
    }

    // 匹配买单和卖单(不涉及退款机制)     //external：只能从合约外部调用 payable：可以接收以太币  onlyDelegateCall: 只能通过委托调用的方式执行   whenNotPaused：合约未暂停时才能调用（通常是紧急暂停机制的一部分）
    function matchOrderWithoutPayback(
        LibOrder.Order calldata sellOrder,
        LibOrder.Order calldata buyOrder,
        uint256 msgValue//随交易发送的以太币数量
    )
        external
        payable
        whenNotPaused
        onlyDelegateCall
        returns (uint128 costValue)
    {
        costValue = _matchOrder(sellOrder, buyOrder, msgValue);
    }

    // 预创建订单(单个)
    function _makeOrderTry(
        LibOrder.Order calldata order,
        uint128 ETHAmount
    ) internal returns (OrderKey newOrderKey) {
        if (
            order.maker == _msgSender() && // only maker can make order--只有订单的制造者（maker）才能创建该订单。
            Price.unwrap(order.price) != 0 && // price cannot be zero
            order.salt != 0 && // salt cannot be zero
            (order.expiry > block.timestamp || order.expiry == 0) && // expiry must be greater than current block timestamp or no expiry --订单的过期时间要么大于当前区块时间（表示订单未过期），要么过期时间为 0（表示订单永不过期）。
            filledAmount[LibOrder.hash(order)] == 0 // order cannot be canceled or filled --该订单未被取消且未被成交过。
        ) {
            //如果条件满足，首先计算订单的哈希值newOrderKey = LibOrder.hash(order)，作为订单的唯一标识。
            newOrderKey = LibOrder.hash(order);

            // deposit asset to vault---资产存入

            if (order.side == LibOrder.Side.List) { //挂牌--卖方
                //挂牌: 是卖家将 NFT 放到市场上等待出售的行为。此时合约需要验证卖家是否真正拥有该 NFT、是否已授权合约转移该 NFT，并在订单创建后锁定卖家的 NFT（防止二次出售）。
                if (order.nft.amount != 1) {
                    // limit list order amount to 1  限制挂牌订单中 NFT 的数量为 1，若数量不为 1，返回LibOrder.ORDERKEY_SENTINEL（表示订单创建失败）。
                    return LibOrder.ORDERKEY_SENTINEL;
                }
                //将 NFT 存入指定的金库（_vault）
                IEasySwapVault(_vault).depositNFT(
                    newOrderKey,
                    order.maker,
                    order.nft.collection,
                    order.nft.tokenId
                );
            } else if (order.side == LibOrder.Side.Bid) { // 出价--买方
                //出价: 是买家针对某个挂牌 NFT 提出报价的行为。此时买家不需要提供 NFT，只需承诺支付对应资金（如 ETH 或代币），合约需要验证买家的资金是否充足，并锁定买家的资金（防止出价后资金不足）
                // 若 NFT 数量为 0，返回LibOrder.ORDERKEY_SENTINEL
                if (order.nft.amount == 0) {
                    return LibOrder.ORDERKEY_SENTINEL;
                }
                //将指定数量的 ETH 存入金库
                IEasySwapVault(_vault).depositETH{value: uint256(ETHAmount)}(
                    newOrderKey,
                    ETHAmount
                );
            }
            // 创将订单添加到订单列表等相关存储结构中
            _addOrder(order);
            // 触发LogMake事件，记录订单创建的相关信息。
            emit LogMake(
                newOrderKey,
                order.side,
                order.saleKind,
                order.maker,
                order.nft,
                order.price,
                order.expiry,
                order.salt
            );
        } else {
            // 记录跳过该订单的相关信息
            emit LogSkipOrder(LibOrder.hash(order), order.salt);
        }
    }

    /**
        尝试取消订单:
        指定的订单（通过 OrderKey 标识），仅在满足特定条件时执行取消操作，并将订单涉及的资产从金库（vault）返还给订单创建者（maker），同时更新订单状态
     */
    function _cancelOrderTry(
        OrderKey orderKey
    ) internal returns (bool success) {
        // 通过 orderKey 从存储的 orders 映射中读取订单数据
        LibOrder.Order memory order = orders[orderKey].order;
        /**
        取消条件检查  
            1.权限校验：订单的创建者（order.maker）必须是当前调用者（_msgSender()），确保只有订单所有者能取消订单。
            2.状态校验：订单的已填充数量（filledAmount[orderKey]）必须小于订单中 NFT 的总数量（order.nft.amount），即仅允许取消未完全成交的订单。
        */
        
        
        if (
            order.maker == _msgSender() &&
            filledAmount[orderKey] < order.nft.amount // only unfilled order can be canceled
        ) {
            // ----------------------- 执行取消操作---------------------------------
            // 计算订单哈希：通过 LibOrder.hash(order) 生成订单的唯一哈希 orderHash，用于后续资产操作的标识
            OrderKey orderHash = LibOrder.hash(order);
            //移除订单：调用 _removeOrder(order) 从订单簿中移除该订单（具体实现可能涉及删除存储中的订单记录）
            _removeOrder(order);
            // ------------------------资产从金库返还--------根据订单方向（side），将锁定在金库中的资产返还给 maker-----
            if (order.side == LibOrder.Side.List) { // 挂单（List）：订单是卖家挂单（出售 NFT），从金库提取对应的 NFT 返还给 maker
                IEasySwapVault(_vault).withdrawNFT(
                    orderHash, // 订单哈希（用于金库验证）
                    order.maker, // 接收者（订单创建者）
                    order.nft.collection,// NFT 集合地址
                    order.nft.tokenId// 具体 NFT 的 ID
                );
            } else if (order.side == LibOrder.Side.Bid) {// 买单（Bid）：订单是买家出价（购买 NFT），计算未成交部分对应的 ETH 金额（价格 × 未成交数量），从金库提取 ETH 返还给 maker：
                uint256 availNFTAmount = order.nft.amount -
                    filledAmount[orderKey];
                IEasySwapVault(_vault).withdrawETH(
                    orderHash,
                    Price.unwrap(order.price) * availNFTAmount, // the withdraw amount of eth
                    order.maker
                );
            }
            // ------------------------更新状态与事件-----------------------------------
            // 调用 _cancelOrder(orderKey) 正式标记订单为已取消（可能更新存储中的订单状态）
            _cancelOrder(orderKey);
            success = true; // 设置 success = true 表示取消成功
            emit LogCancel(orderKey, order.maker); //  触发LogCancel 事件，记录取消操作（便于链下跟踪）
        } else {
            // 取消失败处理
            emit LogSkipOrder(orderKey, order.salt); // 若不满足取消条件（如非订单所有者、订单已完全成交），则发射 LogSkipOrder 事件记录跳过取消的行为，不执行任何状态变更。
        }
    }

    /**
        修改订单
        允许用户修改订单，但严格限制只能修改价格（price） 和数量（amount），
        其他关键属性（如交易方向、交易对手、NFT 信息等）不允许变更。同时处理旧订单的取消和新订单的创建，
        并与金库合约（IEasySwapVault）交互以调整相关资产（NFT 或 ETH）。
     */
    function _editOrderTry(
        OrderKey oldOrderKey,// 旧订单的唯一标识（用于定位旧订单）
        LibOrder.Order calldata newOrder // 新的订单数据（calldata类型，节省 gas）
    ) internal returns (OrderKey newOrderKey, uint256 deltaBidPrice) {
        // 从存储中通过oldOrderKey获取旧订单的完整信息
        LibOrder.Order memory oldOrder = orders[oldOrderKey].order;

        // check order, only the price and amount can be modified  校验订单可修改性（旧订单 vs 新订单）
        if (
            (oldOrder.saleKind != newOrder.saleKind) || //交易类型（如固定价/拍卖）必须相同
            (oldOrder.side != newOrder.side) || //交易方向（挂单/出价）必须相同
            (oldOrder.maker != newOrder.maker) || //订单创建者必须相同
            (oldOrder.nft.collection != newOrder.nft.collection) ||// NFT合约地址必须相同
            (oldOrder.nft.tokenId != newOrder.nft.tokenId) ||// NFT tokenId必须相同
            filledAmount[oldOrderKey] >= oldOrder.nft.amount // // 旧订单未被完全填充
        ) {
            // 校验失败，触发跳过事件，返回哨兵值
            emit LogSkipOrder(oldOrderKey, oldOrder.salt);
            return (LibOrder.ORDERKEY_SENTINEL, 0);
        }

        // 校验新订单合法性
        if (
            newOrder.maker != _msgSender() || //调用者必须是新订单的创建者
            newOrder.salt == 0 ||// salt不能为0（用于生成唯一标识）
            (newOrder.expiry < block.timestamp && newOrder.expiry != 0) || // 未过期（expiry=0表示永不过期）
            filledAmount[LibOrder.hash(newOrder)] != 0  // 新订单未被填充或取消
        ) {
             // 校验失败，触发跳过事件，返回哨兵值
            emit LogSkipOrder(oldOrderKey, newOrder.salt);
            return (LibOrder.ORDERKEY_SENTINEL, 0);
        }

        // -------------------------取消旧订单--------------------------------
        uint256 oldFilledAmount = filledAmount[oldOrderKey];//记录旧订单的已填充数量
        _removeOrder(oldOrder); // 从存储中移除旧订单
        _cancelOrder(oldOrderKey); // 从订单簿中取消旧订单
        // 触发取消事件
        emit LogCancel(oldOrderKey, oldOrder.maker);

        // --------------------------创建新订单---------------------------------
        newOrderKey = _addOrder(newOrder); //将新订单添加到存储中，并获取其唯一标识
        // 与金库合约交互（根据订单方向）--->根据旧订单的交易方向（side），调用金库合约调整资产
        if (oldOrder.side == LibOrder.Side.List) { // 挂单（List）：修改 NFT 相关记录
            IEasySwapVault(_vault).editNFT(oldOrderKey, newOrderKey);
        } else if (oldOrder.side == LibOrder.Side.Bid) { // 出价（Bid）：调整 ETH 保证金（因价格 / 数量变化）
            // 计算旧订单剩余需支付的 ETH: oldRemainingPrice = 单价 * (总数量 - 已填充数量)
            uint256 oldRemainingPrice = Price.unwrap(oldOrder.price) *
                (oldOrder.nft.amount - oldFilledAmount);
            // 计算新订单需支付的 ETH: newRemainingPrice = 新单价 * 新总数量
            uint256 newRemainingPrice = Price.unwrap(newOrder.price) *
                newOrder.nft.amount;
            // 若新金额 > 旧金额，需补充差价（deltaBidPrice），并通过{value: deltaBidPrice}发送 ETH 到金库
            if (newRemainingPrice > oldRemainingPrice) {
                deltaBidPrice = newRemainingPrice - oldRemainingPrice;
                IEasySwapVault(_vault).editETH{value: uint256(deltaBidPrice)}(
                    oldOrderKey,
                    newOrderKey,
                    oldRemainingPrice,
                    newRemainingPrice,
                    oldOrder.maker
                );
            } else {
                // 调用金库的editETH函数更新记录
                IEasySwapVault(_vault).editETH(
                    oldOrderKey,
                    newOrderKey,
                    oldRemainingPrice,
                    newRemainingPrice,
                    oldOrder.maker
                );
            }
        }
        // 触发新订单创建事件 : 记录新订单的关键信息，供前端或其他合约追踪
        emit LogMake(
            newOrderKey,
            newOrder.side,
            newOrder.saleKind,
            newOrder.maker,
            newOrder.nft,
            newOrder.price,
            newOrder.expiry,
            newOrder.salt
        );
    }

    /**
        订单匹配:
        智能合约中处理订单匹配的核心逻辑实现，负责验证订单有效性、更新订单状态并执行资产（NFT 和 ETH）的转移

        核心逻辑框架:
        函数根据调用者身份（卖单制造者sellOrder.maker或买单制造者buyOrder.maker）分为两个主要分支，
        分别处理 “卖家接受买家出价” 和 “买家接受卖家要价” 两种场景，最终实现订单匹配和资产转移。
     */
    function _matchOrder(
        LibOrder.Order calldata sellOrder,
        LibOrder.Order calldata buyOrder,
        uint256 msgValue
    ) internal returns (uint128 costValue) {
        OrderKey sellOrderKey = LibOrder.hash(sellOrder);
        OrderKey buyOrderKey = LibOrder.hash(buyOrder);
        _isMatchAvailable(sellOrder, buyOrder, sellOrderKey, buyOrderKey);
        // 当调用者是卖单制造者 --》场景：卖家主动接受某个买家的出价（即 “卖单匹配买单”）
        if (_msgSender() == sellOrder.maker) {
            require(msgValue == 0, "HD: value > 0"); // 要求msgValue == 0：卖单匹配时无需附带 ETH（因为买家应已将资金存入金库）
            bool isSellExist = orders[sellOrderKey].order.maker != address(0); // check if sellOrder exist in order storage
            // 验证订单有效性：通过_validateOrder检查卖单（是否存在于存储中）和买单（是否在存储中有效）
            _validateOrder(sellOrder, isSellExist);
            _validateOrder(orders[buyOrderKey].order, false); 

            uint128 fillPrice = Price.unwrap(buyOrder.price); // the price of bid order
            if (isSellExist) {
                 //若卖单已存在于存储中（isSellExist == true），则移除该卖单（_removeOrder）并标记为 “删除”或者“完全填充”
                _removeOrder(sellOrder);
                //更新卖单的填充数量（_updateFilledAmount），记录匹配进度
                _updateFilledAmount(sellOrder.nft.amount, sellOrderKey); // sell order totally filled
            }
            //更新买单的填充数量（_updateFilledAmount），记录匹配进度
            _updateFilledAmount(filledAmount[buyOrderKey] + 1, buyOrderKey);
            // 通过LogMatch事件记录匹配详情（订单哈希、价格等）
            emit LogMatch(
                sellOrderKey,
                buyOrderKey,
                sellOrder,
                buyOrder,
                fillPrice
            );
            // -----------------------------资产转移--------------------------------
            // 从金库（_vault）提取买家预存的 ETH
            IEasySwapVault(_vault).withdrawETH(
                buyOrderKey,
                fillPrice,
                address(this)
            );
            //计算协议费用（protocolFee），将扣除费用后的 ETH 转给卖单制造者
            uint128 protocolFee = _shareToAmount(fillPrice, protocolShare);
            sellOrder.maker.safeTransferETH(fillPrice - protocolFee);
            // NFT 转移 --->若卖单在存储中，从金库提取 NFT 给买家；否则直接从卖家地址转 NFT 给买家
            if (isSellExist) {
                // 从金库提取 NFT 给买家
                IEasySwapVault(_vault).withdrawNFT(
                    sellOrderKey,
                    buyOrder.maker,
                    sellOrder.nft.collection,
                    sellOrder.nft.tokenId
                );
            } else {
                // 从卖家地址转 NFT 给买家
                IEasySwapVault(_vault).transferERC721(
                    sellOrder.maker,
                    buyOrder.maker,
                    sellOrder.nft
                );
            }
        } else if (_msgSender() == buyOrder.maker) { // 当调用者是买单制造者--->场景：买家主动接受某个卖家的要价（即 “买单匹配卖单”）
            bool isBuyExist = orders[buyOrderKey].order.maker != address(0); // 验证订单有效性：检查卖单（存储中状态）和买单（是否存在于存储中）
            _validateOrder(orders[sellOrderKey].order, false);
            _validateOrder(buyOrder, isBuyExist);

            uint128 buyPrice = Price.unwrap(buyOrder.price);
            uint128 fillPrice = Price.unwrap(sellOrder.price);
            // 价格校验：若买单不在存储中，要求附带的msgValue至少等于卖单价格；若买单在存储中，要求买单价格≥卖单价格
            if (!isBuyExist) {
                require(msgValue >= fillPrice, "HD: value < fill price"); // 若买单不在存储中，要求附带的msgValue至少等于卖单价格
            } else {
                // 若买单在存储中，要求买单价格≥卖单价格
                require(buyPrice >= fillPrice, "HD: buy price < fill price");
                // 从金库提取买家预存的 ETH
                IEasySwapVault(_vault).withdrawETH(
                    buyOrderKey,
                    buyPrice,
                    address(this)
                );
                // 若买单已存在于存储中（isBuyExist == true），则移除该买单并标记为 “已填充”或者“删除”
                _removeOrder(buyOrder);
                // 更新买单的填充数量
                _updateFilledAmount(filledAmount[buyOrderKey] + 1, buyOrderKey);
            }
            // 更新卖单的填充数量
            _updateFilledAmount(sellOrder.nft.amount, sellOrderKey);

            // 通过LogMatch事件记录匹配详情（订单哈希、价格等）
            emit LogMatch(
                buyOrderKey,
                sellOrderKey,
                buyOrder,
                sellOrder,
                fillPrice
            );
             // -----------------------------资产转移--------------------------------
            // 计算协议费用，将扣除费用后的 ETH 转给卖单制造者
            uint128 protocolFee = _shareToAmount(fillPrice, protocolShare);
            sellOrder.maker.safeTransferETH(fillPrice - protocolFee);
            // 若买单价格＞卖单价格，将差价转回给买家（多付部分退款）
            if (buyPrice > fillPrice) {
                buyOrder.maker.safeTransferETH(buyPrice - fillPrice);
            }
            // 从金库提取 NFT 给买家
            IEasySwapVault(_vault).withdrawNFT(
                sellOrderKey,
                buyOrder.maker,
                sellOrder.nft.collection,
                sellOrder.nft.tokenId
            );
            // 返回值设置：costValue根据买单是否存在，返回 0（已存买单）或买单价格（新买单）
            costValue = isBuyExist ? 0 : buyPrice;
        } else {
            revert("HD: sender invalid");
        }
    }
    /**
        验证卖单（sellOrder）和买单（buyOrder）是否能够进行匹配成交，确保两者在订单类型、资产信息、状态等方面符合交易规则
     */
    function _isMatchAvailable(
        LibOrder.Order memory sellOrder,
        LibOrder.Order memory buyOrder,
        OrderKey sellOrderKey,
        OrderKey buyOrderKey
    ) internal view {
        // 订单唯一性校验
        require(
            OrderKey.unwrap(sellOrderKey) != OrderKey.unwrap(buyOrderKey),
            "HD: same order"
        );
        // 订单方向校验
        require(
            sellOrder.side == LibOrder.Side.List &&
                buyOrder.side == LibOrder.Side.Bid,
            "HD: side mismatch"
        );
        // 卖单类型校验
        require(
            sellOrder.saleKind == LibOrder.SaleKind.FixedPriceForItem,
            "HD: kind mismatch"
        );
        // 创建者唯一性校验
        require(sellOrder.maker != buyOrder.maker, "HD: same maker");
        // 资产匹配校验  验证交易的资产是否匹配，支持两种场景：买单是 “集合固定价” 类型（FixedPriceForCollection）：可能表示买单愿意收购该集合中的任意 NFT
        // 买单和卖单的 NFT 完全一致：即同一合约（collection）下的同一 tokenId
        require( // check if the asset is the same
            buyOrder.saleKind == LibOrder.SaleKind.FixedPriceForCollection ||
                (sellOrder.nft.collection == buyOrder.nft.collection &&
                    sellOrder.nft.tokenId == buyOrder.nft.tokenId),
            "HD: asset mismatch"
        );
        // 订单状态校验  确保两个订单都处于可交易状态：卖单的已填充数量（filledAmount）小于总数量    买单的已填充数量小于总数量     若订单已完全填充（或取消），则无法继续匹配
        require(
            filledAmount[sellOrderKey] < sellOrder.nft.amount &&
                filledAmount[buyOrderKey] < buyOrder.nft.amount,
            "HD: order closed"
        );
    }

    /**
     计算协议费用
     * @notice caculate amount based on share.
     * @param total the total amount.
     * @param share the share in base point.
     */
    function _shareToAmount(
        uint128 total,
        uint128 share
    ) internal pure returns (uint128) {
        return (total * share) / LibPayInfo.TOTAL_SHARE;
    }
    //----------------------------1.权限控制：通过onlyOwner严格限制敏感操作，确保合约管理安全。
    //----------------------------2.安全防护：nonReentrant防重入、_checkDelegateCall防代理调用、零地址校验等机制，降低攻击风险。
    //----------------------------3.可升级兼容性：__gap的设置为未来合约升级预留了空间，适合需要迭代的复杂系统。
    //----------------------------4.事件追踪：关键操作（如提款）通过事件记录，便于链下监控和审计。
    /** 
        防代理调用校验
        作用：防止合约被通过delegatecall方式调用（一种特殊的合约调用方式，允许调用者借用当前合约的存储）。
        原理：self通常指向合约部署时的原始地址，而address(this)在delegatecall场景下会是调用者的地址。通过检查两者是否不同，确保合约未被代理调用，保护存储安全。
        使用场景：通常会在关键函数开头调用，防止恶意合约通过代理方式篡改存储
     */
    function _checkDelegateCall() private view {
        require(address(this) != self);
    }
    // 设置金库地址--->管理员操作函数  这些函数都带有onlyOwner修饰符，表明只有合约所有者才能调用，用于核心参数管理和系统控制
    function setVault(address newVault) public onlyOwner {
        require(newVault != address(0), "HD: zero address");
        _vault = newVault;
    }

    /**
        提取 ETH
        作用：将合约中的 ETH 提取到指定地址。
        安全机制：
            nonReentrant：防止重入攻击（避免在 ETH 转账回调中重复调用该函数）。
            onlyOwner：限制只有管理员能提取资金，防止未授权提款。
        交互：使用safeTransferETH（通常来自 OpenZeppelin 的安全库）安全转账 ETH，并通过LogWithdrawETH事件记录操作。
    */
    function withdrawETH(
        address recipient,
        uint256 amount
    ) external nonReentrant onlyOwner {
        recipient.safeTransferETH(amount);
        emit LogWithdrawETH(recipient, amount);
    }
    // 暂停与恢复合约：pause() / unpause()
    /**
        作用：临时暂停 / 恢复合约核心功能（通常继承自Pausable合约）。
        使用场景：当合约发现漏洞或异常时，管理员可暂停合约以防止资产损失，修复后再恢复
     */
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
        接收 ETH 的默认函数：receive()
        作用：允许合约接收 ETH 转账（当调用者未指定调用函数时触发）。
        特性：payable修饰符表明该函数可以接收 ETH，常用于接收退款、转账等场景
     */
    receive() external payable {}

    /**
        存储间隙：__gap
        作用：为合约升级预留存储位置，避免继承关系中存储变量冲突。
        原理：在使用代理模式升级合约时，新增的存储变量可能会覆盖原有变量。__gap占用 50 个uint256的存储槽，升级时可逐步替换这些位置，保证存储布局兼容。
     */
    uint256[50] private __gap;
}
