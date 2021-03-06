/* setup StabilityBoard signers in new StabilityBoardProxy on Rinkeby */

pragma solidity 0.4.24;

import "../../generic/MultiSig.sol";
import "../../StabilityBoardProxy.sol";


contract Rinkeby_0005_setupSigners {

    StabilityBoardProxy public constant STABILITY_BOARD_PROXY = StabilityBoardProxy(0xa612de13B629a1FF790c1f4E41d0422d2bB50a30);

    function execute(Rinkeby_0005_setupSigners /* self, not used */) external {
        // called via StabilityBoardProxy
        require(address(this) == address(STABILITY_BOARD_PROXY), "only execute via StabilityBoardProxy");

        address[] memory signersToAdd = new address[](2); // dynamic array needed for addSigners() & removeSigners()
        signersToAdd[0] = 0xe71E9636e31B838aF0A3c38B3f3449cdC2b7aa87;   // phraktle
        signersToAdd[1] = 0x9aaf197F25d207ecE17DfBeb20780095f7623A23;   // petro
        STABILITY_BOARD_PROXY.addSigners(signersToAdd);
    }
}