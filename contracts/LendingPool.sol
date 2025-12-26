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

    // 提现请求记录
    mapping(address => mapping(address => WithdrawalRequest)) public userWithdrawRequests;

    uint256 public constant RAY = WadRayMath.RAY;
    uint256 public constant WAD = WadRayMath.WAD;
    uint256 public constant SECONDS_PER_YEAR = WadRayMath.SECONDS_PER_YEAR;

    // 默认的最大清算比例 50%
    uint256 public closeFactor = 5e17;


    event ReserveInitialized(address indexed asset, address indexed aToken, address indexed variableDebtToken);
    event Supply(address indexed user, address indexed asset, uint256 amountRaw);
    event Borrow(address indexed user, address indexed asset, uint256 amountRaw);
    event Repay(address indexed user, address indexed asset, uint256 amountRaw);
    event LiquidationCall(address indexed collateralAsset, address indexed debtAsset, address indexed user, address liquidator, uint256 debtRepaidRaw, uint256 collateralSeizedRaw);



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
        //
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

        // 增发债务token
        uint256 scaled = WadRayMath.rayDiv(amount18, r.variableBorrowIndex);
        VariableDebtToken(r.variableDebtToken).mintScaled(msg.sender, scaled);
        r.totalScaledVariableDebt += scaled;

        // 转账资产
        uint256 poolBal = IERC20(asset).balanceOf(address(this));
        require(poolBal >= amountRaw, "exceed liquidity");
        if (r.totalLiquidity >= amount18) {
            r.totalLiquidity -= amount18;
        } else {
            r.totalLiquidity = 0;
        }

        IERC20(asset).transfer(msg.sender, amountRaw);

        // 更新计算利息
        _updateReserveRates(asset);

        emit Borrow(msg.sender, asset, amountRaw);
    }


    // 还款
    function repay(address asset, uint256 amountRaw) external nonReentrant {
        require(reserves[asset].asset != address(0), "reserve not init");
        ReserveData storage r = reserves[asset];

        // 更新资产索引,获取之前的利息
        _updateReserveState(asset);

        // 转回资产还债
        IERC20(asset).transferFrom(msg.sender, address(this), amountRaw);
        uint256 amount18 = PoolUtils.to18(amountRaw, r.decimals);
        uint256 scaled = WadRayMath.rayDiv(amount18, r.variableBorrowIndex);
        if (scaled > r.totalScaledVariableDebt) {
            scaled = r.totalScaledVariableDebt;
        }

        VariableDebtToken(r.variableDebtToken).burnScaled(msg.sender, scaled);
        if (r.totalScaledVariableDebt >= scaled) {
            r.totalScaledVariableDebt -= scaled;
        }  else {
            r.totalScaledVariableDebt = 0;
        }

        r.totalLiquidity += amount18;

        // 更新计算利息
        _updateReserveRates(asset);

        emit Repay(msg.sender, asset, amountRaw);
    }


    // 清算
    function liquidationCall(address collateralAsset, address debtAsset, address user, uint256 debtToCoverRaw) external nonReentrant {
        require(reserves[collateralAsset].asset != address(0) && reserves[debtAsset].asset != address(0), "invalid assets");
        (uint256 collUSD, uint256 debtUSD, uint256 hf) = _getUserAccountData(user);
        require(hf < RAY, "user not liquidatable");

        ReserveData storage debtR = reserves[debtAsset];
        ReserveData storage collR = reserves[collateralAsset];

        // 根据最大债务清算偿还比例计算最大清算还款量
        uint256 userDebtRaw = VariableDebtToken(debtR.variableDebtToken).balanceOf(user);
        uint256 maxRepay = (userDebtRaw * closeFactor) / 1e18;
        if (debtToCoverRaw > maxRepay) {
            debtToCoverRaw = maxRepay;
        }

        require(debtToCoverRaw > 0, "no repayment required");

        // 先直接将清算人的资产转给pool用于帮借款用户还债
        IERC20(debtAsset).transferFrom(msg.sender, address(this), debtToCoverRaw);

        // burn借款人用户的债务
        uint256 amount18 = PoolUtils.to18(debtToCoverRaw, debtR.decimals);
        uint256 scaledDebt = WadRayMath.rayDiv(amount18, debtR.variableBorrowIndex);
        VariableDebtToken(debtR.variableDebtToken).burnScaled(user, scaledDebt);
        if (debtR.totalScaledVariableDebt >= scaledDebt) {
            debtR.totalScaledVariableDebt -= scaledDebt;
        }  else {
            debtR.totalScaledVariableDebt = 0;
        }

        debtR.totalLiquidity += amount18;

        // 获取资产和抵押品价格,计算清算奖励
        uint256 priceDebt = _getAssetPrice(debtAsset);
        uint256 priceColl = _getAssetPrice(collateralAsset);
        uint256 numerator = amount18 * priceDebt;
        uint256 numeratorWithBonus = WadRayMath.rayMul(numerator, collR.liquidationBonus);
        uint256 collAmount18 = numeratorWithBonus / priceColl;
        uint256 collRaw = PoolUtils.from18(collAmount18, collR.decimals);

        // 判断借款人用户的凭证token
        uint256 userATokenRaw = AToken(collR.aToken).balanceOf(user);
        if (userATokenRaw < collRaw) {
            collRaw = userATokenRaw;
        }

        // burn借款人用户的抵押凭证
        uint256 collAmount18ForBurn = PoolUtils.to18(collRaw, collR.decimals);
        uint256 scaledToBurn = WadRayMath.rayDiv(collAmount18ForBurn, collR.liquidityIndex);
        AToken(collR.aToken).burnScaled(user, scaledToBurn);

        // 将奖励和抵押品转给清算人
        IERC20(collateralAsset).transfer(msg.sender, collRaw);

        // 更新资产流动性索引和利率和债务流动性索引和利率
        _updateReserveState(collateralAsset);
        _updateReserveState(debtAsset);
        _updateReserveRates(collateralAsset);
        _updateReserveRates(debtAsset);

        emit LiquidationCall(collateralAsset, debtAsset, user, msg.sender, debtToCoverRaw, collRaw);
    }


    // 提现
    function withdraw(address asset, uint256 amountRaw) external nonReentrant {
        ReserveData storage r = reserves[asset];
        require(r.asset != address(0), "reserve not init");


    }

    // 申请提现
    function claimWithdrawal(address asset) external nonReentrant {

    }







    // ------------------------------------------- 可供查询的方法

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

    function setCloseFactor(uint256 wadVal) external onlyOwner {
        require(wadVal <= 1e18, "close factor > 1");
        closeFactor = wadVal;
    }

    function setReserveMinLiquidityRatio(address asset, uint256 wadVal) external onlyOwner {
        reserves[asset].minLiquidityRatio = wadVal;
    }










    // --------------------------------------------------- 内部方法

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
