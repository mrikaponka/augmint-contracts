const SafeMath = artifacts.require("./SafeMath.sol");
const TokenAEur = artifacts.require("./TokenAEur.sol");
const FeeAccount = artifacts.require("./FeeAccount.sol");

module.exports = async function(deployer, network, accounts) {
    deployer.link(SafeMath, TokenAEur);
    await deployer.deploy(
        TokenAEur,
        FeeAccount.address,
        2000, // transferFeePt in parts per million = 0.2%
        200, // min: 0.02 A-EUR
        50000 // max fee: 5 A-EUR
    );

    const tokenAEur = TokenAEur.at(TokenAEur.address);
    await tokenAEur.grantMultiplePermissions(accounts[0], ["MonetaryBoard"]);
    await tokenAEur.grantMultiplePermissions(FeeAccount.address, ["NoFeeTransferContracts"]);
};
