// SPDX-License-Identifier: MIT

pragma solidity >=0.5.17 <0.8.0;

import "./lib/SafeMath.sol";
import "./lib/SafeMathInt.sol";
import "./lib/UInt256Lib.sol";
import "./mocks/Ownable.sol";
import "./mocks/IOracle.sol";

interface IFunToken {
    function totalSupply() external view returns (uint256);
    function rebase(uint256 epoch, int256 supplyDelta) external returns (uint256);
}

/**
 * @title Fun's Master
 * @dev Controller for an elastic supply currency based on the uFragments Ideal Money protocol a.k.a. Ampleforth.
 *      uFragments operates symmetrically on expansion and contraction. It will both split and
 *      combine coins to maintain a stable unit price.
 *
 *      This component regulates the token supply of the uFragments ERC20 token in response to
 *      market oracles.
 */
contract Master is Ownable {
    using SafeMath for uint256;
    using SafeMathInt for int256;
    using UInt256Lib for uint256;

    struct Transaction {
        bool enabled;
        address destination;
        bytes data;
    }

    event TransactionFailed(address indexed destination, uint index, bytes data);

    // Stable ordering is not guaranteed.
    Transaction[] public transactions;

    event LogRebase(
        uint256 indexed epoch,
        uint256 exchangeRate,
        int256 requestedSupplyAdjustment,
        uint256 price,
        uint256 lastPrice,
        uint256 lastTotalSupply,
        uint256 timestampSec
    );

    IFunToken public funToken;

    // Market oracle provides the token/USD exchange rate as an 18 decimal fixed point number.
    IOracle public marketOracle;

    // If the current exchange rate is within this fractional distance from the target, no supply
    // update is performed. Fixed point number--same format as the rate.
    // (ie) abs(rate - targetRate) / targetRate < deviationThreshold, then no supply change.
    // DECIMALS Fixed point number.
    uint256 public deviationThreshold;

    // More than this much time must pass between rebase operations.
    uint256 public rebaseCooldown;

    // Block timestamp of last rebase operation
    uint256 public lastRebaseTimestampSec;

    // The number of rebase cycles since inception
    uint256 public epoch;

    uint256 private constant DECIMALS = 18;

    // Due to the expression in computeSupplyDelta(), MAX_RATE * MAX_SUPPLY must fit into an int256.
    // Both are 18 decimals fixed point numbers.
    uint256 private constant MAX_RATE = 10**6 * 10**DECIMALS;
    // MAX_SUPPLY = MAX_INT256 / MAX_RATE
    uint256 private constant MAX_SUPPLY = ~(uint256(1) << 255) / MAX_RATE;

    // Rebase will remain restricted to the owner until the final Oracle is deployed and battle-tested.
    // Ownership will be renounced after this inital period.
    
    bool public rebaseLocked; 
    uint256 public lastPrice;
    uint256 public lastTotalSupply;
    int256 public latestSupplyDelta;

    constructor(address _funToken) public {
        deviationThreshold = 5 * 10 ** (DECIMALS-2);

        rebaseCooldown = 1 days;
        lastRebaseTimestampSec = 0;
        epoch = 0;
        rebaseLocked = true;
        
        funToken = IFunToken(_funToken);
    }

    function setRebaseLocked(bool _locked) external onlyOwner {
        rebaseLocked = _locked;
    }

    function setRebaseCooldown(uint256 _rebaseCooldown) external onlyOwner {
        rebaseCooldown = _rebaseCooldown;
    }
    /**
     * @notice Returns true if the cooldown timer has expired since the last rebase.
     *
     */
     
    function canRebase() public view returns (bool) {
        return ((!rebaseLocked || isOwner()) && lastRebaseTimestampSec.add(rebaseCooldown) < now);
    }
    
    function cooldownExpiryTimestamp() public view returns (uint256) {
        return lastRebaseTimestampSec.add(rebaseCooldown);
    }

    /**
     * @notice Initiates a new rebase operation, provided the minimum time period has elapsed.
     *
     */
     
    function rebase() external {
        require(address(marketOracle) != address(0), "Oracle not set");
        require(canRebase(), "Rebase not allowed");

        lastRebaseTimestampSec = now;

        epoch = epoch.add(1);
        
        (uint256 exchangeRate, , int256 supplyDelta) = getRebaseValues();
        lastPrice = marketOracle.getRate();
        lastTotalSupply = funToken.totalSupply();
        uint256 supplyAfterRebase = funToken.rebase(epoch, supplyDelta);
        latestSupplyDelta = supplyDelta;
        
        require(supplyAfterRebase <= MAX_SUPPLY, 'rebase overflow');
        
        for (uint i = 0; i < transactions.length; i++) {
            Transaction storage t = transactions[i];
            if (t.enabled) {
                bool result =
                    externalCall(t.destination, t.data);
                if (!result) {
                    emit TransactionFailed(t.destination, i, t.data);
                    revert("Transaction Failed");
                }
            }
        }
        
        marketOracle.update();
        
        emit LogRebase(epoch, exchangeRate, supplyDelta, marketOracle.getCurrentRate(), lastPrice, lastTotalSupply, now);
    }
    
    /**
     * @notice Calculates the supplyDelta and returns the current set of values for the rebase
     *
     * @dev The supply adjustment equals (_totalSupply * DeviationFromTargetRate) / rebaseLag
     *      Where DeviationFromTargetRate is (MarketOracleRate - targetRate) / targetRate
     * 
     */    
    
    function getRebaseValues() public view returns (uint256, uint256, int256) {

        uint256 targetRate = 10 ** DECIMALS;
        uint256 exchangeRate = marketOracle.getData();

        if (exchangeRate > MAX_RATE) {
            exchangeRate = MAX_RATE;
        }

        int256 supplyDelta = computeSupplyDelta(exchangeRate, targetRate);

        // Apply the dampening factor.
        if (supplyDelta < 0) {
            supplyDelta = supplyDelta.div(2);
        } else {
            supplyDelta = supplyDelta.div(5);                   
        }

        if (supplyDelta > 0 && funToken.totalSupply().add(uint256(supplyDelta)) > MAX_SUPPLY) {
            supplyDelta = (MAX_SUPPLY.sub(funToken.totalSupply())).toInt256Safe();
        }

        return (exchangeRate, targetRate, supplyDelta);
    }


    /**
     * @return Computes the total supply adjustment in response to the exchange rate
     *         and the targetRate.
     */
    function computeSupplyDelta(uint256 rate, uint256 targetRate)
        internal
        view
        returns (int256)
    {
        if (withinDeviationThreshold(rate, targetRate)) {
            return 0;
        }

        // supplyDelta = totalSupply * (rate - targetRate) / targetRate
        int256 targetRateSigned = targetRate.toInt256Safe();
        return funToken.totalSupply().toInt256Safe()
            .mul(rate.toInt256Safe().sub(targetRateSigned))
            .div(targetRateSigned);
    }

    /**
     * @param rate The current exchange rate, an 18 decimal fixed point number.
     * @param targetRate The target exchange rate, an 18 decimal fixed point number.
     * @return If the rate is within the deviation threshold from the target rate, returns true.
     *         Otherwise, returns false.
     */
    function withinDeviationThreshold(uint256 rate, uint256 targetRate)
        internal
        view
        returns (bool)
    {
        uint256 absoluteDeviationThreshold = targetRate.mul(deviationThreshold)
            .div(10 ** DECIMALS);

        return (rate >= targetRate && rate.sub(targetRate) < absoluteDeviationThreshold)
            || (rate < targetRate && targetRate.sub(rate) < absoluteDeviationThreshold);
    }
    
    /**
     * @notice Sets the reference to the market oracle.
     * @param marketOracle_ The address of the market oracle contract.
     */
    function setMarketOracle(IOracle marketOracle_)
        external
        onlyOwner
    {
        marketOracle = marketOracle_;
    }
    
    /**
     * @notice Adds a transaction that gets called for a downstream receiver of rebases
     * @param destination Address of contract destination
     * @param data Transaction data payload
     */
    function addTransaction(address destination, bytes calldata data)
        external
        onlyOwner
    {
        transactions.push(Transaction({
            enabled: true,
            destination: destination,
            data: data
        }));
    }

    /**
     * @param index Index of transaction to remove.
     *              Transaction ordering may have changed since adding.
     */
    function removeTransaction(uint index)
        external
        onlyOwner
    {
        require(index < transactions.length, "index out of bounds");

        if (index < transactions.length - 1) {
            transactions[index] = transactions[transactions.length - 1];
        }

        transactions.pop();
    }

    /**
     * @param index Index of transaction. Transaction ordering may have changed since adding.
     * @param enabled True for enabled, false for disabled.
     */
    function setTransactionEnabled(uint index, bool enabled)
        external
        onlyOwner
    {
        require(index < transactions.length, "index must be in range of stored tx list");
        transactions[index].enabled = enabled;
    }

    /**
     * @return Number of transactions, both enabled and disabled, in transactions list.
     */
    function transactionsSize()
        external
        view
        returns (uint256)
    {
        return transactions.length;
    }

    /**
     * @dev wrapper to call the encoded transactions on downstream consumers.
     * @param destination Address of destination contract.
     * @param data The encoded data payload.
     * @return True on success
     */
    function externalCall(address destination, bytes memory data)
        internal
        returns (bool)
    {
        bool result;
        assembly {  // solhint-disable-line no-inline-assembly
            // "Allocate" memory for output
            // (0x40 is where "free memory" pointer is stored by convention)
            let outputAddress := mload(0x40)

            // First 32 bytes are the padded length of data, so exclude that
            let dataAddress := add(data, 32)

            result := call(
                sub(gas(), 34710),
                destination,
                0, // transfer value in wei
                dataAddress,
                mload(data),  // Size of the input, in bytes. Stored in position 0 of the array.
                outputAddress,
                0  // Output is ignored, therefore the output size is zero
            )
        }
        return result;
    }    
    
}
