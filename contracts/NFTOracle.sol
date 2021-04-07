// SPDX-License-Identifier: MIT

pragma solidity >=0.5.17 <0.8.0;

import "./lib/SafeMath.sol";
import "./mocks/Ownable.sol";
import "./mocks/IOracle.sol";


interface IUniswapV2Factory {
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    function feeTo() external view returns (address);
    function feeToSetter() external view returns (address);

    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function allPairs(uint) external view returns (address pair);
    function allPairsLength() external view returns (uint);

    function createPair(address tokenA, address tokenB) external returns (address pair);

    function setFeeTo(address) external;
    function setFeeToSetter(address) external;
}

interface IUniswapV2Pair {
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    function name() external pure returns (string memory);
    function symbol() external pure returns (string memory);
    function decimals() external pure returns (uint8);
    function totalSupply() external view returns (uint);
    function balanceOf(address owner) external view returns (uint);
    function allowance(address owner, address spender) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);
    function transfer(address to, uint value) external returns (bool);
    function transferFrom(address from, address to, uint value) external returns (bool);

    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function PERMIT_TYPEHASH() external pure returns (bytes32);
    function nonces(address owner) external view returns (uint);

    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external;

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    function MINIMUM_LIQUIDITY() external pure returns (uint);
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint);
    function price1CumulativeLast() external view returns (uint);
    function kLast() external view returns (uint);

    function mint(address to) external returns (uint liquidity);
    function burn(address to) external returns (uint amount0, uint amount1);
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function sync() external;

    function initialize(address, address) external;
}


// computes square roots using the babylonian mBnbod
// https://en.wikipedia.org/wiki/MBnbods_of_computing_square_roots#Babylonian_mBnbod
library Babylonian {
    function sqrt(uint y) internal pure returns (uint z) {
        if (y > 3) {
            z = y;
            uint x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
        // else z = 0
    }
}

// a library for handling binary fixed point numbers (https://en.wikipedia.org/wiki/Q_(number_format))
library FixedPoint {
    // range: [0, 2**112 - 1]
    // resolution: 1 / 2**112
    struct uq112x112 {
        uint224 _x;
    }

    // range: [0, 2**144 - 1]
    // resolution: 1 / 2**112
    struct uq144x112 {
        uint _x;
    }

    uint8 private constant RESOLUTION = 112;
    uint private constant Q112 = uint(1) << RESOLUTION;
    uint private constant Q224 = Q112 << RESOLUTION;

    // encode a uint112 as a UQ112x112
    function encode(uint112 x) internal pure returns (uq112x112 memory) {
        return uq112x112(uint224(x) << RESOLUTION);
    }

    // encodes a uint144 as a UQ144x112
    function encode144(uint144 x) internal pure returns (uq144x112 memory) {
        return uq144x112(uint(x) << RESOLUTION);
    }

    // divide a UQ112x112 by a uint112, returning a UQ112x112
    function div(uq112x112 memory self, uint112 x) internal pure returns (uq112x112 memory) {
        require(x != 0, 'FixedPoint: DIV_BY_ZERO');
        return uq112x112(self._x / uint224(x));
    }

    // multiply a UQ112x112 by a uint, returning a UQ144x112
    // reverts on overflow
    function mul(uq112x112 memory self, uint y) internal pure returns (uq144x112 memory) {
        uint z;
        require(y == 0 || (z = uint(self._x) * y) / y == uint(self._x), "FixedPoint: MULTIPLICATION_OVERFLOW");
        return uq144x112(z);
    }

    // returns a UQ112x112 which represents the ratio of the numerator to the denominator
    // equivalent to encode(numerator).div(denominator)
    function fraction(uint112 numerator, uint112 denominator) internal pure returns (uq112x112 memory) {
        require(denominator > 0, "FixedPoint: DIV_BY_ZERO");
        return uq112x112((uint224(numerator) << RESOLUTION) / denominator);
    }

    // decode a UQ112x112 into a uint112 by truncating after the radix point
    function decode(uq112x112 memory self) internal pure returns (uint112) {
        return uint112(self._x >> RESOLUTION);
    }

    // decode a UQ144x112 into a uint144 by truncating after the radix point
    function decode144(uq144x112 memory self) internal pure returns (uint144) {
        return uint144(self._x >> RESOLUTION);
    }

    // take the reciprocal of a UQ112x112
    function reciprocal(uq112x112 memory self) internal pure returns (uq112x112 memory) {
        require(self._x != 0, 'FixedPoint: ZERO_RECIPROCAL');
        return uq112x112(uint224(Q224 / self._x));
    }

    // square root of a UQ112x112
    function sqrt(uq112x112 memory self) internal pure returns (uq112x112 memory) {
        return uq112x112(uint224(Babylonian.sqrt(uint(self._x)) << 56));
    }
}

// library with helper mBnbods for oracles that are concerned with computing average prices
library UniswapV2OracleLibrary {
    using FixedPoint for *;

    // helper function that returns the current block timestamp within the range of uint32, i.e. [0, 2**32 - 1]
    function currentBlockTimestamp() internal view returns (uint32) {
        return uint32(block.timestamp % 2 ** 32);
    }

    // produces the cumulative price using counterfactuals to save gas and avoid a call to sync.
    function currentCumulativePrices(
        address pair
    ) internal view returns (uint price0Cumulative, uint price1Cumulative, uint32 blockTimestamp) {
        blockTimestamp = currentBlockTimestamp();
        price0Cumulative = IUniswapV2Pair(pair).price0CumulativeLast();
        price1Cumulative = IUniswapV2Pair(pair).price1CumulativeLast();

        // if time has elapsed since the last update on the pair, mock the accumulated price values
        (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) = IUniswapV2Pair(pair).getReserves();
        if (blockTimestampLast != blockTimestamp) {
            // subtraction overflow is desired
            uint32 timeElapsed = blockTimestamp - blockTimestampLast;
            // addition overflow is desired
            // counterfactual
            price0Cumulative += uint(FixedPoint.fraction(reserve1, reserve0)._x) * timeElapsed;
            // counterfactual
            price1Cumulative += uint(FixedPoint.fraction(reserve0, reserve1)._x) * timeElapsed;
        }
    }
}


/**
 * @title FUN price Oracle
 *      This Oracle calculates the average USD price of FUN based on the FUN-USDT pool and NFT value.
 */
contract NFTOracle is Ownable {
    using FixedPoint for *;

    uint private funUsdPrice0CumulativeLast;
    uint private funUsdPrice1CumulativeLast;
    uint32 private funUsdBlockTimestampLast;

    uint public nftBaseValue;
    uint public nftCurrentValue;
    
    address public funToken;
    IUniswapV2Pair public fun_usd;

    uint256 public funDecimals;
    uint256 public usdDecimals;

    address public controller;
    address public dev;

    event NftCurrentValueUpdated(uint indexed oldValue, uint indexed newValue, uint time);

    modifier onlyControllerOrOwner {
        require(msg.sender == controller || msg.sender == owner(), "FORBIDDEN");
        _;
    }

    modifier onlyDev() {
        require(msg.sender == dev || msg.sender == owner(), "FORBIDDEN");
        _;
    }

    constructor(
        address _controller,
        address _fun,
        address _fun_usd,   // Address of the FUN-USDT pair
        uint _nftBaseValue
        ) public {

        controller = _controller;
        dev = msg.sender;

        funToken = _fun;
        fun_usd = IUniswapV2Pair(_fun_usd);
        
        nftBaseValue = _nftBaseValue;

        funDecimals = uint256(IUniswapV2Pair(fun_usd.token0()).decimals());
        usdDecimals = uint256(IUniswapV2Pair(fun_usd.token1()).decimals());
        if(fun_usd.token0() != funToken) {
            funDecimals = uint256(IUniswapV2Pair(fun_usd.token1()).decimals());
            usdDecimals = uint256(IUniswapV2Pair(fun_usd.token0()).decimals());
        }

        funUsdPrice0CumulativeLast = fun_usd.price0CumulativeLast();
        funUsdPrice1CumulativeLast = fun_usd.price1CumulativeLast();

        (, , funUsdBlockTimestampLast) = fun_usd.getReserves();
    }
    

    function changeDev(address _user) external onlyDev {
        require(dev != _user, 'NO CHANGE');
        dev = _user;
    }

    function changeController(address _user) external onlyControllerOrOwner {
        require(controller != _user, 'NO CHANGE');
        controller = _user;
    }

    function updateNftCurrentValue(uint _value) external onlyDev {
        require(nftCurrentValue != _value, 'NO CHANGE');
        emit NftCurrentValueUpdated(nftCurrentValue, _value, block.timestamp);
        nftCurrentValue = _value;
    }

    // Get the current price of 1 Fun in the smallest USD unit (18 decimals)
    function getCurrentRate() public view returns (uint256) {
        (uint112 reserve0, uint112 reserve1, ) = fun_usd.getReserves();
        uint256 funReserve = uint256(reserve0);
        uint256 usdReserve = uint256(reserve1);
        if(fun_usd.token0() != funToken) {
            funReserve = uint256(reserve1);
            usdReserve = uint256(reserve0);
        }
        if(funDecimals > usdDecimals) {
            usdReserve = usdReserve * 10** (funDecimals - usdDecimals);
        } else if(funDecimals < usdDecimals) {
            funReserve = funReserve * 10** (usdDecimals - funDecimals);
        }
        
        return 10** usdDecimals * usdReserve / funReserve;
    }

    // Get the average price of 1 Fun in the smallest USD unit (18 decimals)
    function getRateInfo() public view returns (uint256, uint256, uint32, uint) {
        (uint price0Cumulative, uint price1Cumulative, uint32 _blockTimestamp) =
            UniswapV2OracleLibrary.currentCumulativePrices(address(fun_usd));

        if(_blockTimestamp <= funUsdBlockTimestampLast) {
            return (price0Cumulative, price1Cumulative, _blockTimestamp, getCurrentRate());
        }

        uint256 unit = 10** funDecimals;
        uint256 diff = price0Cumulative - funUsdPrice0CumulativeLast;
        if(fun_usd.token0() != funToken) {
            diff = price1Cumulative - funUsdPrice1CumulativeLast;
        }

        FixedPoint.uq112x112 memory funUsdAverage = FixedPoint.uq112x112(uint224(unit * diff / (_blockTimestamp - funUsdBlockTimestampLast)));

        return (price0Cumulative, price1Cumulative, _blockTimestamp, funUsdAverage.mul(1).decode144());
    }

    // Update "last" state variables to current values
   function update() external onlyControllerOrOwner {
        uint funUsdAverage;
        (funUsdPrice0CumulativeLast, funUsdPrice1CumulativeLast, funUsdBlockTimestampLast, funUsdAverage) = getRateInfo();
    }

    // Return the average price since last update
    function getRate() public view returns (uint) {
        (, , , uint funUsdAverage) = getRateInfo();
        return funUsdAverage;
    }


    // Return the complex average price since last update
    function getData() external view returns (uint) {
        uint price = getRate();
        if(nftBaseValue > 0 && nftCurrentValue > 0) {
           price = price * nftCurrentValue / nftBaseValue;
        }
        return price;
    }
}
