// SPDX-License-Identifier: MIT

pragma solidity ^0.6.8;

import "./BaseWBTCZing.sol";

contract SushiBadgerWbtcZing is BaseWBTCZing {

    function initialize(
        address _governance,
        address _rewards,
        address _exchange,
        address _wbtc,
        address _registry,
        uint256[3] memory _feeConfig
    ) public initializer {
        __BaseWBTCZing_init(
            _governance, 
            _rewards, 
            _exchange, 
            _wbtc,
            _registry, 
            _feeConfig
        );
    }

    function zing(
        address _destination,
        uint256 _slippage,
        // darknode args
        uint256 _amount,
        bytes32 _nHash,
        bytes calldata _sig
    ) external returns (uint256) {
        bytes32 pHash = keccak256(abi.encode(_destination));
        uint256 _mintAmount = _mintWBTC(pHash, _destination, _slippage, _amount, _nHash, _sig);
        require(_mintAmount == renBTC.balanceOf(address(this)), "zing unexpected mint amount");

        // Swap for badger and wbtc
    }
}
