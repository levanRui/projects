pragma solidity ^0.8.19;

// ----------------------------------------------------------------------------
// BokkyPooBah's Red-Black Tree Library v1.0-pre-release-a
//
// A Solidity Red-Black Tree binary search library to store and access a sorted
// list of unsigned integer data. The Red-Black algorithm rebalances the binary
// search tree, resulting in O(log n) insert, remove and search time (and ~gas)
//
// https://github.com/bokkypoobah/BokkyPooBahsRedBlackTreeLibrary
//
// SPDX-License-Identifier: MIT
//
// Enjoy. (c) BokkyPooBah / Bok Consulting Pty Ltd 2020. The MIT Licence.
// ----------------------------------------------------------------------------
type Price is uint128;
/**
    Solidity 自平衡二叉搜索树库

    该库是基于 红黑树（Red-Black Tree） 数据结构的 Solidity 实现，专为区块链场景优化，
    核心用于对 Price（价格，本质为 uint128）类型数据进行高效的排序、插入、删除和查询操作。
    红黑树通过自平衡机制保证树的高度始终接近 log n（n 为节点数），从而实现 O(log n) 时间复杂度的核心操作，
    大幅优于普通二叉搜索树（极端情况下可能退化为 O (n)），适合需要频繁排序和查询的场景（如 NFT/DeFi 订单簿的价格排序）
    一、核心概念与基础定义
        1. 红黑树的核心特性
            红黑树是一种自平衡二叉搜索树，通过以下 5 条规则保证平衡：
            每个节点要么是 红色，要么是 黑色；
            根节点是 黑色；
            所有叶子节点（NIL 节点，此处用 EMPTY 表示）是 黑色；
            如果一个节点是红色，其两个子节点必须是黑色；
            从任意节点到其所有叶子节点的路径上，黑色节点的数量相同（“黑高” 相等）。
            当插入 / 删除节点破坏这些规则时，会通过 颜色调整 和 旋转操作 恢复平衡，确保树的高度稳定。
        2. 库内核心类型定义
            (1)Price 自定义类型  type Price is uint128;
                本质是 uint128 的封装，用于表示 “价格”，通过自定义类型提升代码可读性，避免与普通整数混淆。
                提供 Price.wrap(uint128)（将 uint128 转为 Price）和 Price.unwrap(Price)（将 Price 转回 uint128）两个内置函数进行类型转换。
            (2)Node 结构体（红黑树节点）
                struct Node {
                    Price parent;   // 父节点的 Price
                    Price left;     // 左子节点的 Price（值小于当前节点）
                    Price right;    // 右子节点的 Price（值大于当前节点）
                    uint8 red;      // 节点颜色：1=红色，2=黑色（用 2 而非 0 避免默认值混淆）
                }
                每个节点存储其亲属节点的引用（通过 Price 关联）和颜色，符合二叉搜索树的父子关系规则（左子树值 < 父节点值 < 右子树值）
            (3)Tree 结构体（红黑树整体）
                struct Tree {
                    Price root;                     // 树的根节点 Price
                    mapping(Price => Node) nodes;   // 存储所有节点，以 Price 为键
                }
                通过 root 定位树的入口，通过 nodes 映射快速查找任意 Price 对应的节点详情，兼顾效率与存储优化。
        3. 常量与错误定义
                常量 / 错误	作用
                EMPTY（Price.wrap(0)）	表示 “空节点”（对应红黑树的 NIL 叶子节点），用于标记无父 / 子节点的场景。
                RED_TRUE（1）	标记节点为红色。
                RED_FALSE（2）	标记节点为黑色（不用 0 是因为 Solidity 映射中未初始化的 uint8 默认为 0，避免与 “黑色” 混淆）。
                CannotFindNextEmptyKey	查找后继节点时，输入的 Price 为 EMPTY。
                CannotInsertEmptyKey	插入时输入的 Price 为 EMPTY。
                CannotInsertExistingKey	插入已存在的 Price（红黑树不允许重复键）。
                CannotRemoveEmptyKey	删除时输入的 Price 为 EMPTY。
                CannotRemoveMissingKey	删除不存在的 Price。
    三、关键设计亮点
        1. 适配区块链场景的优化
            存储效率：使用 mapping(Price => Node) 存储节点，避免数组或链表的低效访问，Solidity 中映射的读取 / 写入效率接近 O (1)。
            类型安全：通过 Price 自定义类型封装 uint128，避免与普通整数混淆，提升代码可读性和安全性。
            错误处理：自定义错误（如 CannotInsertExistingKey）替代 require 字符串提示，减少部署成本（错误字符串存储更高效）并提供更明确的错误信息。
        2. 自平衡保证高效操作
             红黑树的平衡机制确保插入、删除、查询的时间复杂度稳定在 O (log n)，即使在订单量极大的场景（如热门 NFT 交易），仍能快速定位最优价格，避免普通二叉搜索树在极端情况下（如有序插入）退化为链表导致的 O (n) 低效。
        3. 与业务场景深度结合
            库专门针对 Price 类型设计，完美适配区块链交易场景中 “按价格排序” 的核心需求（如之前解析的 OrderStorage 合约中，用该库管理订单价格树，快速获取最优 / 次优订单价格）。
    四、应用场景
        该库是 去中心化交易平台（DEX） 或 NFT 交易市场 的核心基础设施，主要用于：
        订单簿价格排序：按价格组织买单（Bid）和卖单（List），快速获取 “最高买单”“最低卖单”（通过 first/last）。
        次优价格匹配：当最优价格订单无法完全成交时，通过 next/prev 快速定位下一个可匹配价格。
        动态订单调整：支持订单价格的插入（新订单）、删除（取消订单），且操作高效，不影响整体排序结构。
    五、总结
        RedBlackTreeLibrary 是一个高性能、高安全性的 Solidity 红黑树实现，通过自平衡机制解决了普通二叉搜索树的效率问题，
        同时针对区块链场景进行了存储和类型优化。它为需要排序和高效查询的去中心化应用（尤其是交易类应用）提供了关键的数据结构支持，是连接 “业务逻辑” 与 “高效数据管理” 的核心工具。

 */
library RedBlackTreeLibrary {
    struct Node {
        Price parent;
        Price left;
        Price right;
        uint8 red;
    }

    struct Tree {
        Price root;
        mapping(Price => Node) nodes;
    }

    Price private constant EMPTY = Price.wrap(0);
    uint8 private constant RED_TRUE = 1;
    uint8 private constant RED_FALSE = 2; // Can also be 0 - check against RED_TRUE

    error CannotFindNextEmptyKey();
    error CannotFindPrevEmptyKey();
    error CannotInsertEmptyKey();
    error CannotInsertExistingKey();
    error CannotRemoveEmptyKey();
    error CannotRemoveMissingKey();

    function first(Tree storage self) internal view returns (Price key) {
        key = self.root;
        if (isNotEmpty(key)) {
            while (isNotEmpty(self.nodes[key].left)) {
                key = self.nodes[key].left;
            }
        }
    }

    function last(Tree storage self) internal view returns (Price key) {
        key = self.root;
        if (isNotEmpty(key)) {
            while (isNotEmpty(self.nodes[key].right)) {
                key = self.nodes[key].right;
            }
        }
    }

    function next(Tree storage self, Price target) internal view returns (Price cursor) {
        if (isEmpty(target)) {
            revert CannotFindNextEmptyKey();
        }
        if (isNotEmpty(self.nodes[target].right)) {
            cursor = treeMinimum(self, self.nodes[target].right);
        } else {
            cursor = self.nodes[target].parent;
            while (isNotEmpty(cursor) && Price.unwrap(target) == Price.unwrap(self.nodes[cursor].right)) {
                target = cursor;
                cursor = self.nodes[cursor].parent;
            }
        }
    }

    function prev(Tree storage self, Price target) internal view returns (Price cursor) {
        if (isEmpty(target)) {
            revert CannotFindPrevEmptyKey();
        }
        if (isNotEmpty(self.nodes[target].left)) {
            cursor = treeMaximum(self, self.nodes[target].left);
        } else {
            cursor = self.nodes[target].parent;
            while (isNotEmpty(cursor) && Price.unwrap(target) == Price.unwrap(self.nodes[cursor].left)) {
                target = cursor;
                cursor = self.nodes[cursor].parent;
            }
        }
    }

    function exists(Tree storage self, Price key) internal view returns (bool) {
        return isNotEmpty(key) && ((Price.unwrap(key) == Price.unwrap(self.root)) || isNotEmpty(self.nodes[key].parent));
    }

    function isEmpty(Price key) internal pure returns (bool) {
        return Price.unwrap(key) == Price.unwrap(EMPTY);
    }

    function isNotEmpty(Price key) internal pure returns (bool) {
        return Price.unwrap(key) != Price.unwrap(EMPTY);
    }

    function getEmpty() internal pure returns (Price) {
        return EMPTY;
    }

    function getNode(Tree storage self, Price key)
        internal
        view
        returns (Price returnKey, Price parent, Price left, Price right, uint8 red)
    {
        require(exists(self, key));
        return (key, self.nodes[key].parent, self.nodes[key].left, self.nodes[key].right, self.nodes[key].red);
    }

    function insert(Tree storage self, Price key) internal {
        if (isEmpty(key)) {
            revert CannotInsertEmptyKey();
        }
        if (exists(self, key)) {
            revert CannotInsertExistingKey();
        }
        Price cursor = EMPTY;
        Price probe = self.root;
        while (isNotEmpty(probe)) {
            cursor = probe;
            if (Price.unwrap(key) < Price.unwrap(probe)) {
                probe = self.nodes[probe].left;
            } else {
                probe = self.nodes[probe].right;
            }
        }
        self.nodes[key] = Node({parent: cursor, left: EMPTY, right: EMPTY, red: RED_TRUE});
        if (isEmpty(cursor)) {
            self.root = key;
        } else if (Price.unwrap(key) < Price.unwrap(cursor)) {
            self.nodes[cursor].left = key;
        } else {
            self.nodes[cursor].right = key;
        }
        insertFixup(self, key);
    }

    function remove(Tree storage self, Price key) internal {
        if (isEmpty(key)) {
            revert CannotRemoveEmptyKey();
        }
        if (!exists(self, key)) {
            revert CannotRemoveMissingKey();
        }
        Price probe;
        Price cursor;
        if (isEmpty(self.nodes[key].left) || isEmpty(self.nodes[key].right)) {
            cursor = key;
        } else {
            cursor = self.nodes[key].right;
            while (isNotEmpty(self.nodes[cursor].left)) {
                cursor = self.nodes[cursor].left;
            }
        }
        if (isNotEmpty(self.nodes[cursor].left)) {
            probe = self.nodes[cursor].left;
        } else {
            probe = self.nodes[cursor].right;
        }
        Price yParent = self.nodes[cursor].parent;
        self.nodes[probe].parent = yParent;
        if (isNotEmpty(yParent)) {
            if (Price.unwrap(cursor) == Price.unwrap(self.nodes[yParent].left)) {
                self.nodes[yParent].left = probe;
            } else {
                self.nodes[yParent].right = probe;
            }
        } else {
            self.root = probe;
        }
        bool doFixup = self.nodes[cursor].red != RED_TRUE;
        if (Price.unwrap(cursor) != Price.unwrap(key)) {
            replaceParent(self, cursor, key);
            self.nodes[cursor].left = self.nodes[key].left;
            self.nodes[self.nodes[cursor].left].parent = cursor;
            self.nodes[cursor].right = self.nodes[key].right;
            self.nodes[self.nodes[cursor].right].parent = cursor;
            self.nodes[cursor].red = self.nodes[key].red;
            (cursor, key) = (key, cursor);
        }
        if (doFixup) {
            removeFixup(self, probe);
        }
        delete self.nodes[cursor];
    }

    function treeMinimum(Tree storage self, Price key) private view returns (Price) {
        while (isNotEmpty(self.nodes[key].left)) {
            key = self.nodes[key].left;
        }
        return key;
    }

    function treeMaximum(Tree storage self, Price key) private view returns (Price) {
        while (isNotEmpty(self.nodes[key].right)) {
            key = self.nodes[key].right;
        }
        return key;
    }

    function rotateLeft(Tree storage self, Price key) private {
        Price cursor = self.nodes[key].right;
        Price keyParent = self.nodes[key].parent;
        Price cursorLeft = self.nodes[cursor].left;
        self.nodes[key].right = cursorLeft;
        if (isNotEmpty(cursorLeft)) {
            self.nodes[cursorLeft].parent = key;
        }
        self.nodes[cursor].parent = keyParent;
        if (isEmpty(keyParent)) {
            self.root = cursor;
        } else if (Price.unwrap(key) == Price.unwrap(self.nodes[keyParent].left)) {
            self.nodes[keyParent].left = cursor;
        } else {
            self.nodes[keyParent].right = cursor;
        }
        self.nodes[cursor].left = key;
        self.nodes[key].parent = cursor;
    }

    function rotateRight(Tree storage self, Price key) private {
        Price cursor = self.nodes[key].left;
        Price keyParent = self.nodes[key].parent;
        Price cursorRight = self.nodes[cursor].right;
        self.nodes[key].left = cursorRight;
        if (isNotEmpty(cursorRight)) {
            self.nodes[cursorRight].parent = key;
        }
        self.nodes[cursor].parent = keyParent;
        if (isEmpty(keyParent)) {
            self.root = cursor;
        } else if (Price.unwrap(key) == Price.unwrap(self.nodes[keyParent].right)) {
            self.nodes[keyParent].right = cursor;
        } else {
            self.nodes[keyParent].left = cursor;
        }
        self.nodes[cursor].right = key;
        self.nodes[key].parent = cursor;
    }

    function insertFixup(Tree storage self, Price key) private {
        Price cursor;
        while (Price.unwrap(key) != Price.unwrap(self.root) && self.nodes[self.nodes[key].parent].red == RED_TRUE) {
            Price keyParent = self.nodes[key].parent;
            if (Price.unwrap(keyParent) == Price.unwrap(self.nodes[self.nodes[keyParent].parent].left)) {
                cursor = self.nodes[self.nodes[keyParent].parent].right;
                if (self.nodes[cursor].red == RED_TRUE) {
                    self.nodes[keyParent].red = RED_FALSE;
                    self.nodes[cursor].red = RED_FALSE;
                    self.nodes[self.nodes[keyParent].parent].red = RED_TRUE;
                    key = self.nodes[keyParent].parent;
                } else {
                    if (Price.unwrap(key) == Price.unwrap(self.nodes[keyParent].right)) {
                        key = keyParent;
                        rotateLeft(self, key);
                    }
                    keyParent = self.nodes[key].parent;
                    self.nodes[keyParent].red = RED_FALSE;
                    self.nodes[self.nodes[keyParent].parent].red = RED_TRUE;
                    rotateRight(self, self.nodes[keyParent].parent);
                }
            } else {
                cursor = self.nodes[self.nodes[keyParent].parent].left;
                if (self.nodes[cursor].red == RED_TRUE) {
                    self.nodes[keyParent].red = RED_FALSE;
                    self.nodes[cursor].red = RED_FALSE;
                    self.nodes[self.nodes[keyParent].parent].red = RED_TRUE;
                    key = self.nodes[keyParent].parent;
                } else {
                    if (Price.unwrap(key) == Price.unwrap(self.nodes[keyParent].left)) {
                        key = keyParent;
                        rotateRight(self, key);
                    }
                    keyParent = self.nodes[key].parent;
                    self.nodes[keyParent].red = RED_FALSE;
                    self.nodes[self.nodes[keyParent].parent].red = RED_TRUE;
                    rotateLeft(self, self.nodes[keyParent].parent);
                }
            }
        }
        self.nodes[self.root].red = RED_FALSE;
    }

    function replaceParent(Tree storage self, Price a, Price b) private {
        Price bParent = self.nodes[b].parent;
        self.nodes[a].parent = bParent;
        if (isEmpty(bParent)) {
            self.root = a;
        } else {
            if (Price.unwrap(b) == Price.unwrap(self.nodes[bParent].left)) {
                self.nodes[bParent].left = a;
            } else {
                self.nodes[bParent].right = a;
            }
        }
    }

    function removeFixup(Tree storage self, Price key) private {
        Price cursor;
        while (Price.unwrap(key) != Price.unwrap(self.root) && self.nodes[key].red != RED_TRUE) {
            Price keyParent = self.nodes[key].parent;
            if (Price.unwrap(key) == Price.unwrap(self.nodes[keyParent].left)) {
                cursor = self.nodes[keyParent].right;
                if (self.nodes[cursor].red == RED_TRUE) {
                    self.nodes[cursor].red = RED_FALSE;
                    self.nodes[keyParent].red = RED_TRUE;
                    rotateLeft(self, keyParent);
                    cursor = self.nodes[keyParent].right;
                }
                if (
                    self.nodes[self.nodes[cursor].left].red != RED_TRUE
                        && self.nodes[self.nodes[cursor].right].red != RED_TRUE
                ) {
                    self.nodes[cursor].red = RED_TRUE;
                    key = keyParent;
                } else {
                    if (self.nodes[self.nodes[cursor].right].red != RED_TRUE) {
                        self.nodes[self.nodes[cursor].left].red = RED_FALSE;
                        self.nodes[cursor].red = RED_TRUE;
                        rotateRight(self, cursor);
                        cursor = self.nodes[keyParent].right;
                    }
                    self.nodes[cursor].red = self.nodes[keyParent].red;
                    self.nodes[keyParent].red = RED_FALSE;
                    self.nodes[self.nodes[cursor].right].red = RED_FALSE;
                    rotateLeft(self, keyParent);
                    key = self.root;
                }
            } else {
                cursor = self.nodes[keyParent].left;
                if (self.nodes[cursor].red == RED_TRUE) {
                    self.nodes[cursor].red = RED_FALSE;
                    self.nodes[keyParent].red = RED_TRUE;
                    rotateRight(self, keyParent);
                    cursor = self.nodes[keyParent].left;
                }
                if (
                    self.nodes[self.nodes[cursor].right].red != RED_TRUE
                        && self.nodes[self.nodes[cursor].left].red != RED_TRUE
                ) {
                    self.nodes[cursor].red = RED_TRUE;
                    key = keyParent;
                } else {
                    if (self.nodes[self.nodes[cursor].left].red != RED_TRUE) {
                        self.nodes[self.nodes[cursor].right].red = RED_FALSE;
                        self.nodes[cursor].red = RED_TRUE;
                        rotateLeft(self, cursor);
                        cursor = self.nodes[keyParent].left;
                    }
                    self.nodes[cursor].red = self.nodes[keyParent].red;
                    self.nodes[keyParent].red = RED_FALSE;
                    self.nodes[self.nodes[cursor].left].red = RED_FALSE;
                    rotateRight(self, keyParent);
                    key = self.root;
                }
            }
        }
        self.nodes[key].red = RED_FALSE;
    }
}
// ----------------------------------------------------------------------------
/**
    二、核心功能函数解析
库的函数按功能可分为 查询类、插入 / 删除类 和 内部辅助类，以下是关键函数的详细说明：
1. 查询类函数（读取树数据）
（1）first：获取树中最小的 Price（最左节点）
solidity
function first(Tree storage self) internal view returns (Price key) {
    key = self.root;
    if (isNotEmpty(key)) {
        // 二叉搜索树中，最小节点是根节点的最左子节点（递归向左遍历）
        while (isNotEmpty(self.nodes[key].left)) {
            key = self.nodes[key].left;
        }
    }
}
应用场景：订单簿中获取 “最低卖单价格”（卖单按价格升序排序，最小价格为最优）。
（2）last：获取树中最大的 Price（最右节点）
solidity
function last(Tree storage self) internal view returns (Price key) {
    key = self.root;
    if (isNotEmpty(key)) {
        // 二叉搜索树中，最大节点是根节点的最右子节点（递归向右遍历）
        while (isNotEmpty(self.nodes[key].right)) {
            key = self.nodes[key].right;
        }
    }
}
应用场景：订单簿中获取 “最高买单价格”（买单按价格降序排序，最大价格为最优）。
（3）next：获取指定 Price 的 后继节点（大于当前值的最小节点）
solidity
function next(Tree storage self, Price target) internal view returns (Price cursor) {
    if (isEmpty(target)) revert CannotFindNextEmptyKey();
    // 情况1：目标节点有右子树 → 后继是右子树的最左节点
    if (isNotEmpty(self.nodes[target].right)) {
        cursor = treeMinimum(self, self.nodes[target].right);
    } else {
        // 情况2：目标节点无右子树 → 向上追溯父节点，直到找到“当前节点是父节点左子节点”的父节点
        cursor = self.nodes[target].parent;
        while (isNotEmpty(cursor) && Price.unwrap(target) == Price.unwrap(self.nodes[cursor].right)) {
            target = cursor;
            cursor = self.nodes[cursor].parent;
        }
    }
}
辅助函数 treeMinimum：获取某子树的最左节点（即该子树的最小值）。
应用场景：订单簿中查找 “当前价格的下一个更高价格”（如最优价格订单已填满，需匹配次优价格）。
（4）prev：获取指定 Price 的 前驱节点（小于当前值的最大节点）
逻辑与 next 对称：
若目标节点有左子树，前驱是左子树的最右节点（treeMaximum 函数）；
若无左子树，向上追溯父节点，直到找到 “当前节点是父节点右子节点” 的父节点。
应用场景：订单簿中查找 “当前价格的下一个更低价格”。
（5）exists：判断 Price 是否存在于树中
solidity
function exists(Tree storage self, Price key) internal view returns (bool) {
    // 非空 +（是根节点 或 有父节点，即已插入树中）
    return isNotEmpty(key) && ((Price.unwrap(key) == Price.unwrap(self.root)) || isNotEmpty(self.nodes[key].parent));
}
核心逻辑：通过节点是否有父节点（parent != EMPTY）判断是否已插入树中（根节点无父节点，需单独判断）。
2. 插入与删除函数（修改树数据）
（1）insert：插入新 Price 节点
插入流程分为两步：按二叉搜索树规则插入节点 → 修复红黑树平衡。
solidity
function insert(Tree storage self, Price key) internal {
    // 校验：不能插入空值或已存在的值
    if (isEmpty(key)) revert CannotInsertEmptyKey();
    if (exists(self, key)) revert CannotInsertExistingKey();

    // 第一步：按二叉搜索树规则找到插入位置
    Price cursor = EMPTY;       // 记录插入节点的父节点
    Price probe = self.root;    // 从根节点开始遍历
    while (isNotEmpty(probe)) {
        cursor = probe;
        // 左子树存小值，右子树存大值
        if (Price.unwrap(key) < Price.unwrap(probe)) {
            probe = self.nodes[probe].left;
        } else {
            probe = self.nodes[probe].right;
        }
    }

    // 初始化新节点（默认红色，符合红黑树插入规则：新节点为红色，减少黑高冲突）
    self.nodes[key] = Node({parent: cursor, left: EMPTY, right: EMPTY, red: RED_TRUE});

    // 关联父节点与新节点
    if (isEmpty(cursor)) {
        self.root = key; // 树为空，新节点作为根节点
    } else if (Price.unwrap(key) < Price.unwrap(cursor)) {
        self.nodes[cursor].left = key; // 新节点为左子节点
    } else {
        self.nodes[cursor].right = key; // 新节点为右子节点
    }

    // 第二步：修复红黑树平衡（插入红色节点可能破坏规则4）
    insertFixup(self, key);
}
（2）insertFixup：插入后平衡修复
插入红色节点可能破坏 “红色节点的子节点必须为黑色”（规则 4），需通过 颜色调整 和 旋转 恢复平衡。核心逻辑分三种情况处理（基于父节点是祖父节点的左 / 右子节点，逻辑对称）：
情况 1：叔叔节点（父节点的兄弟）是红色 → 调整父、叔、祖父节点颜色；
情况 2：叔叔节点是黑色，且当前节点是父节点的右子节点 → 先左旋父节点，转为情况 3；
情况 3：叔叔节点是黑色，且当前节点是父节点的左子节点 → 右旋祖父节点，调整颜色。
最终确保根节点为黑色（规则 2）。
（3）remove：删除指定 Price 节点
删除是红黑树最复杂的操作，流程分为三步：找到待删除节点的替代节点 → 调整树结构删除节点 → 修复红黑树平衡。
solidity
function remove(Tree storage self, Price key) internal {
    // 校验：不能删除空值或不存在的值
    if (isEmpty(key)) revert CannotRemoveEmptyKey();
    if (!exists(self, key)) revert CannotRemoveMissingKey();

    // 第一步：找到“实际删除节点”（cursor）—— 待删除节点或其替代节点
    Price cursor; // 实际要删除的节点
    Price probe;  // cursor 的子节点（用于后续填补删除位置）
    // 待删除节点只有一个子节点或无子节点 → 直接删除该节点
    if (isEmpty(self.nodes[key].left) || isEmpty(self.nodes[key].right)) {
        cursor = key;
    } else {
        // 待删除节点有两个子节点 → 用“后继节点”（右子树的最小节点）作为替代节点
        cursor = self.nodes[key].right;
        while (isNotEmpty(self.nodes[cursor].left)) {
            cursor = self.nodes[cursor].left;
        }
    }

    // 第二步：用 probe 填补 cursor 的位置（probe 是 cursor 的非空子节点，或 EMPTY）
    if (isNotEmpty(self.nodes[cursor].left)) {
        probe = self.nodes[cursor].left;
    } else {
        probe = self.nodes[cursor].right;
    }
    // 更新 probe 的父节点
    Price yParent = self.nodes[cursor].parent;
    self.nodes[probe].parent = yParent;
    // 关联 probe 与原 cursor 的父节点
    if (isNotEmpty(yParent)) {
        if (Price.unwrap(cursor) == Price.unwrap(self.nodes[yParent].left)) {
            self.nodes[yParent].left = probe;
        } else {
            self.nodes[yParent].right = probe;
        }
    } else {
        self.root = probe; // cursor 是根节点，probe 成为新根
    }

    // 第三步：若删除的是黑色节点，需修复平衡（黑色节点删除可能破坏规则5）
    bool doFixup = self.nodes[cursor].red != RED_TRUE;
    // 若 cursor 是替代节点（非原 key），需将原 key 的数据转移到 cursor（保持树结构）
    if (Price.unwrap(cursor) != Price.unwrap(key)) {
        replaceParent(self, cursor, key); // 转移父节点关联
        self.nodes[cursor].left = self.nodes[key].left; // 转移左子树
        self.nodes[self.nodes[cursor].left].parent = cursor;
        self.nodes[cursor].right = self.nodes[key].right; // 转移右子树
        self.nodes[self.nodes[cursor].right].parent = cursor;
        self.nodes[cursor].red = self.nodes[key].red; // 继承颜色
        (cursor, key) = (key, cursor); // 交换，确保后续删除原 key
    }

    // 执行平衡修复（仅当删除的是黑色节点时）
    if (doFixup) {
        removeFixup(self, probe);
    }

    // 从映射中删除节点
    delete self.nodes[cursor];
}
（4）removeFixup：删除后平衡修复
删除黑色节点可能破坏 “黑高相等”（规则 5），需通过颜色调整和旋转恢复平衡。核心逻辑分四种情况处理（基于当前节点是父节点的左 / 右子节点，逻辑对称），最终确保所有红黑树规则被满足。
3. 内部辅助函数
（1）旋转操作：rotateLeft / rotateRight
旋转是红黑树平衡修复的核心手段，用于调整节点的父子关系，不改变二叉搜索树的排序特性，仅改变树的高度。
rotateLeft（左旋）：将节点的右子节点提升为父节点，原节点变为新父节点的左子节点，新父节点的原左子节点变为原节点的右子节点。
rotateRight（右旋）：与左旋对称，将节点的左子节点提升为父节点，原节点变为新父节点的右子节点，新父节点的原右子节点变为原节点的左子节点。
（2）treeMinimum / treeMaximum
treeMinimum：获取某子树的最左节点（最小值）。
treeMaximum：获取某子树的最右节点（最大值）。
（3）replaceParent
转移节点的父节点关联，用于删除操作中 “替代节点” 继承原节点的父子关系。




 */
// ----------------------------------------------------------------------------
