// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.12;

import "openzeppelin-contracts/access/Ownable.sol";
import "openzeppelin-contracts/access/AccessControl.sol";
import "./interfaces/IERC20.sol";
import "./libraries/SqrtPriceMath.sol";
import "./libraries/TickMath.sol";
import "./libraries/FullMath.sol";
import "./libraries/SafeCast.sol";
import "./interfaces/IUniV3.sol";


contract UniswapBalancer is Ownable, AccessControl {
    using SafeCast for uint256;

    bool public isOpenedCallback;
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");


    constructor() {
        _setupRole(ADMIN_ROLE, msg.sender);
    }

    modifier onlyAdmin() {
        require(hasRole(ADMIN_ROLE, msg.sender), "Caller is not an admin");
        _;
    }

    struct TickInfo {
        int24 tick;
        int128 liquidityNet;
    }

    // @notice isActiveTokenSame boolean that shows is token that need be equalized by price in the same location
    // for example if WETH in mainPool and secondPool is token0 than true
    // @dev this method passes here to save gas
    struct SwapTokenInfo {
        address mainPool;
        address secondPool;
        address secondPoolToken0;
        address secondPoolToken1;
        bool isActiveTokenSame;
    }

    struct Path {
        address tokenIn;
        address tokenOut;
    }

    /******************************* Swap Manager *******************************/
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata _data
    ) external {
        require(amount0Delta > 0 || amount1Delta > 0, "Incorrect Swap");
        Path memory data = abi.decode(_data, (Path));
        require(isOpenedCallback, "Callback is not allowed");

        (bool isExactInput, uint256 amountToPay) = amount0Delta > 0 ?
            (data.tokenIn < data.tokenOut, uint256(amount0Delta))
            : (data.tokenOut < data.tokenIn, uint256(amount1Delta));

        if (isExactInput) {
            IERC20(data.tokenIn).transfer(msg.sender, amountToPay);
        } else {
            IERC20(data.tokenOut).transfer(msg.sender, amountToPay);
        }
    }

    function swapTokens(SwapTokenInfo calldata swapInfo, TickInfo[] calldata ticksLiquidityNets) external onlyAdmin {
        (int24 tickMain, int24 tickSecond) = (getTickInPool(swapInfo.mainPool), getTickInPool(swapInfo.secondPool));

        int24 tickSecondToCompare = swapInfo.isActiveTokenSame ? tickSecond : absoluteValue(tickSecond);

        if (tickMain != tickSecondToCompare) {
            int24 aimTick = calcAimTick(tickMain, tickSecond, tickSecondToCompare, swapInfo.isActiveTokenSame);
            bool zeroForOne = TickMath.getSqrtRatioAtTick(tickSecond) > TickMath.getSqrtRatioAtTick(aimTick);

            uint256 amountIn = calcInputAmount(
                aimTick,
                tickSecond,
                swapInfo.secondPool,
                ticksLiquidityNets
            );

            (address tokenIn, address tokenOut) = zeroForOne ?
                (swapInfo.secondPoolToken0, swapInfo.secondPoolToken1) :
                (swapInfo.secondPoolToken1, swapInfo.secondPoolToken0);


            isOpenedCallback = true;
            IUniV3(swapInfo.secondPool).swap(
                address(this),
                zeroForOne,
                amountIn.toInt256(),
                TickMath.getSqrtRatioAtTick(aimTick),
                abi.encode(Path(tokenIn, tokenOut))
            );
            isOpenedCallback = false;
        }
    }

    function calcAimTick(
        int24 tickMain,
        int24 tickSecond,
        int24 tickSecondToCompare,
        bool isActiveTokenSame
    ) internal pure returns (int24 aimTick){
        int24 tickDiff = tickMain - tickSecondToCompare;
        if (!isActiveTokenSame && tickSecond < 0) {
            tickDiff = - tickDiff;
        }
        aimTick = tickSecond + tickDiff;
    }


    function calcInputAmount(
        int24 aimTick,
        int24 currentTick,
        address pool,
        TickInfo[] memory tickLiquidityNets
    ) internal view returns (uint256 amountIn) {
        uint128 liquidity = IUniV3(pool).liquidity();
        bool zeroForOne = TickMath.getSqrtRatioAtTick(currentTick) > TickMath.getSqrtRatioAtTick(aimTick);
        uint256 amount0;
        uint256 amount1;

        if (tickLiquidityNets.length == 0) {
            amount0 = SqrtPriceMath.getAmount0Delta(
                TickMath.getSqrtRatioAtTick(currentTick),
                TickMath.getSqrtRatioAtTick(aimTick),
                liquidity,
                true
            );
            amount1 = SqrtPriceMath.getAmount1Delta(
                TickMath.getSqrtRatioAtTick(currentTick),
                TickMath.getSqrtRatioAtTick(aimTick),
                liquidity,
                true
            );
        } else {
            int24 startTick = currentTick;
            for (uint256 i = 0; i < tickLiquidityNets.length; i++) {
                TickInfo memory tickInfo = tickLiquidityNets[i];

                bool isTickInRange = currentTick > aimTick ?
                    ((startTick >= tickInfo.tick) && (tickInfo.tick >= aimTick)) :
                    ((aimTick >= tickInfo.tick) && (tickInfo.tick >= startTick));

                if (isTickInRange) {
                    amount0 += SqrtPriceMath.getAmount0Delta(
                        TickMath.getSqrtRatioAtTick(startTick),
                        TickMath.getSqrtRatioAtTick(tickInfo.tick),
                        liquidity,
                        true
                    );

                    amount1 += SqrtPriceMath.getAmount1Delta(
                        TickMath.getSqrtRatioAtTick(startTick),
                        TickMath.getSqrtRatioAtTick(tickInfo.tick),
                        liquidity,
                        true
                    );

                    startTick = tickInfo.tick;

                    int128 liquidityNet = tickInfo.liquidityNet;
                    unchecked {
                        if (zeroForOne) liquidityNet = -liquidityNet;
                    }

                    liquidity = liquidityNet < 0
                        ? liquidity - uint128(-liquidityNet)
                        : liquidity + uint128(liquidityNet);
                }
            }
            amount0 += SqrtPriceMath.getAmount0Delta(
                TickMath.getSqrtRatioAtTick(startTick),
                TickMath.getSqrtRatioAtTick(aimTick),
                liquidity,
                true
            );

            amount1 += SqrtPriceMath.getAmount1Delta(
                TickMath.getSqrtRatioAtTick(startTick),
                TickMath.getSqrtRatioAtTick(aimTick),
                liquidity,
                true
            );
        }

        amountIn = (zeroForOne ? amount0 : amount1);
        amountIn = getAmountWithCommission(amountIn, pool);

    }

    function getTickInPool(address pool) internal view returns (int24 tick){
        (, tick,,,,,) = IUniV3(pool).slot0();
    }

    function absoluteValue(int24 num) internal pure returns (int24) {
        if (num < 0) {
            return - num;
        } else {
            return num;
        }
    }

    function getAmountWithCommission(uint256 amountIn, address pool) internal view returns (uint256 amount) {
        uint24 feePips = IUniV3(pool).fee();
        amount = amountIn + FullMath.mulDivRoundingUp(amountIn, feePips, 1e6 - feePips);
    }

    function grantAdminRole(address user) public onlyOwner {
        grantRole(ADMIN_ROLE, user);
    }

    function revokeAdminRole(address user) public onlyOwner {
        revokeRole(ADMIN_ROLE, user);
    }

    function withdrawToken(IERC20 token, uint256 amount) external onlyOwner {
        token.transfer(msg.sender, amount);
    }

    function withdrawAllToken(IERC20 token) external onlyOwner {
        uint256 balance = token.balanceOf(address(this));
        token.transfer(msg.sender, balance);
    }
}
