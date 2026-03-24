// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "./interfaces/IERC20.sol";
import {Math} from "./libraries/Math.sol";

contract UniswapV2Pair {
    // ── ERC-20 LP token ──────────────────────────────────────────────────────
    // forge-lint: disable-next-line(screaming-snake-case-const)
    string public constant name = "UniDex LP";
    // forge-lint: disable-next-line(screaming-snake-case-const)
    string public constant symbol = "ULP";
    // forge-lint: disable-next-line(screaming-snake-case-const)
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        return _transfer(msg.sender, to, value);
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= value;
        }
        return _transfer(from, to, value);
    }

    function _transfer(address from, address to, uint256 value) internal returns (bool) {
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
        return true;
    }

    function _mint(address to, uint256 value) internal {
        totalSupply += value;
        balanceOf[to] += value;
        emit Transfer(address(0), to, value);
    }

    function _burn(address from, uint256 value) internal {
        balanceOf[from] -= value;
        totalSupply -= value;
        emit Transfer(from, address(0), value);
    }

    // ── Pair ─────────────────────────────────────────────────────────────────
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    address public factory;
    address public token0;
    address public token1;

    uint112 private reserve0;
    uint112 private reserve1;

    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event Swap(address indexed sender, uint256 in0, uint256 in1, uint256 out0, uint256 out1, address indexed to);
    event Sync(uint112 reserve0, uint112 reserve1);

    constructor() {
        factory = msg.sender;
    }

    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, "FORBIDDEN");
        token0 = _token0;
        token1 = _token1;
    }

    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
    }

    function _update(uint256 bal0, uint256 bal1) private {
        // forge-lint: disable-next-line(unsafe-typecast)
        reserve0 = uint112(bal0);
        // forge-lint: disable-next-line(unsafe-typecast)
        reserve1 = uint112(bal1);
        emit Sync(reserve0, reserve1);
    }

    /// @notice Called by router after transferring tokens into the pair.
    function mint(address to) external returns (uint256 liquidity) {
        (uint112 _r0, uint112 _r1) = getReserves();
        uint256 bal0 = IERC20(token0).balanceOf(address(this));
        uint256 bal1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = bal0 - _r0;
        uint256 amount1 = bal1 - _r1;

        if (totalSupply == 0) {
            liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock
        } else {
            liquidity = Math.min((amount0 * totalSupply) / _r0, (amount1 * totalSupply) / _r1);
        }
        require(liquidity > 0, "INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(to, liquidity);
        _update(bal0, bal1);
        emit Mint(msg.sender, amount0, amount1);
    }

    /// @notice Called by router after transferring LP tokens into the pair.
    function burn(address to) external returns (uint256 amount0, uint256 amount1) {
        uint256 liquidity = balanceOf[address(this)];
        uint256 bal0 = IERC20(token0).balanceOf(address(this));
        uint256 bal1 = IERC20(token1).balanceOf(address(this));

        amount0 = (liquidity * bal0) / totalSupply;
        amount1 = (liquidity * bal1) / totalSupply;
        require(amount0 > 0 && amount1 > 0, "INSUFFICIENT_LIQUIDITY_BURNED");

        _burn(address(this), liquidity);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20(token0).transfer(to, amount0);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20(token1).transfer(to, amount1);
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)));
        emit Burn(msg.sender, amount0, amount1, to);
    }

    /// @notice Low-level swap. Caller must ensure amounts satisfy the invariant.
    function swap(uint256 amount0Out, uint256 amount1Out, address to) external {
        require(amount0Out > 0 || amount1Out > 0, "INSUFFICIENT_OUTPUT");
        (uint112 _r0, uint112 _r1) = getReserves();
        require(amount0Out < _r0 && amount1Out < _r1, "INSUFFICIENT_LIQUIDITY");

        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        if (amount0Out > 0) IERC20(token0).transfer(to, amount0Out);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        if (amount1Out > 0) IERC20(token1).transfer(to, amount1Out);

        uint256 bal0 = IERC20(token0).balanceOf(address(this));
        uint256 bal1 = IERC20(token1).balanceOf(address(this));

        uint256 in0 = bal0 > _r0 - amount0Out ? bal0 - (_r0 - amount0Out) : 0;
        uint256 in1 = bal1 > _r1 - amount1Out ? bal1 - (_r1 - amount1Out) : 0;
        require(in0 > 0 || in1 > 0, "INSUFFICIENT_INPUT");

        // k invariant with 0.3% fee: (bal0*1000 - in0*3) * (bal1*1000 - in1*3) >= r0*r1*1000^2
        uint256 adj0 = bal0 * 1000 - in0 * 3;
        uint256 adj1 = bal1 * 1000 - in1 * 3;
        require(adj0 * adj1 >= uint256(_r0) * uint256(_r1) * 1_000_000, "K");

        _update(bal0, bal1);
        emit Swap(msg.sender, in0, in1, amount0Out, amount1Out, to);
    }
}
