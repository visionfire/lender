// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./utils/WadRayMath.sol";
import "./utils/PoolUtils.sol";
import "./InterestRateStrategy.sol";
import "./AToken.sol";
import "./VariableDebtToken.sol";
import "./interfaces/IAggregatorV3.sol";
import "./UserVault.sol";


contract LendingPool is Ownable, ReentrancyGuard {
    using WadRayMath for uint256;
    using PoolUtils for uint256;

    struct ReserveData {
        address asset;
        address aToken;
        address variableDebtToken;
        uint8 decimals;
        // 资产流动性索引,计算利息(根据index,本金随时间放大)
        uint256 liquidityIndex;

        // 借款债务索引,计算债务利率(实际债务随利率变化)
        uint256 variableBorrowIndex;

        // 当前存款利率
        uint256 currentLiquidityRate;

        // 当前借款债务利率
        uint256 currentVariableBorrowRate;

        uint256 lastUpdateTimestamp;
        uint256 totalScaledVariableDebt;
        uint256 totalLiquidity;
        uint256 ltv;
        uint256 liquidationThreshold;
        uint256 liquidationBonus;
        uint256 reserveFactor;
        address interestStrategy;
        IAggregatorV3 priceOracle;
        uint256 minLiquidityRatio;
    }

    struct WithdrawalRequest {
        uint256 amount18;
        uint256 unlockTimestamp;
        bool exists;
    }

    mapping(address => ReserveData) public reserves;
    address[] public reserveList;

    // 用户借贷资金托管账户合约
    mapping(address => address) public userVaults;

    // 允许的托管账户合约可执行地址
    mapping(address => bool) public allowedTargets;

    // 提现请求记录
    mapping(address => mapping(address => WithdrawalRequest)) public userWithdrawRequests;

    uint256 public constant RAY = WadRayMath.RAY;
    uint256 public constant WAD = WadRayMath.WAD;
    uint256 public constant SECONDS_PER_YEAR = WadRayMath.SECONDS_PER_YEAR;

    // 默认的最大清算比例 50%
    uint256 public closeFactor = 5e17;


    event ReserveInitialized(address indexed asset, address indexed aToken, address indexed variableDebtToken);
    event Supply(address indexed user, address indexed asset, uint256 amountRaw);
    event Borrow(address indexed user, address indexed asset, uint256 amountRaw, address vault);
    event Repay(address indexed payer, address indexed asset, uint256 amountRaw);
    event LiquidationCall(address indexed collateralAsset, address indexed debtAsset, address indexed user, address liquidator, uint256 debtRepaidRaw, uint256 collateralSeizedRaw);
    event Withdraw(address indexed user, address indexed asset, uint256 amountRaw, bool delayed, uint256 unlockTimestamp);
    event ClaimWithdrawal(address indexed user, address indexed asset, uint256 amountRaw);
    event VaultCreated(address indexed user, address vault);
    event AllowedTargetSet(address indexed target, bool allowed);



    function initReserve(
        address asset,
        uint8 decimals,
        address priceOracle,
        address interestStrategy,
        uint256 ltv,
        uint256 liquidationThreshold,
        uint256 liquidationBonus,
        uint256 reserveFactor
    ) external onlyOwner {
        require(reserves[asset].asset == address(0), "reserve exists");

        // TODO
        string memory name = "A Token";
        string memory sym = "AT";
        AToken a = new AToken(asset, address(this), name, sym, decimals);

        // TODO
        string memory dname = "Debt Token";
        string memory dsym = "DT";
        VariableDebtToken v = new VariableDebtToken(asset, address(this), dname, dsym, decimals);

        ReserveData storage r = reserves[asset];
        r.asset = asset;
        r.aToken = address(a);
        r.variableDebtToken = address(v);
        r.decimals = decimals;
        // 1.0
        r.liquidityIndex = RAY;
        r.variableBorrowIndex = RAY;
        r.currentLiquidityRate = 0;
        r.currentVariableBorrowRate = 0;
        r.lastUpdateTimestamp = block.timestamp;
        r.totalScaledVariableDebt = 0;
        r.totalLiquidity = 0;
        r.ltv = ltv;
        r.liquidationThreshold = liquidationThreshold;
        r.liquidationBonus = liquidationBonus;
        r.reserveFactor = reserveFactor;
        r.interestStrategy = interestStrategy;
        r.priceOracle = IAggregatorV3(priceOracle);
        // 5% default
        r.minLiquidityRatio = 5e16;
        reserveList.push(asset);
        emit ReserveInitialized(asset, address(a), address(v));
    }


    // 抵押
    function supply(address asset, uint256 amountRaw) external nonReentrant {
        // 判断资产余额
        ReserveData storage r = reserves[asset];
        require(r.asset != address(0), "reserve not init");

        // 转账
        IERC20(asset).transferFrom(msg.sender, address(this), amountRaw);

        // 更新资产索引,获取之前的利息
        _updateReserveState(asset);

        uint256 amount18 = PoolUtils.to18(amountRaw, r.decimals);
        uint256 scaled = WadRayMath.rayDiv(amount18, r.liquidityIndex);

        // 增发抵押凭证
        AToken(r.aToken).mintScaled(msg.sender, scaled);

        r.totalLiquidity += amount18;

        // 更新计算利息
        _updateReserveRates(asset);

        emit Supply(msg.sender, asset, amountRaw);
    }


    // 借贷
    function borrow(address asset, uint256 amountRaw) external nonReentrant {
        require(reserves[asset].asset != address(0), "reserve not init");
        ReserveData storage r = reserves[asset];

        // 更新资产索引,获取之前的利息
        _updateReserveState(asset);

        // 获取资产价格,计算判断HF
        (uint256 collUSD, uint256 debtUSD, uint256 hf) = _getUserAccountData(msg.sender);
        uint256 amount18 = PoolUtils.to18(amountRaw, r.decimals);
        uint256 price = _getAssetPrice(asset);
        uint256 amountUSD = (amount18 * price) / WAD;
        uint256 newDebtUSD = debtUSD + amountUSD;
        require(collUSD * r.liquidationThreshold / RAY >= newDebtUSD, "exceed HF");

        // 判断池子资产是否足够
        uint256 poolBal = IERC20(asset).balanceOf(address(this));
        require(poolBal >= amountRaw, "exceed liquidity");

        // 增发债务token
        uint256 scaled = WadRayMath.rayDiv(amount18, r.variableBorrowIndex);
        VariableDebtToken(r.variableDebtToken).mintScaled(msg.sender, scaled);
        r.totalScaledVariableDebt += scaled;

        // 创建或获取用户托管账户合约
        address vault = _createVaultIfNeeded(msg.sender);

        // 更新池子流动性资产记录
        if (r.totalLiquidity >= amount18) {
            r.totalLiquidity -= amount18;
        } else {
            r.totalLiquidity = 0;
        }

        // 将借贷资金转入到托管账户合约
        IERC20(asset).transfer(vault, amountRaw);

        // 更新计算利息
        _updateReserveRates(asset);

        emit Borrow(msg.sender, asset, amountRaw, vault);
    }


    // 还款
    function repay(address asset, uint256 amountRaw) external nonReentrant {
        require(reserves[asset].asset != address(0), "reserve not init");
        ReserveData storage r = reserves[asset];

        // 更新资产索引,获取之前的利息
        _updateReserveState(asset);

        uint256 remaining = amountRaw;
        uint256 pulledFromVault = 0;

        // 获取用户的托管账户合约
        address vaultAddr = userVaults[msg.sender];
        if (vaultAddr != address(0)) {
            uint256 vaultBal = UserVault(vaultAddr).balanceOf(asset);
            if (vaultBal > 0) {
                uint256 take = vaultBal >= remaining ? remaining : vaultBal;
                // 从托管账户合约转账还给流动性池
                UserVault(vaultAddr).transferByPool(asset, address(this), take);
                remaining -= take;
                pulledFromVault = take;
            }
        }

        // 如果托管账户合约不够还,则继续从用户个人地址还款
        if (remaining > 0) {
            IERC20(asset).transferFrom(msg.sender, address(this), remaining);
        }

        uint256 totalPaidRaw = amountRaw - remaining;
        uint256 amount18 = PoolUtils.to18(totalPaidRaw, r.decimals);
        uint256 scaled = WadRayMath.rayDiv(amount18, r.variableBorrowIndex);
        if (scaled > r.totalScaledVariableDebt) {
            scaled = r.totalScaledVariableDebt;
        }

        VariableDebtToken(r.variableDebtToken).burnScaled(msg.sender, scaled);
        if (r.totalScaledVariableDebt >= scaled) {
            r.totalScaledVariableDebt -= scaled;
        } else {
            r.totalScaledVariableDebt = 0;
        }

        r.totalLiquidity += amount18;

        _updateReserveRates(asset);
        emit Repay(msg.sender, asset, totalPaidRaw);
    }


    // 清算
    function liquidationCall(address collateralAsset, address debtAsset, address user, uint256 debtToCoverRaw, address[] calldata vaultTokensToSeize) external nonReentrant {
        require(reserves[collateralAsset].asset != address(0) && reserves[debtAsset].asset != address(0), "invalid assets");
        (uint256 collUSD, uint256 debtUSD, uint256 hf) = _getUserAccountData(user);
        require(hf < RAY, "user not liquidatable");

        ReserveData storage debtR = reserves[debtAsset];
        ReserveData storage collR = reserves[collateralAsset];

        uint256 userDebtRaw = VariableDebtToken(debtR.variableDebtToken).balanceOf(user);
        uint256 maxRepay = (userDebtRaw * closeFactor) / 1e18;
        if (debtToCoverRaw > maxRepay) debtToCoverRaw = maxRepay;
        require(debtToCoverRaw > 0, "nothing to repay");

        uint256 remaining = debtToCoverRaw;
        uint256 paidFromVault = 0;

        // 1.先从用户的托管账户合约进行清算还款
        address userVaultAddr = userVaults[user];
        if (userVaultAddr != address(0)) {
            uint256 vb = UserVault(userVaultAddr).balanceOf(debtAsset);
            if (vb > 0) {
                uint256 take = vb >= remaining ? remaining : vb;
                UserVault(userVaultAddr).transferByPool(debtAsset, address(this), take);
                remaining -= take;
                paidFromVault = take;
            }
        }

        // 2.不够再直接从清算者个人地址转款帮忙偿还
        if (remaining > 0) {
            IERC20(debtAsset).transferFrom(msg.sender, address(this), remaining);
        }

        uint256 totalRepaid = debtToCoverRaw - remaining + ((remaining > 0) ? remaining : 0);

        // burn借款人用户的债务
        uint256 amount18 = PoolUtils.to18(debtToCoverRaw, debtR.decimals);
        uint256 scaled = WadRayMath.rayDiv(amount18, debtR.variableBorrowIndex);
        VariableDebtToken(debtR.variableDebtToken).burnScaled(user, scaled);
        if (debtR.totalScaledVariableDebt >= scaled) {
            debtR.totalScaledVariableDebt -= scaled;
        } else {
            debtR.totalScaledVariableDebt = 0;
        }

        debtR.totalLiquidity += amount18;

        // 获取资产和抵押品价格,计算清算奖励
        uint256 priceDebt = _getAssetPrice(debtAsset);
        uint256 priceColl = _getAssetPrice(collateralAsset);

        // 需要先把偿还的债务换算为USD等价值来计算清算奖励,再将奖励的部分换成抵押物价值
        uint256 amountUSD = (amount18 * priceDebt) / WAD;
        uint256 amountUSDWithBonus = (amountUSD * collR.liquidationBonus) / RAY;
        uint256 collAmount18 = (amountUSDWithBonus * WAD) / priceColl;
        uint256 collRaw = PoolUtils.from18(collAmount18, collR.decimals);

        // 判断借款人用户的凭证token
        uint256 userATokenRaw = AToken(collR.aToken).balanceOf(user);
        if (collRaw > userATokenRaw) {
            collRaw = userATokenRaw;
            collAmount18 = PoolUtils.to18(collRaw, collR.decimals);
        }

        // burn借款人用户的抵押凭证
        uint256 scaledToBurn = WadRayMath.rayDiv(collAmount18, collR.liquidityIndex);
        AToken(collR.aToken).burnScaled(user, scaledToBurn);

        // transfer underlying collateral from pool to liquidator
        // 3.给奖励给到清算者
        IERC20(collateralAsset).transfer(msg.sender, collRaw);

        // 如果vaultTokensToSeize有指定,则直接将用户里的指定的token都转给到池子
        if (userVaultAddr != address(0) && vaultTokensToSeize.length > 0) {
            UserVault(userVaultAddr).sweepTokens(vaultTokensToSeize, address(this));
        }

        // 更新资产流动性索引和利率和债务流动性索引和利率
        _updateReserveState(collateralAsset);
        _updateReserveState(debtAsset);
        _updateReserveRates(collateralAsset);
        _updateReserveRates(debtAsset);

        emit LiquidationCall(collateralAsset, debtAsset, user, msg.sender, debtToCoverRaw, collRaw);
    }


    // 申请提现
    function withdraw(address asset, uint256 amountRaw) external nonReentrant {
        ReserveData storage r = reserves[asset];
        require(r.asset != address(0), "reserve not init");


        _updateReserveState(asset);

        // 判断抵押凭证是否足够
        uint256 userBal = AToken(r.aToken).balanceOf(msg.sender);
        require(userBal >= amountRaw, "not enough aToken");

        uint256 amount18 = PoolUtils.to18(amountRaw, r.decimals);
        uint256 scaled = WadRayMath.rayDiv(amount18, r.liquidityIndex);

        // 设置和提现时间锁
        bool trigger = false;
        uint256 totalLiquidity = r.totalLiquidity;

        if (amount18 * 10 > totalLiquidity) trigger = true;
        if (totalLiquidity > amount18) {
            uint256 newAvailable = totalLiquidity - amount18;
            if (newAvailable < (totalLiquidity * r.minLiquidityRatio / WAD)) trigger = true;
        } else {
            trigger = true;
        }

        uint256 totalBorrows = WadRayMath.rayMul(r.totalScaledVariableDebt, r.variableBorrowIndex);
        (uint256 newLiqRate, uint256 newBorrowRate) = InterestRateStrategy(r.interestStrategy).calculateRates(
            (totalLiquidity > amount18 ? totalLiquidity - amount18 : 0),
            totalBorrows,
            r.reserveFactor
        );
        if (newBorrowRate > r.currentVariableBorrowRate + (2 * 1e25)) {
            trigger = true;
        }

        // burn抵押凭证
        AToken(r.aToken).burnScaled(msg.sender, scaled);

        // 提现需确保用户必须有托管账户合约
        address vault = _createVaultIfNeeded(msg.sender);

        if (trigger) {
            // 延时提现,记录请求(资金仍在池里暂未转出)
            WithdrawalRequest storage req = userWithdrawRequests[msg.sender][asset];
            req.amount18 += amount18;
            req.unlockTimestamp = block.timestamp + 7 days;
            req.exists = true;

            if (r.totalLiquidity >= amount18) {
                r.totalLiquidity -= amount18;
            } else {
                r.totalLiquidity = 0;
            }
            _updateReserveRates(asset);
            emit Withdraw(msg.sender, asset, amountRaw, true, req.unlockTimestamp);
        } else {
            // 立即提现,只能从托管账户合约提现到用户地址
            uint256 need = amountRaw;

            // 优先使用托管账户合约现有余额
            uint256 vaultBal = UserVault(vault).balanceOf(asset);
            if (vaultBal >= need) {
                // 足够 -> 托管账户合约直接转给用户
                UserVault(vault).transferByPool(asset, msg.sender, need);
            } else {
                // 不足 -> 先把托管账户合约里全部转给用户
                if (vaultBal > 0) {
                    UserVault(vault).transferByPool(asset, msg.sender, vaultBal);
                }
                uint256 remain = need - vaultBal;

                // 剩余部分从池内转入托管账户合约，然后再从托管账户合约转给用户
                uint256 poolBal = IERC20(asset).balanceOf(address(this));
                require(poolBal >= remain, "withdraw: pool lacks funds");

                IERC20(asset).transfer(vault, remain);
                UserVault(vault).transferByPool(asset, msg.sender, remain);
            }

            if (r.totalLiquidity >= amount18) {
                r.totalLiquidity -= amount18;
            } else {
                r.totalLiquidity = 0;
            }
            _updateReserveRates(asset);
            emit Withdraw(msg.sender, asset, amountRaw, false, 0);
        }
    }



    // 锁定时间后确认提现
    function claimWithdrawal(address asset) external nonReentrant {
        WithdrawalRequest storage req = userWithdrawRequests[msg.sender][asset];
        require(req.exists, "no request");
        require(block.timestamp >= req.unlockTimestamp, "not unlocked");
        uint256 amount18 = req.amount18;
        require(amount18 > 0, "no amount");

        uint256 raw = PoolUtils.from18(amount18, reserves[asset].decimals);

        // 提现需确保用户必须有托管账户合约
        address vault = _createVaultIfNeeded(msg.sender);

        // 只能从托管账户合约提现,优先使用托管账户合约现有余额
        uint256 vaultBal = UserVault(vault).balanceOf(asset);
        if (vaultBal >= raw) {
            UserVault(vault).transferByPool(asset, msg.sender, raw);
        } else {
            // 先把托管账户合约中的转给用户
            if (vaultBal > 0) {
                UserVault(vault).transferByPool(asset, msg.sender, vaultBal);
            }
            uint256 remain = raw - vaultBal;

            // 剩余部分从池内转入托管账户合约，然后再从托管账户合约转给用户
            uint256 poolBal = IERC20(asset).balanceOf(address(this));
            require(poolBal >= remain, "pool lacks funds");

            IERC20(asset).transfer(vault, remain);
            UserVault(vault).transferByPool(asset, msg.sender, remain);
        }

        // 清空提现申请数据
        req.amount18 = 0;
        req.unlockTimestamp = 0;
        req.exists = false;

        emit ClaimWithdrawal(msg.sender, asset, raw);
    }









    // ------------------------------------------- 可供查询的方法

    function getUserVault(address user) external view returns (address) {
        return userVaults[user];
    }

    // 查询地址是否允许托管账户合约交易
    function isAllowedTarget(address target) external view returns (bool) {
        return allowedTargets[target];
    }

    // 获取当前抵押价值,债务价值,HF
    function getUserAccountData(address user) external view returns (uint256 totalCollateralUSD, uint256 totalDebtUSD, uint256 healthFactor) {
        (uint256 a, uint256 b, uint256 c) = _getUserAccountData(user);
        return (a, b, c);
    }


    function _getUserAccountData(address user) internal view returns (uint256 totalCollateralUSD, uint256 totalDebtUSD, uint256 healthFactor) {
        uint256 collateralUSD = 0;
        uint256 debtUSD = 0;
        uint256 weightedThresholdTimesVal = 0;

        for (uint256 i = 0; i < reserveList.length; i++) {
            address asset = reserveList[i];
            ReserveData storage r = reserves[asset];

            // 查询用户抵押
            uint256 userATokenRaw = AToken(r.aToken).balanceOf(user);
            if (userATokenRaw > 0) {
                uint256 amount18 = PoolUtils.to18(userATokenRaw, r.decimals);
                uint256 price = _getAssetPrice(asset);
                uint256 val = (amount18 * price) / WAD;
                collateralUSD += val;
                weightedThresholdTimesVal += val * r.liquidationThreshold / RAY;
            }

            // 查询用户债务
            uint256 userDebtRaw = VariableDebtToken(r.variableDebtToken).balanceOf(user);
            if (userDebtRaw > 0) {
                uint256 debt18 = PoolUtils.to18(userDebtRaw, r.decimals);
                uint256 price2 = _getAssetPrice(asset);
                uint256 val2 = (debt18 * price2) / WAD;
                debtUSD += val2;
            }
        }

        if (debtUSD == 0) {
            healthFactor = type(uint256).max;
        } else {
            if (weightedThresholdTimesVal == 0) healthFactor = 0;
            else healthFactor = (weightedThresholdTimesVal * RAY) / debtUSD;
        }
        return (collateralUSD, debtUSD, healthFactor);
    }

    // 获取资产池流动性索引
    function getReserveLiquidityIndex(address asset) external view returns (uint256) {
        return reserves[asset].liquidityIndex;
    }


    // 获取债务池流动性索引
    function getReserveVariableBorrowIndex(address asset) external view returns (uint256) {
        return reserves[asset].variableBorrowIndex;
    }





    // ---------------------------------- 管理设置参数

    function setAllowedTarget(address target, bool allowed) external onlyOwner {
        allowedTargets[target] = allowed;
        emit AllowedTargetSet(target, allowed);
    }

    function setCloseFactor(uint256 wadVal) external onlyOwner {
        require(wadVal <= 1e18, "close factor > 1");
        closeFactor = wadVal;
    }

    function setReserveMinLiquidityRatio(address asset, uint256 wadVal) external onlyOwner {
        reserves[asset].minLiquidityRatio = wadVal;
    }










    // --------------------------------------------------- 内部方法

    function _createVaultIfNeeded(address user) internal returns (address) {
        address v = userVaults[user];
        if (v == address(0)) {
            // 创建托管账户合约
            UserVault vault = new UserVault(user, address(this));
            userVaults[user] = address(vault);
            emit VaultCreated(user, address(vault));
            return address(vault);
        }
        return v;
    }

    function _updateReserveState(address asset) internal {
        ReserveData storage r = reserves[asset];
        uint256 dt = block.timestamp - r.lastUpdateTimestamp;
        if (dt == 0) {
            return;
        }

        uint256 indexIncrease = (r.liquidityIndex * r.currentLiquidityRate * dt) / (SECONDS_PER_YEAR * RAY);
        r.liquidityIndex += indexIncrease;
        uint256 borrowIndexIncrease = (r.variableBorrowIndex * r.currentVariableBorrowRate * dt) / (SECONDS_PER_YEAR * RAY);
        r.variableBorrowIndex += borrowIndexIncrease;
        r.lastUpdateTimestamp = block.timestamp;
    }

    function _updateReserveRates(address asset) internal {
        ReserveData storage r = reserves[asset];
        uint256 totalBorrows = WadRayMath.rayMul(r.totalScaledVariableDebt, r.variableBorrowIndex);
        (uint256 liqRate, uint256 varRate) = InterestRateStrategy(r.interestStrategy).calculateRates(r.totalLiquidity, totalBorrows, r.reserveFactor);
        r.currentLiquidityRate = liqRate;
        r.currentVariableBorrowRate = varRate;
    }


    function _getAssetPrice(address asset) internal view returns (uint256) {
        // chainlink获取资产价格
        ReserveData storage r = reserves[asset];
        IAggregatorV3 agg = r.priceOracle;
        require(address(agg) != address(0), "no price oracle");
        (, int256 answer,, ,) = agg.latestRoundData();
        require(answer > 0, "invalid price");
        uint8 pdec = agg.decimals();
        uint256 price = uint256(answer);
        if (pdec == 18) {
            return price;
        }

        if (pdec < 18) {
            return price * (10 ** (18 - pdec));
        }

        return price / (10 ** (pdec - 18));
    }

}
