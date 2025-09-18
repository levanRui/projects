// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
/**
    支付信息与费用分成管理工具

    LibPayInfo 是一个用于管理支付信息和费用分成的 Solidity 库，主要定义了费用分配的核心数据结构、常量和哈希函数，
    适用于需要按比例分配资金的场景（如 NFT 交易中的平台手续费、创作者分成等）。

    四、设计亮点与应用场景
        1. 设计亮点
            基准点格式：使用 TOTAL_SHARE = 10000 作为基准，避免浮点数精度问题（Solidity 不支持浮点数），通过整数运算实现精确的比例计算（如 250 表示 2.5%）。
            安全限制：MAX_PROTOCOL_SHARE 限制平台最大分成比例，保护用户利益，防止过度收费。
            签名兼容：提供 TYPE_HASH 和 hash 函数，支持 EIP-712 结构化数据签名，便于在链下生成包含费用信息的订单，链上验证其合法性。
        2. 应用场景
            NFT 交易分成：在 NFT 交易中，将交易金额按比例分配给卖家、平台、创作者等，通过 PayInfo 数组记录多方收款信息（如 [平台, 创作者, 卖家] 各自的分成比例）。
            协议手续费管理：结合 ProtocolManager 合约（如之前解析的 ProtocolManager），动态调整平台分成比例，并通过 MAX_PROTOCOL_SHARE 限制调整范围。
            链下订单验证：在链下生成包含费用信息的订单，通过 hash 函数计算哈希并签名，链上验证签名时重新计算哈希，确保费用配置未被篡改。
    五、总结
        LibPayInfo 是一个轻量级但关键的工具库，通过标准化的费用分成数据结构和哈希功能，为区块链应用中的资金分配提供了安全、
        精确且可验证的解决方案。它特别适合需要多角色分成的场景（如 NFT 市场、去中心化交易所），确保费用分配透明、可审计且不易被篡改。
 */
library LibPayInfo {
    // 库中定义了两个关键常量，用于规范费用分成的比例范围：
    //total share in percentage, 10,000 = 100%
    uint128 public constant TOTAL_SHARE = 10000; //表示 100% 的分成比例（基准点，Basis Point），即 10000 = 100%，1 = 0.01%。
    uint128 public constant MAX_PROTOCOL_SHARE = 1000;//协议（平台）可收取的最大分成比例，即 1000/10000 = 10%，防止平台设置过高手续费。
    //是 PayInfo 结构体的类型哈希，由结构体字段的类型和名称通过 keccak256 计算得出，用于唯一标识结构体类型，防止哈希碰撞
    bytes32 public constant TYPE_HASH =keccak256("PayInfo(address receiver,uint96 share)");
    /**
        PayInfo 结构体：支付信息与分成配置                                  
        作用：记录一笔资金分配的接收方和对应的分成比例。
        示例：若某笔交易手续费为 1 ETH，PayInfo 中 receiver 为平台地址，share 为 250（即 2.5%），则平台分得 0.025 ETH。
     */
    struct PayInfo {
        address payable receiver;// 收款地址（ payable 表示可接收 ETH）
        uint96 share;// 分成比例（基准点格式，基于 TOTAL_SHARE）
    }
    /**
        计算 PayInfo 实例的哈希值，用于链下签名和链上验证（如验证订单中包含的费用分成配置是否被篡改）。
        哈希过程：先通过 abi.encode 打包 TYPE_HASH、接收地址和分成比例，再用 keccak256 计算最终哈希
     */
    function hash(PayInfo memory info) internal pure returns (bytes32) {
        return keccak256(abi.encode(TYPE_HASH, info.receiver, info.share));
    }
}
