// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Price} from "./RedBlackTreeLibrary.sol";

/**
    --------整体设计思路----
    这些结构体共同构建了 NFT 交易协议的核心数据模型：
    1.使用Order存储基础订单信息
    2.通过DBOrder和OrderQueue实现了高效的订单存储和价格队列管理
    3.提供EditDetail支持订单修改功能
    4.用MatchDetail记录交易匹配结果
    这种设计考虑了订单管理的效率（通过链表和队列）、功能完整性（支持创建、编辑、匹配）和数据一致性（原子化操作结构），非常适合 NFT 交易场景中可能出现的高频订单操作和复杂匹配逻辑。

    ----------整体代码--------------------
    这段代码通过标准化哈希计算（EIP-712）、定义唯一订单标识（OrderKey）和哨兵值，为 NFT 交易协议提供了核心基础能力：
    (1)订单唯一性：通过 Order 全字段哈希生成 OrderKey，确保每个订单有唯一标识。
    (2)数据可验证性：EIP-712 哈希支持链下签名 + 链上验证，确保订单未被篡改。
    (3)结构管理：哨兵值和判断函数简化了订单链表 / 队列（如 OrderQueue）的遍历和边界判断。
    这些设计是 NFT 交易协议中 "订单管理" 模块的核心，为后续的订单创建、修改、匹配、取消等操作提供了统一的标识和验证标准。
 */
type OrderKey is bytes32;

library LibOrder {
    // 订单方向，通常是枚举类型（如 Bid 表示出价，Ask 表示卖出）
    enum Side {
        List,//挂牌
        Bid // 出价
    }
    // 销售类型，可能包括固定价格、拍卖等不同的交易模式
    enum SaleKind {
        FixedPriceForCollection,//针对整个藏品的固定价格销售
        FixedPriceForItem//针对单个物品的固定价格销售
    }

    // 资产结构
    struct Asset {
        uint256 tokenId; //代币 ID，标识某个特定 NFT
        address collection;//藏品合约地址，指示该 NFT 所属的藏品
        uint96 amount; //数量，使用 uint96 类型（可能用于表示价格或数量）
    }

    //表示 NFT 的基本信息
    struct NFTInfo {
        address collection; //藏品合约地址
        uint256 tokenId;//代币 ID
    }

    struct Order {
        Side side;  //订单方向，通常是枚举类型（如 Bid 表示买入，Ask 表示卖出）
        SaleKind saleKind; // 销售类型，可能包括固定价格、拍卖等不同的交易模式
        address maker; //订单创建者（ maker ）的地址  记录谁创建了这个订单
        Asset nft; //交易的 NFT 资产信息  包含 NFT 合约地址、token ID、数量等信息（需要查看 Asset 结构体定义）
        Price price; // unit price of nft
        uint64 expiry; // 订单的过期时间戳 超过这个时间后，订单将不再有效
        uint64 salt; //随机数，用于确保订单的唯一性   在生成订单哈希时通常会用到，防止相同参数的订单产生相同的哈希值
    }
    //用于在合约存储中管理订单，是订单在数据库式存储中的表示
    struct DBOrder {
        Order order; //包含订单的核心信息（方向、价格、创建者等）
        OrderKey next;//指向下一个订单的键，用于构建链表结构，方便订单的遍历和管理
    }

    /// @dev Order queue: used to store orders of the same price
    //管理相同价格的订单队列（注释已说明：used to store orders of the same price）
    //结合DBOrder的next字段，这个结构可以实现一个完整的队列：
    //从head开始，通过next指针遍历到tail
    //相同价格的订单会被组织在同一个队列中，这对订单匹配和价格排序非常重要
    struct OrderQueue {
        OrderKey head;//队列头部订单的键（第一个订单）
        OrderKey tail;//队列尾部订单的键（最后一个订单）
    }
    

    //用于处理订单编辑操作的详细信息  ---> 这种设计使得订单编辑操作可以原子化地进行，确保旧订单被正确移除并替换为新订单。
    struct EditDetail {
        OrderKey oldOrderKey; // 标识需要被修改或替换的旧订单
        LibOrder.Order newOrder; // 新的订单信息，将替代旧订单
    }

    //记录一笔成功匹配的交易详情 ---> 当一个卖单和买单成功匹配并完成交易时，这个结构可以完整记录交易双方的订单信息，用于后续的事件记录、结算或审计。
    struct MatchDetail {
        LibOrder.Order sellOrder; //卖单信息
        LibOrder.Order buyOrder; //买单信息

    }
    /**
        作用：定义一个 "哨兵值"（Sentinel Value），作为订单键（OrderKey）的特殊标记。
        含义：0x0 通常表示 "空" 或 "终止"，在之前的 makeOrders 函数中，已用它来判断订单是否创建成功（若订单键为哨兵值，则表示创建失败）。
        使用场景：在订单链表（如 DBOrder 的 next 字段）中，哨兵值可作为链表的终止标记（类似链表的 null）
     */
    OrderKey public constant ORDERKEY_SENTINEL = OrderKey.wrap(0x0);

    /**
        背景：这是遵循 EIP-712 标准的结构化数据哈希定义。EIP-712 用于规范链上 / 链下数据的签名格式，确保签名的可读性和安全性（避免对随机哈希值签名）。
        作用：
            ASSET_TYPEHASH：Asset 结构体的类型哈希，由结构体名称和字段类型拼接后哈希得到，用于标准化 Asset 数据的哈希计算。
            ORDER_TYPEHASH：Order 结构体的类型哈希，包含 Order 自身的字段类型，以及嵌套的 Asset 结构体的类型定义（因为 Order 中包含 Asset nft 字段）。
        意义：类型哈希确保了相同结构的不同数据能生成唯一且可验证的哈希，为后续的订单签名、验证提供基础
     */
    bytes32 public constant ASSET_TYPEHASH =
        keccak256("Asset(uint256 tokenId,address collection,uint96 amount)");

    bytes32 public constant ORDER_TYPEHASH =
        keccak256(
            "Order(uint8 side,uint8 saleKind,address maker,Asset nft,uint128 price,uint64 expiry,uint64 salt)Asset(uint256 tokenId,address collection,uint96 amount)"
        );


    //哈希计算函数----Asset 结构体哈希
    /**
        功能：计算 Asset 结构体的哈希值，遵循 EIP-712 标准。
        过程：用 abi.encode 拼接 ASSET_TYPEHASH 和 Asset 的所有字段（tokenId、collection、amount），再对结果进行 keccak256 哈希。
        用途：Asset 是 Order 的嵌套字段，其哈希会被用于计算整个 Order 的哈希
     */
    function hash(Asset memory asset) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    ASSET_TYPEHASH,
                    asset.tokenId,
                    asset.collection,
                    asset.amount
                )
            );
    }
    //哈希计算函数----Order 结构体哈希（生成 OrderKey）
    /**
        功能：计算 Order 结构体的哈希值，并将其包装为 OrderKey 类型（订单的唯一标识）。
        过程：
            拼接 ORDER_TYPEHASH、Order 的所有字段（side、saleKind 等）。
            其中 order.nft 字段通过上面的 hash(Asset) 函数计算哈希后传入。
            用 keccak256 对拼接结果哈希，再通过 OrderKey.wrap 转换为 OrderKey 类型。
        核心意义：
        OrderKey 本质上是订单的唯一哈希标识，通过订单的所有字段计算得出，确保 " 相同订单参数生成相同 OrderKey，不同参数生成不同 OrderKey"。
        这为订单的存储（如 DBOrder）、查询、验证提供了唯一标识。
     */
    function hash(Order memory order) internal pure returns (OrderKey) {
        return
            OrderKey.wrap(
                keccak256(
                    abi.encodePacked(
                        ORDER_TYPEHASH,
                        order.side,
                        order.saleKind,
                        order.maker,
                        hash(order.nft),
                        Price.unwrap(order.price),
                        order.expiry,
                        order.salt
                    )
                )
            );
    }
    //哨兵值判断函数
    /**
        功能：判断一个 OrderKey 是否为哨兵值（ORDERKEY_SENTINEL）。
    使用场景：
        在遍历订单链表时，用 isSentinel 判断是否到达链表末尾（如 DBOrder.next 为哨兵值时，表示没有下一个订单）。
        在订单创建 / 匹配逻辑中，用 isNotSentinel 验证订单是否有效（如之前 makeOrders 中判断订单是否创建成功）。
     */
    function isSentinel(OrderKey orderKey) internal pure returns (bool) {
        return OrderKey.unwrap(orderKey) == OrderKey.unwrap(ORDERKEY_SENTINEL);
    }

    function isNotSentinel(OrderKey orderKey) internal pure returns (bool) {
        return OrderKey.unwrap(orderKey) != OrderKey.unwrap(ORDERKEY_SENTINEL);
    }
}
