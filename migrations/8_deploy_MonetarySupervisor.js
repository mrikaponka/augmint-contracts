const SafeMath = artifacts.require("./SafeMath.sol");
const TokenAEur = artifacts.require("./TokenAEur.sol");
const MonetarySupervisor = artifacts.require("./MonetarySupervisor.sol");
const InterestEarnedAccount = artifacts.require("./InterestEarnedAccount.sol");
const AugmintReserves = artifacts.require("./AugmintReserves.sol");

module.exports = async function(deployer) {
    deployer.link(SafeMath, MonetarySupervisor);

    await deployer.deploy(
        MonetarySupervisor,
        TokenAEur.address,
        AugmintReserves.address,
        InterestEarnedAccount.address,

        /* Parameters Used to ensure totalLoanAmount or totalLockedAmount difference is withing limit and system also works
            when any of those 0 or low. */
        200000 /* ltdDifferenceLimit = 20%  allow lock or loan if Loan To Deposut ratio stay within 1 +- this param
                                                stored as parts per million */,
        50000000 /* allowedLtdDifferenceAmount =5,000 A-EUR - if totalLoan and totalLock difference is less than that
                                        then allow loan or lock even if ltdDifference limit would go off with it */
    );

    const interestEarnedAccount = InterestEarnedAccount.at(InterestEarnedAccount.address);
    const tokenAEur = TokenAEur.at(TokenAEur.address);
    const augmintReserves = AugmintReserves.at(AugmintReserves.address);
    await Promise.all([
        interestEarnedAccount.grantPermission(MonetarySupervisor.address, "MonetarySupervisorContract"),
        tokenAEur.grantPermission(MonetarySupervisor.address, "MonetarySupervisorContract"),
        tokenAEur.grantPermission(MonetarySupervisor.address, "NoFeeTransferContracts"),
        augmintReserves.grantPermission(MonetarySupervisor.address, "MonetarySupervisorContract")
    ]);
};
