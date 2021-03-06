/*
 Generic token / ETH rates contract.
 only callable by trusted price oracles.
 Being regularly called by a price oracle
 Note: symbol is always the "pegged symbol" not the token's own symbol!
*/
pragma solidity 0.4.24;

import "./generic/SafeMath.sol";
import "./generic/Restricted.sol";


contract Rates is Restricted {
    using SafeMath for uint256;

    struct RateInfo {
        uint rate; // how much token is worth 1 ETH, i.e. token/ETH rate, 0 rate means no rate info available
        uint lastUpdated;
    }

    // mapping pegged currency symbol => rate.
    // all rates are stored as token amounts (with 2 decimals for EUR, i.e. if EUR/ETH = 989.12 then rate = 98912)
    mapping(bytes32 => RateInfo) public rates;

    event RateChanged(bytes32 symbol, uint newRate);

    constructor(address permissionGranterContract) public Restricted(permissionGranterContract) {} // solhint-disable-line no-empty-blocks

    function setRate(bytes32 symbol, uint newRate) external restrict("RatesFeeder") {
        rates[symbol] = RateInfo(newRate, now);
        emit RateChanged(symbol, newRate);
    }

    function setMultipleRates(bytes32[] symbols, uint[] newRates) external restrict("RatesFeeder") {
        require(symbols.length == newRates.length, "symbols and newRates lengths must be equal");
        for (uint256 i = 0; i < symbols.length; i++) {
            rates[symbols[i]] = RateInfo(newRates[i], now);
            emit RateChanged(symbols[i], newRates[i]);
        }
    }

    function convertFromWei(bytes32 bSymbol, uint weiValue) external view returns(uint value) {
        require(rates[bSymbol].rate > 0, "rates[bSymbol] must be > 0");
        return weiValue.mul(rates[bSymbol].rate).roundedDiv(1000000000000000000);
    }

    function convertToWei(bytes32 bSymbol, uint value) external view returns(uint weiValue) {
        // next line would revert with div by zero but require to emit reason
        require(rates[bSymbol].rate > 0, "rates[bSymbol] must be > 0");
        /* TODO: can we make this not loosing max scale? */
        return value.mul(1000000000000000000).roundedDiv(rates[bSymbol].rate);
    }

}
