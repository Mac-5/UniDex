// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UniswapV2Factory} from "./UniswapV2Factory.sol";
import {UniswapV2Pair} from "./UniswapV2Pair.sol";
import {IERC20} from "./interfaces/IERC20.sol";

contract UniswapV2Router {
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    UniswapV2Factory public immutable factory;

    constructor(address _factory) {
        factory = UniswapV2Factory(_factory);
    }

    // ── Internal helpers ─────────────────────────────────────────────────────

    function _getPair(address tokenA, address tokenB) internal view returns (UniswapV2Pair) {
        address pair = factory.getPair(tokenA, tokenB);
        require(pair != address(0), "PAIR_NOT_FOUND");
        return UniswapV2Pair(pair);
    }

    /// @dev Compute optimal deposit amounts given reserves.
    function _optimalAmounts(uint256 amountADesired, uint256 amountBDesired, uint256 rA, uint256 rB)
        internal
        pure
        returns (uint256 amountA, uint256 amountB)
    {
        if (rA == 0 && rB == 0) return (amountADesired, amountBDesired);
        uint256 bOptimal = (amountADesired * rB) / rA;
        if (bOptimal <= amountBDesired) return (amountADesired, bOptimal);
        uint256 aOptimal = (amountBDesired * rA) / rB;
        return (aOptimal, amountBDesired);
    }

    /// @dev Given exact input, compute output with 0.3% fee.
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        public
        pure
        returns (uint256 amountOut)
    {
        require(amountIn > 0, "INSUFFICIENT_INPUT");
        require(reserveIn > 0 && reserveOut > 0, "INSUFFICIENT_LIQUIDITY");
        uint256 amountInWithFee = amountIn * 997;
        amountOut = (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
    }

    /// @dev Given exact output, compute required input with 0.3% fee.
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        public
        pure
        returns (uint256 amountIn)
    {
        require(amountOut > 0, "INSUFFICIENT_OUTPUT");
        require(reserveIn > 0 && reserveOut > 0, "INSUFFICIENT_LIQUIDITY");
        amountIn = (reserveIn * amountOut * 1000) / ((reserveOut - amountOut) * 997) + 1;
    }

    // ── Liquidity ─────────────────────────────────────────────────────────────

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        if (factory.getPair(tokenA, tokenB) == address(0)) factory.createPair(tokenA, tokenB);
        UniswapV2Pair pair = _getPair(tokenA, tokenB);

        (uint112 rA, uint112 rB) = _sortedReserves(pair, tokenA, tokenB);
        (amountA, amountB) = _optimalAmounts(amountADesired, amountBDesired, rA, rB);
        require(amountA >= amountAMin && amountB >= amountBMin, "SLIPPAGE");

        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20(tokenA).transferFrom(msg.sender, address(pair), amountA);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20(tokenB).transferFrom(msg.sender, address(pair), amountB);
        liquidity = pair.mint(to);
    }

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to
    ) external returns (uint256 amountA, uint256 amountB) {
        UniswapV2Pair pair = _getPair(tokenA, tokenB);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        pair.transferFrom(msg.sender, address(pair), liquidity);
        (uint256 amount0, uint256 amount1) = pair.burn(to);

        (address t0,) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        (amountA, amountB) = tokenA == t0 ? (amount0, amount1) : (amount1, amount0);
        require(amountA >= amountAMin && amountB >= amountBMin, "SLIPPAGE");
    }

    // ── Swaps ─────────────────────────────────────────────────────────────────

    /// @notice Swap exact tokens for tokens along a path.
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to
    ) external returns (uint256[] memory amounts) {
        amounts = _getAmountsOut(amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "INSUFFICIENT_OUTPUT");
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20(path[0]).transferFrom(msg.sender, factory.getPair(path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
    }

    /// @notice Swap tokens for exact tokens along a path.
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to
    ) external returns (uint256[] memory amounts) {
        amounts = _getAmountsIn(amountOut, path);
        require(amounts[0] <= amountInMax, "EXCESSIVE_INPUT");
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20(path[0]).transferFrom(msg.sender, factory.getPair(path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
    }

    // ── Internal swap execution ───────────────────────────────────────────────

    function _swap(uint256[] memory amounts, address[] calldata path, address to) internal {
        for (uint256 i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            UniswapV2Pair pair = UniswapV2Pair(factory.getPair(input, output));
            bool inputIs0 = input < output;
            uint256 amountOut = amounts[i + 1];
            (uint256 out0, uint256 out1) = inputIs0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
            address recipient = i < path.length - 2 ? factory.getPair(output, path[i + 2]) : to;
            pair.swap(out0, out1, recipient);
        }
    }

    // ── Quote helpers ─────────────────────────────────────────────────────────

    function _getAmountsOut(uint256 amountIn, address[] calldata path)
        internal
        view
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i; i < path.length - 1; i++) {
            UniswapV2Pair pair = UniswapV2Pair(factory.getPair(path[i], path[i + 1]));
            (uint112 r0, uint112 r1) = pair.getReserves();
            bool is0 = path[i] < path[i + 1];
            amounts[i + 1] = getAmountOut(amounts[i], is0 ? r0 : r1, is0 ? r1 : r0);
        }
    }

    function _getAmountsIn(uint256 amountOut, address[] calldata path)
        internal
        view
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](path.length);
        amounts[amounts.length - 1] = amountOut;
        for (uint256 i = path.length - 1; i > 0; i--) {
            UniswapV2Pair pair = UniswapV2Pair(factory.getPair(path[i - 1], path[i]));
            (uint112 r0, uint112 r1) = pair.getReserves();
            bool is0 = path[i - 1] < path[i];
            amounts[i - 1] = getAmountIn(amounts[i], is0 ? r0 : r1, is0 ? r1 : r0);
        }
    }

    function _sortedReserves(UniswapV2Pair pair, address tokenA, address tokenB)
        internal
        view
        returns (uint112 rA, uint112 rB)
    {
        (uint112 r0, uint112 r1) = pair.getReserves();
        (rA, rB) = tokenA < tokenB ? (r0, r1) : (r1, r0);
    }
}
