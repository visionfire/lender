// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./utils/WadRayMath.sol";
import "./interfaces/ILendingPool.sol";
import "./utils/PoolUtils.sol";


contract VariableDebtToken is ERC20 {
    using WadRayMath for uint256;

    address public underlying;
    address public pool;
    uint8 public overrideDecimals;

    mapping(address => uint256) internal _scaledBalances;
    uint256 internal _totalScaledSupply;

    modifier onlyPool() {
        require(msg.sender == pool, "only pool");
        _;
    }

    constructor(address _underlying, address _pool, string memory name_, string memory symbol_, uint8 _decimals)
    ERC20(name_, symbol_) {
        underlying = _underlying;
        pool = _pool;
        overrideDecimals = _decimals;
    }

    function decimals() public view virtual override returns (uint8) {
        return overrideDecimals;
    }

    function totalSupply() public view virtual override returns (uint256) {
        uint256 borrowIndex = ILendingPool(pool).getReserveVariableBorrowIndex(underlying);
        uint256 total18 = WadRayMath.rayMul(_totalScaledSupply, borrowIndex);
        return PoolUtils.from18(total18, overrideDecimals);
    }

    function balanceOf(address account) public view virtual override returns (uint256) {
        uint256 scaled = _scaledBalances[account];
        if (scaled == 0) return 0;
        uint256 borrowIndex = ILendingPool(pool).getReserveVariableBorrowIndex(underlying);
        uint256 amount18 = WadRayMath.rayMul(scaled, borrowIndex);
        return PoolUtils.from18(amount18, overrideDecimals);
    }


    // 需要屏蔽的方法，禁用债务转移

    function transfer(address, uint256) public virtual override returns (bool) {
        revert("transfer fail");
    }

    function transferFrom(address, address, uint256) public virtual override returns (bool) {
        revert("transfer fail");
    }

    function approve(address, uint256) public virtual override returns (bool) {
        revert("approve fail");
    }

    function allowance(address, address) public view virtual override returns (uint256) {
        return 0;
    }


    function mintScaled(address to, uint256 scaledAmount) external onlyPool returns (bool) {
        _scaledBalances[to] += scaledAmount;
        _totalScaledSupply += scaledAmount;
        uint256 borrowIndex = ILendingPool(pool).getReserveVariableBorrowIndex(underlying);
        uint256 amount18 = WadRayMath.rayMul(scaledAmount, borrowIndex);
        emit Transfer(address(0), to, PoolUtils.from18(amount18, overrideDecimals));
        return true;
    }

    function burnScaled(address from, uint256 scaledAmount) external onlyPool returns (bool) {
        require(_scaledBalances[from] >= scaledAmount, "burn exceed");
        _scaledBalances[from] -= scaledAmount;
        _totalScaledSupply -= scaledAmount;
        uint256 borrowIndex = ILendingPool(pool).getReserveVariableBorrowIndex(underlying);
        uint256 amount18 = WadRayMath.rayMul(scaledAmount, borrowIndex);
        emit Transfer(from, address(0), PoolUtils.from18(amount18, overrideDecimals));
        return true;
    }
}
