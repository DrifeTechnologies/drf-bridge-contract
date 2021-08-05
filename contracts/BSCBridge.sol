// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.5;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/**
 * @dev Interface of the BEP20 standard used by the DRF token
 */
interface IBEP20 {
    /**
     * @dev Moves `amount` tokens from the caller's account to `recipient`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address recipient, uint256 amount)
        external
        returns (bool);

    /**
     * @dev Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply.
     *
     * Requirements
     *
     * - `msg.sender` must be the token owner
     */
    function mintTo(address account, uint256 amount) external returns (bool);

    /**
     * @dev Destroys `amount` tokens from `account`, decreasing the total supply.
     *
     * Requirements
     *
     * - `msg.sender` must be the token owner
     */
    function burnFrom(address account, uint256 amount) external returns (bool);
}

/**
 * @dev BSC side of Drife Bridge smart contracts setup to move DRF tokens across
 * Ethereum and other EVM compatible chains like Binance Smart Chain.
 *   - Min swap value: 10 DRF (configurable)
 *   - Max swap value: Balance amount available
 *   - Swap fee: 0.1% (configurable)
 *   - Finality: (~75 sec.)
 *     - ETH: 7 blocks
 *     - BSC: 15 blocks
 *   - Reference implementation: https://github.com/anyswap/mBTC/blob/master/contracts/ProxySwapAsset.sol
 */
contract BSCBridge is Ownable {
    using SafeMath for uint256;

    // BSC Token contract address
    address public tokenBSC;

    // List of TXs on ETH side that were processed
    mapping(bytes32 => bool) txHashes;

    // Fee Rate in percentage with two units of precision after the decimal to store as integer
    // e.g. 1%, 0.05%, 0.5% multiplied by 10000 (100 * 100) become 10000, 500, 5000 respectively
    uint256 public feeRate;

    // Minimum and Maximun fee deductible for swaps
    uint256 public minFee;
    uint256 public maxFee;

    // Fee accumulated from swap out transactions
    uint256 public accumulatedFee;

    // Minimum Swap amount of DRF (100 DRF = 100 * 10**18)
    uint256 public minSwapAmount;

    // Fee Type for event logging
    enum FeeType {
        RATE,
        MAX,
        MIN
    }

    /**
     * @dev Event emitted upon the swap out call.
     * @param swapOutAddress The BSC address of the swap out initiator.
     * @param swapInAddress The ETH address to which the tokens are swapped.
     * @param amount The amount of tokens getting locked and swapped from BSC.
     */
    event SwappedOut(
        address indexed swapOutAddress,
        address indexed swapInAddress,
        uint256 amount
    );

    /**
     * @dev Event emitted upon the swap in call.
     * @param txHash Transaction hash on ETH where the swap has beed initiated.
     * @param swapInAddress The BSC address to which the tokens are swapped.
     * @param amountSent The amount of tokens to be released on BSC.
     * @param fee The amount of tokens deducted as fee for carrying out the swap.
     */
    event SwappedIn(
        bytes32 indexed txHash,
        address indexed swapInAddress,
        uint256 amountSent,
        uint256 fee
    );

    /**
     * @dev Event emitted upon changing fee params in the contract.
     * @param oldFeeParam The fee param before tx.
     * @param newFeeParam The new value of the fee param to be updated.
     * @param feeType The fee param to be updated.
     */
    event FeeUpdate(uint256 oldFeeParam, uint256 newFeeParam, FeeType feeType);

    constructor(
        address _BSCtokenAddress,
        uint256 _feeRate,
        uint256 _minSwapAmount,
        uint256 _minFee,
        uint256 _maxFee
    ) {
        tokenBSC = _BSCtokenAddress;
        feeRate = _feeRate;
        minSwapAmount = _minSwapAmount;
        minFee = _minFee;
        maxFee = _maxFee;
        accumulatedFee = 0;
    }

    /**
     * @dev Initiate a token transfer from BSC to ETH.
     * @param amount The amount of tokens getting locked and swapped from BSC.
     * @param swapInAddress The ETH address to which the tokens are swapped.
     */
    function SwapOut(uint256 amount, address swapInAddress)
        external
        returns (bool)
    {
        require(swapInAddress != address(0), "Bridge: invalid addr");
        require(amount >= minSwapAmount, "Bridge: invalid amount");

        require(
            IBEP20(tokenBSC).burnFrom(msg.sender, amount),
            "Bridge: invalid transfer"
        );
        emit SwappedOut(msg.sender, swapInAddress, amount);
        return true;
    }

    /**
     * @dev Initiate a token transfer from ETH to BSC.
     * @param txHash Transaction hash on ETH where the swap has been initiated.
     * @param to The BSC address to which the tokens are swapped.
     * @param amount The amount of tokens swapped.
     */
    function SwapIn(
        bytes32 txHash,
        address to,
        uint256 amount
    ) external onlyOwner returns (bool) {
        require(txHash != bytes32(0), "Bridge: invalid tx");
        require(to != address(0), "Bridge: invalid addr");
        require(txHashes[txHash] == false, "Bridge: dup tx");
        txHashes[txHash] = true;

        // Calculate fee based on `feeRate` percentage of amount
        // and to be at least `minFee` and at most `maxFee`
        // fee = amount * feeRate / 100 / 10000
        uint256 fee = amount.mul(feeRate).div(1000000) >= minFee &&
            amount.mul(feeRate).div(1000000) <= maxFee
            ? amount.mul(feeRate).div(1000000)
            : amount.mul(feeRate).div(1000000) < minFee
            ? minFee
            : maxFee;

        // Automatically check for amount > fee before transferring otherwise throws safemath error
        require(
            IBEP20(tokenBSC).mintTo(
                to,
                amount.sub(fee, "Bridge: invalid amount")
            ),
            "Bridge: invalid transfer"
        );
        accumulatedFee = accumulatedFee.add(fee);

        emit SwappedIn(txHash, to, amount.sub(fee), fee);
        return true;
    }

    /**
     * @dev Update the fee rate on the current chain. Only callable by the owner
     * @param newFeeRate uint - the new fee rate that applies to the current side of the bridge
     */
    function updateFeeRate(uint256 newFeeRate) external onlyOwner {
        uint256 oldFeeRate = feeRate;
        feeRate = newFeeRate;
        emit FeeUpdate(oldFeeRate, newFeeRate, FeeType.RATE);
    }

    /**
     * @dev Update the max fee on the current chain. Only callable by the owner
     * @param newMaxFee uint - the new max fee that applies to the current side bridge
     */
    function updateMaxFee(uint256 newMaxFee) external onlyOwner {
        uint256 oldMaxFee = maxFee;
        maxFee = newMaxFee;
        emit FeeUpdate(oldMaxFee, newMaxFee, FeeType.MAX);
    }

    /**
     * @dev Update the min fee on the current chain. Only callable by the owner
     * @param newMinFee uint - the new max fee that applies to the current side bridge
     */
    function updateMinFee(uint256 newMinFee) external onlyOwner {
        uint256 oldMinFee = minFee;
        minFee = newMinFee;
        emit FeeUpdate(oldMinFee, newMinFee, FeeType.MIN);
    }

    /**
     * @dev Withdraw liquidity from the bridge contract to a BSC address.
     * Only callable by the owner.
     * @param to The address to which the tokens are swapped.
     * @param amount The amount of tokens to be released.
     */
    function withdrawLiquidity(address to, uint256 amount) external onlyOwner {
        require(
            amount <
                (IERC20(tokenBSC).balanceOf(address(this)) - accumulatedFee),
            "Bridge: invalid amount"
        );
        IBEP20(tokenBSC).transfer(to, amount);
    }

    /**
     * @dev Withdraw liquidity from the bridge contract to a BSC address.
     * Only callable by the owner.
     * @param to The address to which the tokens are swapped.
     */
    function withdrawAccumulatedFee(address to) external onlyOwner {
        IBEP20(tokenBSC).transfer(to, accumulatedFee);
        accumulatedFee = 0;
    }
}
