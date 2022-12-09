// SPDX-License-Identifier: MIT

pragma solidity 0.8.16;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "./BasicSpell.sol";
import "../libraries/UniV3/UniV3WrappedLibMockup.sol";
import "../interfaces/IWIchiFarm.sol";
import "../interfaces/ichi/IICHIVault.sol";
import "../interfaces/uniswap/v3/IUniswapV3Pool.sol";
import "../interfaces/uniswap/v3/IUniswapV3SwapCallback.sol";

contract IchiVaultSpell is BasicSpell, IUniswapV3SwapCallback {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    struct Strategy {
        address vault;
        uint256 maxPositionSize;
    }

    /// @dev temperory state used to store uni v3 pool when swapping on uni v3
    IUniswapV3Pool private swapPool;

    /// @dev poolId => ichi vault
    Strategy[] public strategies;
    /// @dev poolId => collateral token => maxLTV
    mapping(uint256 => mapping(address => uint256)) public maxLTV;
    /// @dev address of ICHI farm wrapper
    IWIchiFarm public wIchiFarm;
    /// @dev address of ICHI token
    address public ICHI;

    modifier existingStrategy(uint256 poolId) {
        if (strategies[poolId].vault == address(0))
            revert NOT_EXIST_STRATEGY(address(this), poolId);

        _;
    }

    modifier onlyWhitelistedCollateral(uint256 poolId, address col) {
        if (maxLTV[poolId][col] == 0) revert COL_NOT_WHITELISTED(poolId, col);

        _;
    }

    modifier withinMaxSize(uint256 poolId, uint256 posSize) {
        if (posSize > strategies[poolId].maxPositionSize)
            revert EXCEED_MAX_LIMIT(poolId);

        _;
    }

    function initialize(
        IBank _bank,
        address _werc20,
        address _weth,
        address _wichiFarm
    ) external initializer {
        __BasicSpell_init(_bank, _werc20, _weth);

        wIchiFarm = IWIchiFarm(_wichiFarm);
        ICHI = address(wIchiFarm.ICHI());
        IWIchiFarm(_wichiFarm).setApprovalForAll(address(_bank), true);
    }

    /**
     * @notice Owner privileged function to add vault
     * @param vault Address of ICHI angel vault
     */
    function addStrategy(address vault, uint256 maxPosSize) external onlyOwner {
        if (vault == address(0)) revert ZERO_ADDRESS();
        strategies.push(Strategy({vault: vault, maxPositionSize: maxPosSize}));
    }

    function addCollaterals(
        uint256 poolId,
        address[] memory collaterals,
        uint256[] memory maxLTVs
    ) external existingStrategy(poolId) onlyOwner {
        if (collaterals.length != maxLTVs.length || collaterals.length == 0)
            revert INPUT_ARRAY_MISMATCH();

        for (uint256 i = 0; i < collaterals.length; i++) {
            maxLTV[poolId][collaterals[i]] = maxLTVs[i];
        }
    }

    /**
     * @notice Internal function to deposit assets on ICHI Vault
     * @param collToken Isolated collateral token address
     * @param collAmount Amount of isolated collateral
     * @param borrowToken Token address to borrow
     * @param borrowAmount amount to borrow from Bank
     */
    function depositInternal(
        uint256 poolId,
        address collToken,
        address borrowToken,
        uint256 collAmount,
        uint256 borrowAmount
    ) internal {
        Strategy memory strategy = strategies[poolId];

        // 1. Lend isolated collaterals on compound
        doLend(collToken, collAmount);

        // 2. Borrow specific amounts
        doBorrow(borrowToken, borrowAmount);

        // 3. Add liquidity - Deposit on ICHI Vault
        IICHIVault vault = IICHIVault(strategy.vault);
        bool isTokenA = vault.token0() == borrowToken;
        uint256 balance = IERC20(borrowToken).balanceOf(address(this));
        ensureApprove(borrowToken, address(vault));
        if (isTokenA) {
            vault.deposit(balance, 0, address(this));
        } else {
            vault.deposit(0, balance, address(this));
        }
    }

    /**
     * @notice External function to deposit assets on IchiVault
     * @param collToken Collateral Token address to deposit (e.g USDC)
     * @param collAmount Amount of user's collateral (e.g USDC)
     * @param borrowToken Address of token to borrow
     * @param borrowAmount Amount to borrow from Bank
     */
    function openPosition(
        uint256 poolId,
        address collToken,
        address borrowToken,
        uint256 collAmount,
        uint256 borrowAmount
    )
        external
        existingStrategy(poolId)
        onlyWhitelistedCollateral(poolId, collToken)
        withinMaxSize(poolId, borrowAmount)
    {
        // 1-3 Deposit on ichi vault
        depositInternal(
            poolId,
            collToken,
            borrowToken,
            collAmount,
            borrowAmount
        );

        // 4. Put collateral - ICHI Vault Lp Token
        address vault = strategies[poolId].vault;
        doPutCollateral(vault, IERC20(vault).balanceOf(address(this)));
    }

    /**
     * @notice External function to deposit assets on IchiVault and farm in Ichi Farm
     * @param collToken Collateral Token address to deposit (e.g USDC)
     * @param collAmount Amount of user's collateral (e.g USDC)
     * @param borrowToken Address of token to borrow
     * @param borrowAmount Amount to borrow from Bank
     * @param farmingPid Pool Id of vault lp on ICHI Farm
     */
    function openPositionFarm(
        uint256 poolId,
        address collToken,
        address borrowToken,
        uint256 collAmount,
        uint256 borrowAmount,
        uint256 farmingPid
    )
        external
        existingStrategy(poolId)
        onlyWhitelistedCollateral(poolId, collToken)
        withinMaxSize(poolId, borrowAmount)
    {
        Strategy memory strategy = strategies[poolId];
        address lpToken = wIchiFarm.ichiFarm().lpToken(farmingPid);
        if (strategy.vault != lpToken) revert INCORRECT_LP(lpToken);

        // 1-3 Deposit on ichi vault
        depositInternal(
            poolId,
            collToken,
            borrowToken,
            collAmount,
            borrowAmount
        );

        // 4. Take out collateral
        (, address posCollToken, uint256 collId, uint256 collSize, ) = bank
            .getCurrentPositionInfo();
        if (collSize > 0) {
            (uint256 decodedPid, ) = wIchiFarm.decodeId(collId);
            if (farmingPid != decodedPid) revert INCORRECT_PID(farmingPid);
            if (posCollToken != address(wIchiFarm))
                revert INCORRECT_COLTOKEN(posCollToken);
            bank.takeCollateral(collSize);
            wIchiFarm.burn(collId, collSize);
        }

        // 5. Deposit on farming pool, put collateral
        ensureApprove(strategy.vault, address(wIchiFarm));
        uint256 lpAmount = IERC20(strategy.vault).balanceOf(address(this));
        uint256 id = wIchiFarm.mint(farmingPid, lpAmount);
        bank.putCollateral(address(wIchiFarm), id, lpAmount);
    }

    /**
     * @dev Increase isolated collateral of position
     * @param token Isolated collateral token address
     * @param amount Amount of token to increase position
     */
    function increasePosition(address token, uint256 amount) external {
        // 1. Get user input amounts
        doLend(token, amount);
    }

    /**
     * @dev Reduce isolated collateral of position
     * @param token Isolated collateral token address
     * @param amount Amount of token to reduce position
     */
    function reducePosition(address token, uint256 amount) external {
        doWithdraw(token, amount);
        doRefund(token);
    }

    function withdrawInternal(
        uint256 poolId,
        address collToken,
        address borrowToken,
        uint256 amountRepay,
        uint256 amountLpWithdraw,
        uint256 amountUWithdraw
    ) internal {
        Strategy memory strategy = strategies[poolId];

        IICHIVault vault = IICHIVault(strategy.vault);
        // 2. Remove Liquidity - Withdraw from ICHI Vault
        if (address(vault) == address(0))
            revert LP_NOT_WHITELISTED(address(vault));
        uint256 positionId = bank.POSITION_ID();

        // 2. Compute repay amount if MAX_INT is supplied (max debt)
        if (amountRepay == type(uint256).max) {
            amountRepay = bank.borrowBalanceCurrent(positionId, borrowToken);
        }

        // 3. Calculate actual amount to remove
        uint256 amtLPToRemove = vault.balanceOf(address(this)) -
            amountLpWithdraw;

        // 4. Remove liquidity
        vault.withdraw(amtLPToRemove, address(this));

        // 5. Swap withdrawn tokens to initial deposit token
        bool isTokenA = vault.token0() == borrowToken;
        uint256 amountToSwap = IERC20(
            isTokenA ? vault.token1() : vault.token0()
        ).balanceOf(address(this));
        if (amountToSwap > 0) {
            swapPool = IUniswapV3Pool(vault.pool());
            swapPool.swap(
                address(this),
                // if withdraw token is Token0, then swap token1 -> token0 (false)
                !isTokenA,
                int256(amountToSwap),
                isTokenA
                    ? TickMath.MAX_SQRT_RATIO - 1 // Token0 -> Token1
                    : TickMath.MIN_SQRT_RATIO + 1, // Token1 -> Token0
                abi.encode(address(this))
            );
        }

        // 6. Withdraw isolated collateral from Bank
        doWithdraw(collToken, amountUWithdraw);

        // 7. Repay
        doRepay(borrowToken, amountRepay);

        // 8. Refund
        doRefund(borrowToken);
        doRefund(collToken);
    }

    /**
     * @notice External function to withdraw assets from ICHI Vault
     * @param collToken Token address to withdraw (e.g USDC)
     * @param borrowToken Token address to withdraw (e.g USDC)
     * @param lpTakeAmt Amount of ICHI Vault LP token to take out from Bank
     * @param amountRepay Amount to repay the loan
     * @param amountLpWithdraw Amount of ICHI Vault LP to withdraw from ICHI Vault
     * @param amountUWithdraw Amount of Isolated collateral to withdraw from Compound
     */
    function closePosition(
        uint256 poolId,
        address collToken,
        address borrowToken,
        uint256 lpTakeAmt,
        uint256 amountRepay,
        uint256 amountLpWithdraw,
        uint256 amountUWithdraw
    )
        external
        existingStrategy(poolId)
        onlyWhitelistedCollateral(poolId, collToken)
    {
        // 1. Take out collateral
        doTakeCollateral(strategies[poolId].vault, lpTakeAmt);

        withdrawInternal(
            poolId,
            collToken,
            borrowToken,
            amountRepay,
            amountLpWithdraw,
            amountUWithdraw
        );
    }

    function closePositionFarm(
        uint256 poolId,
        address collToken,
        address borrowToken,
        uint256 lpTakeAmt,
        uint256 amountRepay,
        uint256 amountLpWithdraw,
        uint256 amountUWithdraw
    )
        external
        existingStrategy(poolId)
        onlyWhitelistedCollateral(poolId, collToken)
    {
        address vault = strategies[poolId].vault;
        (, address posCollToken, uint256 collId, , ) = bank
            .getCurrentPositionInfo();
        if (IWIchiFarm(posCollToken).getUnderlyingToken(collId) != vault)
            revert INCORRECT_UNDERLYING(vault);
        if (posCollToken != address(wIchiFarm))
            revert INCORRECT_COLTOKEN(posCollToken);

        // 1. Take out collateral
        bank.takeCollateral(lpTakeAmt);
        wIchiFarm.burn(collId, lpTakeAmt);

        // 2-8. remove liquidity
        withdrawInternal(
            poolId,
            collToken,
            borrowToken,
            amountRepay,
            amountLpWithdraw,
            amountUWithdraw
        );

        // 9. Refund ichi token
        doCutRewardsFee(ICHI);
        doRefund(ICHI);
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external override {
        if (msg.sender != address(swapPool)) revert NOT_FROM_UNIV3(msg.sender);
        address payer = abi.decode(data, (address));

        if (amount0Delta > 0) {
            if (payer == address(this)) {
                IERC20Upgradeable(swapPool.token0()).safeTransfer(
                    msg.sender,
                    uint256(amount0Delta)
                );
            } else {
                IERC20Upgradeable(swapPool.token0()).safeTransferFrom(
                    payer,
                    msg.sender,
                    uint256(amount0Delta)
                );
            }
        } else if (amount1Delta > 0) {
            if (payer == address(this)) {
                IERC20Upgradeable(swapPool.token1()).safeTransfer(
                    msg.sender,
                    uint256(amount1Delta)
                );
            } else {
                IERC20Upgradeable(swapPool.token1()).safeTransferFrom(
                    payer,
                    msg.sender,
                    uint256(amount1Delta)
                );
            }
        }
    }
}
