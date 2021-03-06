const Rates = artifacts.require("./Rates.sol");
const moment = require("moment");

module.exports = {
    newRatesAsserts,
    get rates() {
        return rates;
    },
};

let rates = null;

before(async function () {
    rates = await Rates.at(Rates.address);
});

async function newRatesAsserts(tx, symbols, newRates) {
    const currentTime = moment().utc().unix();

    assert.equal(tx.logs.length, symbols.length, "setMultipleRates / setRate should emmit RateChanged event(s)");

    for (let i = 0; i < symbols.length; i++) {
        assert.equal(tx.logs[i].event, "RateChanged", "RateChanged event should be emited for " + i + ". symbol");

        assert.equal(
            web3.utils.hexToUtf8(tx.logs[i].args.symbol), // hexToUtf8 removes trailing zeros from bytes32 ascii
            web3.utils.hexToUtf8(symbols[i]),
            "symbol " + i + ". should be set in RateChanged event"
        );

        assert.equal(
            tx.logs[i].args.newRate.toString(),
            newRates[i].toString(),
            "newRate " + i + ". should be set in RateChanged event"
        );

        const rateInfo = await rates.rates(symbols[i]);

        assert.equal(
            rateInfo[0].toString(),
            newRates[i].toString(),
            "new rate should be set for " + i + ". symbol in rates contract"
        );

        assert(currentTime >= rateInfo[1] - 2, "lastUpdated should be >= current time - 2 for " + i + ". symbol");
        assert(currentTime <= rateInfo[1] + 1, "lastUpdated should be <= current time + 1 for " + i + ". symbol");
    }
}
