const tokenTestHelpers = require("./helpers/tokenTestHelpers.js");
const testHelpers = require("./helpers/testHelpers.js");
const MonetarySupervisor = artifacts.require("./MonetarySupervisor.sol");
const AugmintToken = artifacts.require("./TokenAEur.sol");

const BN = web3.utils.BN;

let augmintToken = null;
let monetarySupervisor = null;
let newMS;
let newToken;

contract("token conversion tests", (accounts) => {
    before(async () => {
        augmintToken = tokenTestHelpers.augmintToken;
        monetarySupervisor = tokenTestHelpers.monetarySupervisor;

        newToken = await AugmintToken.new(accounts[0], tokenTestHelpers.feeAccount.address);

        newMS = await MonetarySupervisor.new(
            accounts[0],
            newToken.address,
            tokenTestHelpers.augmintReserves.address,
            tokenTestHelpers.interestEarnedAccount.address,
            200000,
            200000,
            500000
        );

        await Promise.all([
            tokenTestHelpers.feeAccount.grantPermission(newMS.address, web3.utils.asciiToHex("NoTransferFee")),
            newToken.grantPermission(newMS.address, web3.utils.asciiToHex("MonetarySupervisor")),
            newToken.grantPermission(accounts[0], web3.utils.asciiToHex("StabilityBoard")),
            newMS.grantPermission(accounts[0], web3.utils.asciiToHex("StabilityBoard")),
        ]);
    });

    it("should set accepted legacy Augmint token", async function () {
        const legacyToken = accounts[1];
        const tx = await monetarySupervisor.setAcceptedLegacyAugmintToken(legacyToken, true);
        testHelpers.logGasUse(this, tx, "setAcceptedLegacyAugmintToken");

        let [newState] = await Promise.all([
            monetarySupervisor.acceptedLegacyAugmintTokens(legacyToken),
            testHelpers.assertEvent(monetarySupervisor, "AcceptedLegacyAugmintTokenChanged", {
                augmintTokenAddress: legacyToken,
                newAcceptedState: true,
            }),
        ]);

        assert.equal(newState, true);

        const tx2 = await monetarySupervisor.setAcceptedLegacyAugmintToken(legacyToken, false);
        testHelpers.logGasUse(this, tx2, "setAcceptedLegacyAugmintToken");

        [newState] = await Promise.all([
            monetarySupervisor.acceptedLegacyAugmintTokens(legacyToken),
            testHelpers.assertEvent(monetarySupervisor, "AcceptedLegacyAugmintTokenChanged", {
                augmintTokenAddress: legacyToken,
                newAcceptedState: false,
            }),
        ]);
        assert.equal(newState, false);
    });

    it("only permitted set accepted legacy Augmint token", async function () {
        await testHelpers.expectThrow(
            monetarySupervisor.setAcceptedLegacyAugmintToken(accounts[1], false, { from: accounts[1] })
        );
    });

    it("should convert legacy tokens", async function () {
        const amount = new BN(50000);
        const account = accounts[0];

        await Promise.all([
            tokenTestHelpers.issueToken(accounts[0], account, amount),
            newMS.setAcceptedLegacyAugmintToken(augmintToken.address, true),
        ]);

        const [oldTokenSupplyBefore, newTokenSupplyBefore, oldTokenBalBefore, newTokenBalBefore] = await Promise.all([
            augmintToken.totalSupply(),
            newToken.totalSupply(),
            augmintToken.balanceOf(account),
            newToken.balanceOf(account),
        ]);

        const tx = await augmintToken.transferAndNotify(newMS.address, amount, 0, { from: account });
        testHelpers.logGasUse(this, tx, "transferAndNotify - convertLegacyTokens");

        const [oldTokenSupplyAfter, newTokenSupplyAfter, oldTokenBalAfter, newTokenBalAfter] = await Promise.all([
            augmintToken.totalSupply(),
            newToken.totalSupply(),
            augmintToken.balanceOf(account),
            newToken.balanceOf(account),
            testHelpers.assertEvent(newToken, "Transfer", {
                from: "0x0000000000000000000000000000000000000000",
                to: account,
                amount: amount.toString(),
            }),
            testHelpers.assertEvent(newMS, "LegacyTokenConverted", {
                oldTokenAddress: augmintToken.address,
                account,
                amount: amount.toString(),
            }),
        ]);

        assert.equal(oldTokenSupplyAfter.toString(), oldTokenSupplyBefore.sub(amount).toString(), "old Token Supply");
        assert.equal(newTokenSupplyAfter.toString(), newTokenSupplyBefore.add(amount).toString(), "new Token Supply");
        assert.equal(oldTokenBalAfter.toString(), oldTokenBalBefore.sub(amount).toString(), "old token balance");
        assert.equal(newTokenBalAfter.toString(), newTokenBalBefore.add(amount).toString(), "new token balance");
    });

    it("only accepted tokens should be converted", async function () {
        const amount = 1000;
        const account = accounts[0];

        await Promise.all([
            newMS.setAcceptedLegacyAugmintToken(augmintToken.address, false),
            tokenTestHelpers.issueToken(accounts[0], account, amount),
        ]);

        await testHelpers.expectThrow(augmintToken.transferAndNotify(newMS.address, amount, 0, { from: account }));
    });
});
