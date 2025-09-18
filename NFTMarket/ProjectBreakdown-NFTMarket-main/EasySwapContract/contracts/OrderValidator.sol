// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";

import {Price} from "./libraries/RedBlackTreeLibrary.sol";
import {LibOrder, OrderKey} from "./libraries/LibOrder.sol";

/**
 * 这个OrderValidator抽象合约是一个可升级合约，主要负责订单的有效性验证、填充状态管理和取消操作。它基于 OpenZeppelin 的升级合约框架，并集成了 EIP-712 标准用于安全的签名验证
 */
abstract contract OrderValidator is
    Initializable,
    ContextUpgradeable,
    EIP712Upgradeable
{
    bytes4 private constant EIP_1271_MAGIC_VALUE = 0x1626ba7e;

    uint256 private constant CANCELLED = type(uint256).max;

    // fillsStat record orders filled status, key is the order hash,
    // and value is filled amount.
    // Value CANCELLED means the order has been canceled.
    mapping(OrderKey => uint256) public filledAmount;

    function __OrderValidator_init(
        string memory EIP712Name,
        string memory EIP712Version
    ) internal onlyInitializing {
        __Context_init();
        __EIP712_init(EIP712Name, EIP712Version);
        __OrderValidator_init_unchained();
    }

    function __OrderValidator_init_unchained() internal onlyInitializing {}

    /**
      检查订单有效性
     * @notice Validate order parameters.
     * @param order  Order to validate.
     * @param isSkipExpiry  Skip expiry check if true.
     */
    function _validateOrder(
        LibOrder.Order memory order,
        bool isSkipExpiry //是否跳过有效期检查的标志
    ) internal view {
        // 检查订单必须有一个有效的 maker（创建者）地址，不能是零地址
        require(order.maker != address(0), "OVa: miss maker");
        // Order must be started and not be expired.
        //如果不跳过有效期检查，则验证订单要么永不过期（expiry 为 0），要么尚未过期（expiry 大于当前区块时间）
        if (!isSkipExpiry) { // Skip expiry check if true.
            require(
                order.expiry == 0 || order.expiry > block.timestamp,
                "OVa: expired"
            );
        }
        // 订单的 salt（随机数）不能为 0，用于防止订单哈希碰撞
        require(order.salt != 0, "OVa: zero salt");
        //根据订单方向（side）进行不同验证
        if (order.side == LibOrder.Side.List) {
            //对于挂单（List）：检查 NFT 集合地址是否有效（非零地址）
            require(
                order.nft.collection != address(0),
                "OVa: unsupported nft asset"
            );
        } else if (order.side == LibOrder.Side.Bid) {
            //对于买单（Bid）：检查订单价格必须大于 0
            require(Price.unwrap(order.price) > 0, "OVa: zero price");
        }
    }

    /**
     * @notice 获取订单填充量.
     * @param orderKey  The hash of the order.
     * @return orderFilledAmount Has completed fill amount of sell order (0 if order is unfilled).
     */
    function _getFilledAmount(
        OrderKey orderKey
    ) internal view returns (uint256 orderFilledAmount) {
        // Get has completed fill amount.
        orderFilledAmount = filledAmount[orderKey];
        // Cancelled order cannot be matched.
        require(orderFilledAmount != CANCELLED, "OVa: canceled");
    }

    /**
     * @notice 更新订单填充量.
     * @param newAmount  New fill amount of order.
     * @param orderKey  The hash of the order.
     */
    function _updateFilledAmount(
        uint256 newAmount,
        OrderKey orderKey
    ) internal {
        require(newAmount != CANCELLED, "OVa: canceled");
        filledAmount[orderKey] = newAmount;
    }

    /**
     *取消后的订单无法恢复，filledAmount被永久设为CANCELLED，后续匹配会失败
     * @notice Cancel order.
     * @dev Cancelled orders cannot be reopened.
     * @param orderKey  The hash of the order.
     */
    function _cancelOrder(OrderKey orderKey) internal {
        filledAmount[orderKey] = CANCELLED;
    }
    // __gap预留 50 个存储槽，防止升级时存储布局冲突
    uint256[50] private __gap;
}
