// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {LibTransferSafeUpgradeable, IERC721} from "./libraries/LibTransferSafeUpgradeable.sol";//提供安全的 ETH 和 ERC721 转账工具函数（如safeTransferETH、safeTransferNFT），避免转账失败导致的资产锁定。
import {LibOrder, OrderKey} from "./libraries/LibOrder.sol";//定义订单相关数据结构（如OrderKey订单唯一键、Asset资产信息、NFTInfo NFT 详情）

import {IEasySwapVault} from "./interface/IEasySwapVault.sol";//金库合约的接口规范，约束外部可调用的函数签名
/**
    NFT 与 ETH 资产托管金库

    EasySwapVault 是一个专为 NFT 交易场景设计的资产托管合约，
    核心功能是安全管理用户用于交易的 ETH 和 NFT 资产，仅允许授权的订单簿合约（orderBook）触发资产操作，实现资产托管与交易逻辑的隔离，提升系统安全性。
 */
contract EasySwapVault is IEasySwapVault, OwnableUpgradeable {
    using LibTransferSafeUpgradeable for address;
    using LibTransferSafeUpgradeable for IERC721;

    address public orderBook;//授权的订单簿合约地址，仅该地址可调用资产操作函数
    mapping(OrderKey => uint256) public ETHBalance;//记录每个订单（通过OrderKey索引）在金库中托管的 ETH 余额。
    mapping(OrderKey => uint256) public NFTBalance;//记录每个订单在金库中托管的 NFT 的tokenId（因单个订单通常对应单个 NFT，用tokenId直接关联）。

    //核心权限控制 -->onlyEasySwapOrderBook 修饰符: 限制所有资产操作函数（如存提 ETH/NFT、修改订单资产）仅能由授权的订单簿合约（orderBook）调用，防止未授权地址直接操作资产
    modifier onlyEasySwapOrderBook() {
        require(msg.sender == orderBook, "HV: only EasySwap OrderBook");
        _;
    }

    function initialize() public initializer {
        __Ownable_init(_msgSender());// 初始化所有权，将部署者设为合约所有者
    }
    //设置订单簿地址-->仅合约所有者可调用，用于绑定订单簿合约（如部署新订单簿后更新授权地址），是资产安全的关键配置
    function setOrderBook(address newOrderBook) public onlyOwner {
        require(newOrderBook != address(0), "HV: zero address");// 禁止设置零地址
        orderBook = newOrderBook;// 更新授权的订单簿地址
    }
    //--------------------------------------------------------------核心功能：资产托管与操作----------------------------------------------------------
    /**
        合约按资产类型（ETH、NFT）和操作场景（存、提、修改、转移）分为多个核心函数，所有资产操作均需通过订单簿合约触发。
     */
     //查询订单 ETH 余额
    function balanceOf(
        OrderKey orderKey
    ) external view returns (uint256 ETHAmount, uint256 tokenId) {
        ETHAmount = ETHBalance[orderKey];// 返回订单托管的ETH金额
        tokenId = NFTBalance[orderKey];// 同时返回托管的NFT tokenId（便于批量查询）
    }

    //---------------------------------------------------1.ETH 资产管理---------------------------------------------
    /**
        存入 ETH功能
        场景：用户创建买单（Bid）时，订单簿调用此函数将用户的 ETH 转入金库托管。
        安全：通过msg.value校验实际转入金额，避免金额不匹配。
     */
    function depositETH(
        OrderKey orderKey,
        uint256 ETHAmount
    ) external payable onlyEasySwapOrderBook {
        require(msg.value >= ETHAmount, "HV: not match ETHAmount");// 校验转入ETH金额不小于托管金额
        ETHBalance[orderKey] += msg.value;// 累加订单的ETH托管余额
    }
    /**
        提取 ETH功能
        场景：订单取消、交易失败或用户提取未成交资金时，订单簿调用此函数将 ETH 退回用户
     */
    function withdrawETH(
        OrderKey orderKey,
        uint256 ETHAmount,
        address to
    ) external onlyEasySwapOrderBook {
        ETHBalance[orderKey] -= ETHAmount;
        to.safeTransferETH(ETHAmount);
    }
    /** 
        修改订单 ETH 托管功能
        场景：用户修改买单（如调整价格 / 数量）时，订单簿调用此函数将旧订单的 ETH 托管转移至新订单，并处理差额（退款或补款）。
     */
    function editETH(
        OrderKey oldOrderKey,
        OrderKey newOrderKey,
        uint256 oldETHAmount,
        uint256 newETHAmount,
        address to
    ) external payable onlyEasySwapOrderBook {
        ETHBalance[oldOrderKey] = 0;// 清空旧订单的ETH托管余额
        if (oldETHAmount > newETHAmount) {
            // 新托管金额 < 旧金额：将差额退回用户
            ETHBalance[newOrderKey] = newETHAmount;
            to.safeTransferETH(oldETHAmount - newETHAmount);
        } else if (oldETHAmount < newETHAmount) {
             // 新托管金额 > 旧金额：校验补充的ETH是否足够，累加至新订单
            require(msg.value >= newETHAmount - oldETHAmount,"HV: not match newETHAmount");
            ETHBalance[newOrderKey] = msg.value + oldETHAmount;
        } else {
            // 金额不变：直接转移至新订单
            ETHBalance[newOrderKey] = oldETHAmount;
        }
    }
    //---------------------------------------------------2.NFT 资产管理---------------------------------------------
    /**
        存入 NFT功能
        场景：用户创建卖单（List）时，订单簿调用此函数将用户的 NFT 转入金库托管。
        安全：使用safeTransferNFT确保 NFT 转账成功（若接收方合约未实现onERC721Received会 revert）。
     */
    function depositNFT(
        OrderKey orderKey,
        address from,
        address collection,
        uint256 tokenId
    ) external onlyEasySwapOrderBook {
        // 从用户地址安全转移NFT到金库
        IERC721(collection).safeTransferNFT(from, address(this), tokenId);
        NFTBalance[orderKey] = tokenId;// 关联订单与NFT的tokenId
    }
    /**
        提取 NFT功能
        场景：卖单取消、交易失败或用户提取未成交 NFT 时，订单簿调用此函数将 NFT 退回用户
     */
    function withdrawNFT(
        OrderKey orderKey,
        address to,
        address collection,
        uint256 tokenId
    ) external onlyEasySwapOrderBook {
        require(NFTBalance[orderKey] == tokenId, "HV: not match tokenId");// 校验NFT归属
        delete NFTBalance[orderKey];// 清空订单与NFT的关联
        // 将NFT从金库安全转移到目标地址
        IERC721(collection).safeTransferNFT(address(this), to, tokenId);
    }

    /**
        修改订单 NFT 托管功能
        场景：用户修改卖单（如调整价格 / 数量）时，订单簿调用此函数将旧订单的 NFT 托管转移至新订单（无需实际转移 NFT，仅更新映射关系）
     */
    function editNFT(
        OrderKey oldOrderKey,
        OrderKey newOrderKey
    ) external onlyEasySwapOrderBook {
        NFTBalance[newOrderKey] = NFTBalance[oldOrderKey];
        delete NFTBalance[oldOrderKey];
    }
    //-------------------------------------------资产转移（交易成交时）----------------------------------------------------
    /**
        单个 NFT 转移
        场景：交易成交时，订单簿调用此函数将托管的 NFT 从金库转移给买家
     */
    function transferERC721(
        address from,
        address to,
        LibOrder.Asset calldata assets
    ) external onlyEasySwapOrderBook {
        // 从指定地址（通常是金库或用户）将NFT转移到目标地址（如买家）
        IERC721(assets.collection).safeTransferNFT(from, to, assets.tokenId);
    }
    /**
        批量 NFT 转移
        特点：无onlyEasySwapOrderBook修饰符，允许任意地址调用，但需调用者拥有对应的 NFT（safeTransferNFT会校验授权）。
        场景：用户批量转移自有 NFT（非交易场景，如批量转账给其他地址）
     */
    function batchTransferERC721(
        address to,
        LibOrder.NFTInfo[] calldata assets
    ) external {
        for (uint256 i = 0; i < assets.length; ++i) {
            // 批量将调用者的NFT转移到目标地址
            IERC721(assets[i].collection).safeTransferNFT(
                _msgSender(),
                to,
                assets[i].tokenId
            );
        }
    }
    //ERC721 接收回调-->遵循 ERC721 标准，必须实现此函数才能让合约成功接收 NFT（否则 NFT 转账会失败）
    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) public virtual returns (bytes4) {
        //返回标准回调签名，表明合约可接收NFT
        return this.onERC721Received.selector;
    }
    //ETH 接收函数--->允许合约接收ETH转账（如用户存入ETH时）
    receive() external payable {}

    uint256[50] private __gap;
}

/**
    五、合约设计亮点
    严格的权限隔离：
        所有核心资产操作（存提、修改）仅允许订单簿合约调用，所有者仅能配置订单簿地址，避免权限滥用导致资产损失。
        安全的资产转移：
        依赖LibTransferSafeUpgradeable库的安全转账函数（safeTransferETH、safeTransferNFT），处理 ETH 转账失败（如接收方是合约但未实现receive）和 NFT 转账回调问题，降低资产锁定风险。
    订单与资产强绑定：
        通过OrderKey将 ETH/NFT 资产与订单一一对应，确保资产操作精准关联到具体订单，避免混淆。
        支持订单修改的无缝资产调整：
    editETH和editNFT函数实现新旧订单资产的平滑转移，处理金额差额（退款 / 补款），无需用户重复操作，提升体验。
    可升级兼容性：
        遵循 OpenZeppelin 可升级合约规范，通过OwnableUpgradeable和__gap预留扩展空间，便于后续添加功能（如支持 ERC1155 多代币、批量 ETH 操作等）。
    六、适用场景
        EasySwapVault 是NFT 去中心化交易平台的核心资产托管组件，与订单簿合约（如之前解析的OrderStorage、OrderValidator）配合，实现完整的交易流程：
        用户创建订单时，订单簿调用depositETH/depositNFT将资产转入金库托管。
        订单匹配成交时，订单簿调用withdrawETH/withdrawNFT和transferERC721，将买家的 ETH 转给卖家，卖家的 NFT 转给买家。
        订单取消或修改时，通过withdraw/edit函数处理资产退回或转移。
        通过隔离资产托管和交易逻辑，该合约大幅降低了交易系统的安全风险，是 NFT 交易平台不可或缺的基础设施。
 */
