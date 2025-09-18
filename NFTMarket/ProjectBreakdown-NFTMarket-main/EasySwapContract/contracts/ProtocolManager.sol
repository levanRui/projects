// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {LibPayInfo} from "./libraries/LibPayInfo.sol";
/**
    ProtocolManager抽象合约是一个可升级合约（基于 OpenZeppelin 的升级模式），
    主要用于管理协议的费用分成比例（protocolShare）。它提供了初始化、设置和验证协议分成比例的核心功能，同时遵循可升级合约的设计规范。
 */
abstract contract ProtocolManager is
    Initializable,
    OwnableUpgradeable
{
    uint128 public protocolShare;// 存储协议的分成比例（如手续费百分比），使用uint128类型既节省存储空间，又能满足常规比例数值范围需求
    // 当协议分成比例更新时触发，记录新的比例值，便于链下跟踪和审计。
    event LogUpdatedProtocolShare(uint128 indexed newProtocolShare);
    // 可升级合约不使用传统构造函数，而是通过__{ContractName}_init模式进行初始化
    /**
        内部初始化函数，带有onlyInitializing修饰符，确保只能在合约部署或首次升级时调用。
        可根据需要取消注释__Ownable_init，初始化所有权（默认所有者为部署者）。
        调用__ProtocolManager_init_unchained执行具体初始化逻辑（分离初始化逻辑的标准写法）。
     */
    function __ProtocolManager_init(
        uint128 newProtocolShare
    ) internal onlyInitializing {
        // __Ownable_init(_msgSender());
        __ProtocolManager_init_unchained(
            newProtocolShare
        );
    }

    /**
        实际执行初始化的函数，调用_setProtocolShare设置初始的协议分成比例。
        命名中的_unchained表示该函数不依赖其他父合约的初始化，是可升级合约的规范写法。
     */
    function __ProtocolManager_init_unchained(
        uint128 newProtocolShare
    ) internal onlyInitializing {
        _setProtocolShare(newProtocolShare);
    }
    //（外部函数） 允许合约所有者更新协议分成比例，带有onlyOwner修饰符，确保权限安全。实际逻辑委托给内部函数_setProtocolShare
    function setProtocolShare(
        uint128 newProtocolShare
    ) external onlyOwner {
        _setProtocolShare(newProtocolShare);
    }
    /**
        （内部函数）
        执行协议分成比例的验证和更新：
        校验：确保新比例不超过LibPayInfo中定义的最大值（MAX_PROTOCOL_SHARE），防止设置不合理的高比例。
        更新：将protocolShare设为新值。
        事件：触发LogUpdatedProtocolShare记录变更。
     */
    function _setProtocolShare(uint128 newProtocolShare) internal {
        require(
            newProtocolShare <= LibPayInfo.MAX_PROTOCOL_SHARE,
            "PM: exceed max protocol share"
        );
        protocolShare = newProtocolShare;
        emit LogUpdatedProtocolShare(newProtocolShare);
    }
    // 存储间隙，为合约升级预留 50 个uint256的存储槽，避免升级时因新增变量导致的存储布局冲突（可升级合约的标准实践）
    uint256[50] private __gap;
}
