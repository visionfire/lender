// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./utils/WadRayMath.sol";
import "./interfaces/ILendingPool.sol";
import "./utils/PoolUtils.sol";

contract AToken is ERC20 {
    using WadRayMath for uint256;

    address public underlying;
    address public pool;
    uint8 public overrideDecimals;

    // 用于通过ray计算用户抵押余额
    mapping(address => uint256) internal _scaledBalances;
    uint256 internal _totalScaledSupply;

    modifier onlyPool() {
        require(msg.sender == pool, "only pool");
        _;
    }

    constructor(
        address _underlying,
        address _pool,
        string memory name_,
        string memory symbol_,
        uint8 _decimals
    ) ERC20(name_, symbol_) {
        underlying = _underlying;
        pool = _pool;
        overrideDecimals = _decimals;
    }

    function decimals() public view virtual override returns (uint8) {
        return overrideDecimals;
    }

    function totalSupply() public view virtual override returns (uint256) {
        uint256 liquidityIndex = ILendingPool(pool).getReserveLiquidityIndex(underlying);
        // 当前的scaledSupply * liquidityIndex
        uint256 total18 = WadRayMath.rayMul(_totalScaledSupply, liquidityIndex);
        return PoolUtils.from18(total18, overrideDecimals);
    }

    // 返回包含利息的抵押凭证余额
    function balanceOf(address account) public view virtual override returns (uint256) {
        uint256 scaled = _scaledBalances[account];
        if (scaled == 0) return 0;
        uint256 liquidityIndex = ILendingPool(pool).getReserveLiquidityIndex(underlying);
        uint256 amount18 = WadRayMath.rayMul(scaled, liquidityIndex);
        return PoolUtils.from18(amount18, overrideDecimals);
    }

    // 转账凭证,抵押也将一并转出
    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        _transferScaled(_msgSender(), to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public virtual override returns (bool) {
        uint256 currentAllowance = allowance(from, _msgSender());
        require(currentAllowance >= amount, "transfer amount exceeds allowance");
        _approve(from, _msgSender(), currentAllowance - amount);
        _transferScaled(from, to, amount);
        return true;
    }

    function _transferScaled(address from, address to, uint256 amount) internal {
        require(to != address(0), "transfer to zero");
        uint256 amount18 = PoolUtils.to18(amount, overrideDecimals);
        uint256 liquidityIndex = ILendingPool(pool).getReserveLiquidityIndex(underlying);
        uint256 scaled = WadRayMath.rayDiv(amount18, liquidityIndex);
        require(_scaledBalances[from] >= scaled, "transfer exceeds scaled balance");
        _scaledBalances[from] -= scaled;
        _scaledBalances[to] += scaled;
        emit Transfer(from, to, amount);
    }

    // 增发凭证atoken
    function mintScaled(address to, uint256 scaledAmount) external onlyPool returns (bool) {
        _scaledBalances[to] += scaledAmount;
        _totalScaledSupply += scaledAmount;
        uint256 liquidityIndex = ILendingPool(pool).getReserveLiquidityIndex(underlying);
        uint256 amount18 = WadRayMath.rayMul(scaledAmount, liquidityIndex);
        emit Transfer(address(0), to, PoolUtils.from18(amount18, overrideDecimals));
        return true;
    }

    // 销毁凭证atoken
    function burnScaled(address from, uint256 scaledAmount) external onlyPool returns (bool) {
        require(_scaledBalances[from] >= scaledAmount, "burn exceed");
        _scaledBalances[from] -= scaledAmount;
        _totalScaledSupply -= scaledAmount;
        uint256 liquidityIndex = ILendingPool(pool).getReserveLiquidityIndex(underlying);
        uint256 amount18 = WadRayMath.rayMul(scaledAmount, liquidityIndex);
        emit Transfer(from, address(0), PoolUtils.from18(amount18, overrideDecimals));
        return true;
    }
}
