// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

// import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {RedBlackTreeLibrary, Price} from "./libraries/RedBlackTreeLibrary.sol";// 提供红黑树数据结构，用于按价格排序订单（支持快速查询、插入、删除）
import {LibOrder, OrderKey} from "./libraries/LibOrder.sol"; // 定义订单相关数据结构（如Order、DBOrder、OrderQueue）和工具函数（如订单哈希、哨兵值判断）。

error CannotInsertDuplicateOrder(OrderKey orderKey); // 插入重复订单时触发（通过订单唯一键orderKey判断）
/**
    OrderStorage 是一个可升级的订单存储管理合约，核心用于 NFT 交易场景中订单的结构化存储、高效查询、添加与删除。
    它通过红黑树（Red-Black Tree） 实现价格排序，结合队列（Queue） 管理同一价格下的订单，
    确保订单匹配时能快速定位最优价格，并按创建顺序处理订单，兼顾效率与公平性
 */
contract OrderStorage is Initializable {
    using RedBlackTreeLibrary for RedBlackTreeLibrary.Tree;

    ///存储所有订单的完整信息，以订单唯一键orderKey（订单哈希）为索引。DBOrder包含订单数据（Order）和下一个订单的键（next）
    mapping(OrderKey => LibOrder.DBOrder) public orders;

    //按「NFT 集合地址 + 订单方向」存储价格红黑树。- 键 1：NFT 集合地址（address）；- 键 2：订单方向（Side.Bid买单 / Side.List卖单）；- 值：红黑树，按价格排序，快速获取最优价格。
    mapping(address => mapping(LibOrder.Side => RedBlackTreeLibrary.Tree))
        public priceTrees;

    //按「NFT 集合地址 + 订单方向 + 价格」存储订单队列。- 同一价格下的订单按创建顺序排成队列，保证 “先到先得”；- OrderQueue包含队列头（head）和尾（tail）的orderKey。
    mapping(address => mapping(LibOrder.Side => mapping(Price => LibOrder.OrderQueue)))
        public orderQueues;

    function __OrderStorage_init() internal onlyInitializing {}

    function __OrderStorage_init_unchained() internal onlyInitializing {}
    // 工具函数：onePlus  作用：高效实现整数 + 1 操作，因uint256溢出在 Solidity 0.8.x 中会自动 revert，此处用unchecked减少 gas 消耗（适用于确定不会溢出的场景，如订单计数）
    function onePlus(uint256 x) internal pure returns (uint256) {
        unchecked {
            return 1 + x; // 无溢出检查，用于安全递增计数器
        }
    }
    //---------------价格查询：获取最优 / 次优价格: 红黑树支持 O (log n) 时间复杂度的价格排序，核心用于快速定位匹配优先级最高的订单------------------------------------
    // 获取当前最优价格--->逻辑：根据订单方向，从红黑树中取极值（买单取最高，卖单取最低），对应 “最优匹配价格”
    function getBestPrice(
        address collection,
        LibOrder.Side side
    ) public view returns (Price price) {
        price = (side == LibOrder.Side.Bid)
            ? priceTrees[collection][side].last() // 买单：最优价格是最高价格（红黑树最后一个节点）
            : priceTrees[collection][side].first();// 卖单：最优价格是最低价格（红黑树第一个节点）
    }
    //获取次优价格-->作用：当最优价格订单无法匹配（如已填满）时，快速获取下一个优先级的价格
    function getNextBestPrice(
        address collection,
        LibOrder.Side side,
        Price price
    ) public view returns (Price nextBestPrice) {
        if (RedBlackTreeLibrary.isEmpty(price)) { // 若输入价格无效，直接返回最优价格
            nextBestPrice = (side == LibOrder.Side.Bid)
                ? priceTrees[collection][side].last()
                : priceTrees[collection][side].first();
        } else {
            nextBestPrice = (side == LibOrder.Side.Bid)
                ? priceTrees[collection][side].prev(price)// 买单：次优价格是当前价格的前一个（更低但仅次于当前）
                : priceTrees[collection][side].next(price);//卖单：次优价格是当前价格的后一个（更高但仅次于当前）
        }
    }
    //------------------------------------------------- 订单操作---------------------------------------------
    // 核心逻辑：生成订单唯一键 → 检查重复 → 插入价格到红黑树 → 插入订单到对应队列
    // 关键设计：(1)订单唯一键由LibOrder.hash生成（基于订单核心参数，确保唯一性） (2)同一价格的订单按FIFO（先进先出） 排列，通过队列tail指针插入尾部，保证公平性。
    function _addOrder(
        LibOrder.Order memory order
    ) internal returns (OrderKey orderKey) {
        // 1. 生成订单唯一键（通过LibOrder.hash计算订单哈希）
        orderKey = LibOrder.hash(order);
        // 2. 检查订单是否已存在（通过maker地址是否为零判断）
        if (orders[orderKey].order.maker != address(0)) {
            revert CannotInsertDuplicateOrder(orderKey);
        }

        // 3. 若价格未在红黑树中，插入价格（确保价格排序）
        RedBlackTreeLibrary.Tree storage priceTree = priceTrees[
            order.nft.collection
        ][order.side];
        if (!priceTree.exists(order.price)) {
            priceTree.insert(order.price);
        }

        // 4. 插入订单到对应价格的队列
        LibOrder.OrderQueue storage orderQueue = orderQueues[
            order.nft.collection
        ][order.side][order.price];
        // 4.1 若队列为空（head是哨兵值），初始化队列
        if (LibOrder.isSentinel(orderQueue.head)) { // 队列是否初始化
            orderQueues[order.nft.collection][order.side][ // 创建新的队列
                order.price
            ] = LibOrder.OrderQueue(
                LibOrder.ORDERKEY_SENTINEL,
                LibOrder.ORDERKEY_SENTINEL
            );
            orderQueue = orderQueues[order.nft.collection][order.side][
                order.price
            ];
        }
        // 4.2 若队列无订单（tail是哨兵值），直接设为头和尾
        if (LibOrder.isSentinel(orderQueue.tail)) { // 队列是否为空
            orderQueue.head = orderKey;
            orderQueue.tail = orderKey;
            orders[orderKey] = LibOrder.DBOrder( // 创建新的订单，插入队列， 下一个订单为sentinel
                order,
                LibOrder.ORDERKEY_SENTINEL
            );
        } else { 
            // 4.3 队列非空，插入到尾部（保持创建顺序）
            orders[orderQueue.tail].next = orderKey; // 将新订单插入队列尾部
            orders[orderKey] = LibOrder.DBOrder(
                order,
                LibOrder.ORDERKEY_SENTINEL
            );
            orderQueue.tail = orderKey;
        }
    }
    // -----------------------------------------------删除指定订单 --------------------------------------------------
    //核心逻辑：定位订单队列 → 遍历查找目标订单 → 调整队列指针 → 清理空队列与红黑树价格。
    function _removeOrder(
        LibOrder.Order memory order
    ) internal returns (OrderKey orderKey) {
        //1. 定位到订单对应的队列（集合+方向+价格）
        LibOrder.OrderQueue storage orderQueue = orderQueues[
            order.nft.collection
        ][order.side][order.price];
        orderKey = orderQueue.head;
        OrderKey prevOrderKey;//记录前一个订单的键
        bool found;
        //2. 遍历队列查找目标订单（匹配maker、saleKind、expiry等核心参数）
        while (LibOrder.isNotSentinel(orderKey) && !found) {
            LibOrder.DBOrder memory dbOrder = orders[orderKey];
            if (
                (dbOrder.order.maker == order.maker) &&
                (dbOrder.order.saleKind == order.saleKind) &&
                (dbOrder.order.expiry == order.expiry) &&
                (dbOrder.order.salt == order.salt) &&
                (dbOrder.order.nft.tokenId == order.nft.tokenId) &&
                (dbOrder.order.nft.amount == order.nft.amount)
            ) {
                // 3. 找到订单，调整队列指针
                OrderKey temp = orderKey;
                // emit OrderRemoved(order.nft.collection, orderKey, order.maker, order.side, order.price, order.nft, block.timestamp);
                if ( OrderKey.unwrap(orderQueue.head) ==OrderKey.unwrap(orderKey)) {
                    orderQueue.head = dbOrder.next;// 若删除头节点，更新head为下一个订单
                } else {
                    orders[prevOrderKey].next = dbOrder.next;// 非头节点，更新前一个订单的next
                }
                if (OrderKey.unwrap(orderQueue.tail) ==OrderKey.unwrap(orderKey)) {
                    orderQueue.tail = prevOrderKey;// 若删除尾节点，更新tail为前一个订单
                }
                prevOrderKey = orderKey;
                orderKey = dbOrder.next;
                delete orders[temp];
                found = true;
            } else {
                 // 4. 删除订单记录
                prevOrderKey = orderKey;
                orderKey = dbOrder.next;
            }
        }
        // 5. 若队列空了，清理队列和红黑树中的价格
        if (found) {
            if (LibOrder.isSentinel(orderQueue.head)) {
                delete orderQueues[order.nft.collection][order.side][ order.price];// 删除空队列
                RedBlackTreeLibrary.Tree storage priceTree = priceTrees[order.nft.collection][order.side];
                if (priceTree.exists(order.price)) {
                    priceTree.remove(order.price);// 从红黑树删除无订单的价格
                }
            }
        } else {
            revert("Cannot remove missing order");// 未找到订单，抛出错误
        }
    }
    //--------------------------------------------------订单查询：批量查询与最优订单查询------------------------------------
    /**
        多条件批量查询订单  -->核心应用：前端展示订单列表（如 “当前 NFT 的所有卖单”），支持分页和筛选
     */
    function getOrders(
        address collection,
        uint256 tokenId,
        LibOrder.Side side,
        LibOrder.SaleKind saleKind,
        uint256 count,// 最大返回数量
        Price price,// 价格上限/下限
        OrderKey firstOrderKey// 起始订单键（用于分页）
    ) external view returns (LibOrder.Order[] memory resultOrders, OrderKey nextOrderKey){
        resultOrders = new LibOrder.Order[](count);
        // 1. 确定起始价格（若未指定，取最优价格）
        if (RedBlackTreeLibrary.isEmpty(price)) {
            price = getBestPrice(collection, side);
        } else {
            if (LibOrder.isSentinel(firstOrderKey)) {
                price = getNextBestPrice(collection, side, price);
            }
        }
        // 2. 遍历红黑树中的价格，收集符合条件的订单
        uint256 i;
        while (RedBlackTreeLibrary.isNotEmpty(price) && i < count) {
            LibOrder.OrderQueue memory orderQueue = orderQueues[collection][ side][price];
            OrderKey orderKey = orderQueue.head;
             // 2.1 若指定起始订单键，跳转到该订单
            if (LibOrder.isNotSentinel(firstOrderKey)) {
                while (
                    LibOrder.isNotSentinel(orderKey) &&
                    OrderKey.unwrap(orderKey) != OrderKey.unwrap(firstOrderKey)
                ) {
                    LibOrder.DBOrder memory order = orders[orderKey];
                    orderKey = order.next;
                }
                firstOrderKey = LibOrder.ORDERKEY_SENTINEL;// 重置，避免重复跳转
            }
            // 2.2 遍历队列，收集有效订单
            while (LibOrder.isNotSentinel(orderKey) && i < count) {
                LibOrder.DBOrder memory dbOrder = orders[orderKey];
                orderKey = dbOrder.next;
                // 过滤过期订单
                if ((dbOrder.order.expiry != 0 &&dbOrder.order.expiry < block.timestamp)) {
                    continue;
                }
                // 过滤不符合交易类型/TokenId的订单（如集合级买单不匹配单品订单）
                if ((side == LibOrder.Side.Bid) &&(saleKind == LibOrder.SaleKind.FixedPriceForCollection)) {
                    if ((dbOrder.order.side == LibOrder.Side.Bid) &&(dbOrder.order.saleKind == LibOrder.SaleKind.FixedPriceForItem)) {
                        continue;
                    }
                }

                if ((side == LibOrder.Side.Bid) && (saleKind == LibOrder.SaleKind.FixedPriceForItem)) {
                    if ((dbOrder.order.side == LibOrder.Side.Bid) &&(dbOrder.order.saleKind ==LibOrder.SaleKind.FixedPriceForItem) &&(tokenId != dbOrder.order.nft.tokenId)) {
                        continue;
                    }
                }
                // 收集订单，记录下一个订单键（用于分页）
                resultOrders[i] = dbOrder.order;
                nextOrderKey = dbOrder.next;
                i = onePlus(i);
            }
             // 3. 处理下一个价格
            price = getNextBestPrice(collection, side, price);
        }
    }

    /**
     获取最优可交易订单: 按价格优先级，返回第一个符合条件的有效订单（未过期、匹配筛选条件）
     核心应用：订单匹配逻辑中，快速找到 “最优对手单”（如用户挂单时，自动匹配当前最优价格的买单 / 卖单）
     */
    function getBestOrder(
        address collection,
        uint256 tokenId,
        LibOrder.Side side,
        LibOrder.SaleKind saleKind
    ) external view returns (LibOrder.Order memory orderResult) {
        Price price = getBestPrice(collection, side);
        // 遍历价格（从最优到次优）
        while (RedBlackTreeLibrary.isNotEmpty(price)) {
            LibOrder.OrderQueue memory orderQueue = orderQueues[collection][side][price];
            OrderKey orderKey = orderQueue.head;
            //遍历队列，查找第一个有效订单
            while (LibOrder.isNotSentinel(orderKey)) {
                LibOrder.DBOrder memory dbOrder = orders[orderKey];
                // 过滤不符合条件的订单（同getOrders逻辑）
                if ((side == LibOrder.Side.Bid) &&(saleKind == LibOrder.SaleKind.FixedPriceForItem)) {
                    if ((dbOrder.order.side == LibOrder.Side.Bid) &&(dbOrder.order.saleKind ==LibOrder.SaleKind.FixedPriceForItem) &&(tokenId != dbOrder.order.nft.tokenId)) {
                        orderKey = dbOrder.next;
                        continue;
                    }
                }

                if ((side == LibOrder.Side.Bid) &&(saleKind == LibOrder.SaleKind.FixedPriceForCollection)) {
                    if ((dbOrder.order.side == LibOrder.Side.Bid) &&(dbOrder.order.saleKind ==LibOrder.SaleKind.FixedPriceForItem)) {
                        orderKey = dbOrder.next;
                        continue;
                    }
                }
                // 过滤过期订单，找到有效订单后直接返回
                if ((dbOrder.order.expiry == 0 ||dbOrder.order.expiry > block.timestamp)) {
                    orderResult = dbOrder.order;
                    break;
                }
                orderKey = dbOrder.next;
            }
            // 找到有效订单后退出循环
            if (Price.unwrap(orderResult.price) > 0) {
                break;
            }
            price = getNextBestPrice(collection, side, price);
        }
    }
    // 可升级合约存储间隙，预留 50 个存储槽，避免升级时因新增变量导致存储布局冲突。
    uint256[50] private __gap;
}
