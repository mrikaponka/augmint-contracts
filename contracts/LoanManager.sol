/*
    Contract to manage Augmint token loan contracts backed by ETH
    For flows see: https://github.com/Augmint/augmint-contracts/blob/master/docs/loanFlow.png

    TODO:
        - create MonetarySupervisor interface and use it instead?
        - make data arg generic bytes?
        - make collect() run as long as gas provided allows
*/
pragma solidity 0.4.24;

import "./Rates.sol";
import "./generic/Restricted.sol";
import "./generic/SafeMath.sol";
import "./interfaces/AugmintTokenInterface.sol";
import "./MonetarySupervisor.sol";


contract LoanManager is Restricted, TokenReceiver {
    using SafeMath for uint256;

    uint constant PPM_FACTOR = 1e6;
    uint constant WEI_FACTOR = 1e18;
    uint constant WEI_PER_PPM_FACTOR = WEI_FACTOR / PPM_FACTOR; // = 1e12

    enum LoanState { Open, Repaid, DoNotUse, Collected } // NB: DoNotUse state is kept for backwards compatibility only (so the ordinal of 'Collected' does not shift), as the name states: do not use it.

    struct LoanProduct {
        uint minDisbursedAmount;        // 0: minimum loanAmount, with decimals set in AugmintToken.decimals (i.e. token amount)
        uint32 term;                    // 1: term length (in seconds)
        uint32 discountRate;            // 2: discountRate (in parts per million, i.e. 10,000 = 1%)
        uint32 initialCollateralRatio;  // 3: initial collateral ratio: [collateral value (in token) / repayment value (in token)] (in ppm).
        uint32 defaultingFeePt;         // 4: % of repaymentAmount (in parts per million, i.e. 50,000 = 5%)
        bool isActive;                  // 5: flag to enable/disable product
        uint32 minCollateralRatio;      // 6: minimum collateral ratio: [collateral value (in token) / repayment value (in token)] (in ppm), defines the margin, zero means no margin.
    }

    /* NB: we don't need to store loan parameters because loan products can't be altered (only disabled/enabled) */
    struct LoanData {
        uint collateralAmount;      // 0: collateral amount (in wei)
        uint repaymentAmount;       // 1: repayment amount (in token)
        address borrower;           // 2: address of the owner of this loan
        uint32 productId;           // 3: id of the product from which this loan was created
        LoanState state;            // 4: current status of the loan (Open/Repaid/Collected)
        uint40 maturity;            // 5: expiration date (in epoch seconds)
    }

    LoanProduct[] public products;

    LoanData[] public loans;
    mapping(address => uint[]) public accountLoans;  // owner account address =>  array of loan Ids

    Rates public rates; // instance of token/ETH rate provider contract
    AugmintTokenInterface public augmintToken; // instance of token contract
    MonetarySupervisor public monetarySupervisor;

    event NewLoan(uint32 productId, uint loanId, address indexed borrower, uint collateralAmount, uint loanAmount,
        uint repaymentAmount, uint40 maturity, uint currentRate);

    event LoanChanged(uint loanId, address indexed borrower, uint collateralAmount,
        uint repaymentAmount, uint currentRate);

    event LoanProductActiveStateChanged(uint32 productId, bool newState);

    event LoanProductAdded(uint32 productId);

    event LoanRepaid(uint loanId, address indexed borrower, uint currentRate);

    event LoanCollected(uint loanId, address indexed borrower, uint collectedCollateral,
        uint releasedCollateral, uint defaultingFee, uint currentRate);

    event SystemContractsChanged(Rates newRatesContract, MonetarySupervisor newMonetarySupervisor);

    constructor(address permissionGranterContract, AugmintTokenInterface _augmintToken,
                    MonetarySupervisor _monetarySupervisor, Rates _rates)
    public Restricted(permissionGranterContract) {
        augmintToken = _augmintToken;
        monetarySupervisor = _monetarySupervisor;
        rates = _rates;
    }

    function addLoanProduct(uint32 term, uint32 discountRate, uint32 initialCollateralRatio, uint minDisbursedAmount,
                                uint32 defaultingFeePt, bool isActive, uint32 minCollateralRatio)
    external restrict("StabilityBoard") {
        uint _newProductId = products.push(
            LoanProduct(minDisbursedAmount, term, discountRate, initialCollateralRatio, defaultingFeePt, isActive, minCollateralRatio)
        ) - 1;

        uint32 newProductId = uint32(_newProductId);
        require(newProductId == _newProductId, "productId overflow");

        emit LoanProductAdded(newProductId);
    }

    function setLoanProductActiveState(uint32 productId, bool newState)
    external restrict ("StabilityBoard") {
        require(productId < products.length, "invalid productId"); // next line would revert but require to emit reason
        products[productId].isActive = newState;
        emit LoanProductActiveStateChanged(productId, newState);
    }

    function newEthBackedLoan(uint32 productId, uint minRate) external payable {
        require(productId < products.length, "invalid productId"); // next line would revert but require to emit reason
        LoanProduct storage product = products[productId];
        require(product.isActive, "product must be in active state"); // valid product

        uint currentRate = getCurrentRate();
        require(currentRate >= minRate, "current rate is below minimum");

        // calculate loan values based on ETH sent in with Tx
        uint collateralValueInToken = _convertFromWei(currentRate, msg.value);
        uint repaymentAmount = collateralValueInToken.mul(PPM_FACTOR).div(product.initialCollateralRatio);

        uint loanAmount;
        (loanAmount, ) = calculateLoanValues(product, repaymentAmount);

        require(loanAmount >= product.minDisbursedAmount, "loanAmount must be >= minDisbursedAmount");

        uint expiration = now.add(product.term);
        uint40 maturity = uint40(expiration);
        require(maturity == expiration, "maturity overflow");

        // Create new loan
        uint loanId = loans.push(
            LoanData(msg.value, repaymentAmount, msg.sender, productId, LoanState.Open, maturity)
        ) - 1;

        // Store ref to new loan
        accountLoans[msg.sender].push(loanId);

        // Issue tokens and send to borrower
        monetarySupervisor.issueLoan(msg.sender, loanAmount);

        emit NewLoan(productId, loanId, msg.sender, msg.value, loanAmount, repaymentAmount, maturity, currentRate);
    }

    function addExtraCollateral(uint loanId) external payable {
        require(loanId < loans.length, "invalid loanId");
        LoanData storage loan = loans[loanId];
        require(loan.state == LoanState.Open, "loan state must be Open");
        LoanProduct storage product = products[loan.productId];
        require(product.minCollateralRatio > 0, "not a margin type loan");

        loan.collateralAmount = loan.collateralAmount.add(msg.value);

        emit LoanChanged(loanId, loan.borrower, loan.collateralAmount, loan.repaymentAmount, getCurrentRate());
    }

    /* repay loan, called from AugmintToken's transferAndNotify
     Flow for repaying loan:
        1) user calls token contract's transferAndNotify loanId passed in data arg
        2) transferAndNotify transfers tokens to the Lender contract
        3) transferAndNotify calls Lender.transferNotification with lockProductId
    */
    // from arg is not used as we allow anyone to repay a loan:
    function transferNotification(address, uint repaymentAmount, uint loanId) external {
        require(msg.sender == address(augmintToken), "msg.sender must be augmintToken");

        _repayLoan(loanId, repaymentAmount);
    }

    function collect(uint[] loanIds) external {
        uint currentRate = getCurrentRate();

        /* when there are a lots of loans to be collected then
             the client need to call it in batches to make sure tx won't exceed block gas limit.
         Anyone can call it - can't cause harm as it only allows to collect loans which they are defaulted
         TODO: optimise defaulting fee calculations
        */
        uint totalLoanAmountCollected;
        uint totalCollateralToCollect;
        uint totalDefaultingFee;
        for (uint i = 0; i < loanIds.length; i++) {
            (uint loanAmount, uint defaultingFee, uint collateralToCollect) = _collectLoan(loanIds[i], currentRate);
            totalLoanAmountCollected = totalLoanAmountCollected.add(loanAmount);
            totalDefaultingFee = totalDefaultingFee.add(defaultingFee);
            totalCollateralToCollect = totalCollateralToCollect.add(collateralToCollect);
        }

        if (totalCollateralToCollect > 0) {
            address(monetarySupervisor.augmintReserves()).transfer(totalCollateralToCollect);
        }

        if (totalDefaultingFee > 0) {
            address(augmintToken.feeAccount()).transfer(totalDefaultingFee);
        }

        monetarySupervisor.loanCollectionNotification(totalLoanAmountCollected);// update KPIs

    }

    /* to allow upgrade of Rates and MonetarySupervisor contracts */
    function setSystemContracts(Rates newRatesContract, MonetarySupervisor newMonetarySupervisor)
    external restrict("StabilityBoard") {
        rates = newRatesContract;
        monetarySupervisor = newMonetarySupervisor;
        emit SystemContractsChanged(newRatesContract, newMonetarySupervisor);
    }

    function getProductCount() external view returns (uint) {
        return products.length;
    }

    // returns <chunkSize> loan products starting from some <offset>:
    // [ productId, minDisbursedAmount, term, discountRate, initialCollateralRatio, defaultingFeePt, maxLoanAmount, isActive, minCollateralRatio ]
    function getProducts(uint offset, uint16 chunkSize)
    external view returns (uint[9][]) {
        uint limit = SafeMath.min(offset.add(chunkSize), products.length);
        uint[9][] memory response = new uint[9][](limit.sub(offset));

        for (uint i = offset; i < limit; i++) {
            LoanProduct storage product = products[i];
            response[i - offset] = [i, product.minDisbursedAmount, product.term, product.discountRate,
                    product.initialCollateralRatio, product.defaultingFeePt,
                    monetarySupervisor.getMaxLoanAmount(product.minDisbursedAmount), product.isActive ? 1 : 0,
                    product.minCollateralRatio];
        }
        return response;
    }

    function getLoanCount() external view returns (uint) {
        return loans.length;
    }

    /* returns <chunkSize> loans starting from some <offset>. Loans data encoded as:
        [loanId, collateralAmount, repaymentAmount, borrower, productId,
              state, maturity, disbursementTime, loanAmount, interestAmount, marginCallRate] */
    function getLoans(uint offset, uint16 chunkSize)
    external view returns (uint[12][]) {
        uint limit = SafeMath.min(offset.add(chunkSize), loans.length);
        uint[12][] memory response = new uint[12][](limit.sub(offset));
        uint currentRate = getCurrentRate();

        for (uint i = offset; i < limit; i++) {
            response[i - offset] = _getLoanTuple(i, currentRate);
        }
        return response;
    }

    function getLoanCountForAddress(address borrower) external view returns (uint) {
        return accountLoans[borrower].length;
    }

    /* returns <chunkSize> loans of a given account, starting from some <offset>. Loans data encoded as:
        [loanId, collateralAmount, repaymentAmount, borrower, productId, state, maturity, disbursementTime,
                                            loanAmount, interestAmount, marginCallRate, isCollectable] */
    function getLoansForAddress(address borrower, uint offset, uint16 chunkSize)
    external view returns (uint[12][]) {
        uint[] storage loansForAddress = accountLoans[borrower];
        uint limit = SafeMath.min(offset.add(chunkSize), loansForAddress.length);
        uint[12][] memory response = new uint[12][](limit.sub(offset));
        uint currentRate = getCurrentRate();

        for (uint i = offset; i < limit; i++) {
            response[i - offset] = _getLoanTuple(loansForAddress[i], currentRate);
        }
        return response;
    }

    function getLoanTuple(uint loanId) public view returns (uint[12] result) {
        return _getLoanTuple(loanId, getCurrentRate());
    }

    function _getLoanTuple(uint loanId, uint currentRate) internal view returns (uint[12] result) {
        require(loanId < loans.length, "invalid loanId"); // next line would revert but require to emit reason
        LoanData storage loan = loans[loanId];
        LoanProduct storage product = products[loan.productId];

        uint loanAmount;
        uint interestAmount;
        (loanAmount, interestAmount) = calculateLoanValues(product, loan.repaymentAmount);
        uint disbursementTime = loan.maturity - product.term;

        // Add extra calculated data for convenience: marginCallRate, isCollectable
        uint marginCallRate = calculateMarginCallRate(product.minCollateralRatio, loan.repaymentAmount, loan.collateralAmount);

        result = [loanId, loan.collateralAmount, loan.repaymentAmount, uint(loan.borrower),
            loan.productId, uint(loan.state), loan.maturity, disbursementTime, loanAmount, interestAmount,
            marginCallRate, isCollectable(loan, currentRate) ? 1 : 0];
    }

    function calculateLoanValues(LoanProduct storage product, uint repaymentAmount)
    internal view returns (uint loanAmount, uint interestAmount) {
        // calculate loan values based on repayment amount
        loanAmount = repaymentAmount.mul(product.discountRate).ceilDiv(PPM_FACTOR);
        interestAmount = loanAmount > repaymentAmount ? 0 : repaymentAmount.sub(loanAmount);
    }

    // the token/ETH rate of the margin, under which the loan can be "margin called" (collected)
    function calculateMarginCallRate(uint32 minCollateralRatio, uint repaymentAmount, uint collateralAmount)
    internal pure returns (uint) {
        return uint(minCollateralRatio).mul(repaymentAmount).mul(WEI_PER_PPM_FACTOR).div(collateralAmount);
    }

    function isUnderMargin(LoanData storage loan, uint currentRate)
    internal view returns (bool) {
        uint32 minCollateralRatio = products[loan.productId].minCollateralRatio;
        uint marginCallRate = calculateMarginCallRate(minCollateralRatio, loan.repaymentAmount, loan.collateralAmount);
        return minCollateralRatio > 0 && marginCallRate > 0 && currentRate < marginCallRate;
    }

    function isCollectable(LoanData storage loan, uint currentRate)
    internal view returns (bool) {
        return loan.state == LoanState.Open && (now >= loan.maturity || isUnderMargin(loan, currentRate));
    }

    // Returns the current token/ETH rate
    function getCurrentRate()
    internal view returns (uint) {
        (uint currentRate, ) = rates.rates(augmintToken.peggedSymbol());
        require(currentRate > 0, "No current rate available");
        return currentRate;
    }

    /* internal function, assuming repayment amount already transfered  */
    function _repayLoan(uint loanId, uint repaymentAmount) internal {
        require(loanId < loans.length, "invalid loanId"); // next line would revert but require to emit reason
        LoanData storage loan = loans[loanId];
        require(loan.state == LoanState.Open, "loan state must be Open");
        require(repaymentAmount == loan.repaymentAmount, "repaymentAmount must be equal to tokens sent");
        require(now <= loan.maturity, "current time must be earlier than maturity");

        LoanProduct storage product = products[loan.productId];
        uint loanAmount;
        uint interestAmount;
        (loanAmount, interestAmount) = calculateLoanValues(product, loan.repaymentAmount);

        loans[loanId].state = LoanState.Repaid;

        if (interestAmount > 0) {
            augmintToken.transfer(monetarySupervisor.interestEarnedAccount(), interestAmount);
            augmintToken.burn(loanAmount);
        } else {
            // negative or zero interest (i.e. discountRate >= 0)
            augmintToken.burn(repaymentAmount);
        }

        monetarySupervisor.loanRepaymentNotification(loanAmount); // update KPIs

        loan.borrower.transfer(loan.collateralAmount); // send back ETH collateral

        emit LoanRepaid(loanId, loan.borrower, getCurrentRate());
    }

    function _collectLoan(uint loanId, uint currentRate) private returns(uint loanAmount, uint defaultingFee, uint collateralToCollect) {
        LoanData storage loan = loans[loanId];
        require(isCollectable(loan, currentRate), "Not collectable");
        LoanProduct storage product = products[loan.productId];

        (loanAmount, ) = calculateLoanValues(product, loan.repaymentAmount);

        loan.state = LoanState.Collected;

        // send ETH collateral to augmintToken reserve
        // uint defaultingFeeInToken = loan.repaymentAmount.mul(product.defaultingFeePt).div(1000000);
        defaultingFee = _convertToWei(currentRate, loan.repaymentAmount.mul(product.defaultingFeePt).div(PPM_FACTOR));
        uint targetCollection = _convertToWei(currentRate, loan.repaymentAmount).add(defaultingFee);

        uint releasedCollateral;
        if (targetCollection < loan.collateralAmount) {
            releasedCollateral = loan.collateralAmount.sub(targetCollection);
            loan.borrower.transfer(releasedCollateral);
        }
        collateralToCollect = loan.collateralAmount.sub(releasedCollateral);
        if (defaultingFee >= collateralToCollect) {
            defaultingFee = collateralToCollect;
            collateralToCollect = 0;
        } else {
            collateralToCollect = collateralToCollect.sub(defaultingFee);
        }

        emit LoanCollected(loanId, loan.borrower, collateralToCollect.add(defaultingFee),
                releasedCollateral, defaultingFee, currentRate);
    }

    function _convertToWei(uint rate, uint tokenAmount) private pure returns(uint weiAmount) {
        return tokenAmount.mul(WEI_FACTOR).roundedDiv(rate);
    }

    function _convertFromWei(uint rate, uint weiAmount) private pure returns(uint tokenAmount) {
        return weiAmount.mul(rate).roundedDiv(WEI_FACTOR);
    }
}
