// SPDX-License-Identifier: MIT

pragma solidity ^0.6.8;

import "deps/@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "deps/@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "deps/@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "deps/@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "deps//@openzeppelin/contracts/access/Ownable.sol";

interface IGateway {
    function mint(
        bytes32 _pHash,
        uint256 _amount,
        bytes32 _nHash,
        bytes calldata _sig
    ) external returns (uint256);

    function burn(bytes calldata _to, uint256 _amount) external returns (uint256);
}

interface IGatewayRegistry {
    function getGatewayBySymbol(string calldata _tokenSymbol) external view returns (IGateway);

    function getGatewayByToken(address _tokenAddress) external view returns (IGateway);

    function getTokenBySymbol(string calldata _tokenSymbol) external view returns (IERC20);
}

interface ICurveExchange {
    function exchange(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 min_dy
    ) external;

    function get_dy(
        int128,
        int128 j,
        uint256 dx
    ) external view returns (uint256);

    function calc_token_amount(uint256[2] calldata amounts, bool deposit) external returns (uint256 amount);

    function add_liquidity(uint256[2] calldata amounts, uint256 min_mint_amount) external;

    function remove_liquidity(uint256 _amount, uint256[2] calldata min_amounts) external;

    function remove_liquidity_imbalance(uint256[2] calldata amounts, uint256 max_burn_amount) external;

    function remove_liquidity_one_coin(
        uint256 _token_amounts,
        int128 i,
        uint256 min_amount
    ) external;
}

// BaseWBTCZing allows native BTC -> wBTC "zings" straight into a sett.
contract BaseWBTCZing is OwnableUpgradeable {
    using SafeMathUpgradeable for uint256;
    using SafeERC20 for IERC20;

    IERC20 renBTC;
    IERC20 wBTC;

    // RenVM gateway registry.
    IGatewayRegistry public registry;
    // Curve exchange contract for the renBTC/wBTC pool.
    ICurveExchange public exchange;

    event RecoverStuck(uint256 amount);
    event MintWBTC(uint256 renbtc_minted, uint256 wbtc_exchanged, uint256 fee);
    event MintRenBTC(uint256 amount, uint256 fee);
    event ExchangeWBTCBytesError(bytes error);
    event ExchangeWBTCStringError(string error);

    address public rewards;
    address public governance;

    uint256 public mintFeeBps;
    uint256 private percentageFeeRewardsBps;
    uint256 private percentageFeeGovernanceBps;

    uint256 public constant MAX_BPS = 10000;

    function __BaseWBTCZing_init(
        address _governance,
        address _rewards,
        address _exchange,
        address _wbtc,
        address _registry,
        uint256[3] memory _feeConfig
    ) public initializer {
        governance = _governance;
        rewards = _rewards;

        registry = IGatewayRegistry(_registry);
        exchange = ICurveExchange(_exchange);
        renBTC = registry.getTokenBySymbol("BTC");
        wBTC = IERC20(_wbtc);

        mintFeeBps = _feeConfig[0];
        percentageFeeRewardsBps = _feeConfig[1];
        percentageFeeGovernanceBps = _feeConfig[2];
    }

    function recoverStuck(
        bytes calldata encoded,
        uint256 _amount,
        bytes32 _nHash,
        bytes calldata _sig
    ) external {
        // Ensure sender matches sender of original tx.
        uint256 start = encoded.length - 32;
        address sender = abi.decode(encoded[start:], (address));
        require(sender == msg.sender);

        bytes32 pHash = keccak256(encoded);
        uint256 _mintAmount = registry.getGatewayBySymbol("BTC").mint(pHash, _amount, _nHash, _sig);

        emit RecoverStuck(_mintAmount);

        renBTC.safeTransfer(msg.sender, _mintAmount);
    }

    // _mintWBTC mints wBTC which can be used by the parent contract to convert to lp tokens and deposit into sett.
    function _mintWBTC(
        // payload hash of all args user/darknode supplied (in case child contracts want to supply additional args)
        bytes32 pHash,
        address _destination,
        uint256 _slippage,
        // darknode args
        uint256 _amount,
        bytes32 _nHash,
        bytes calldata _sig
    ) internal returns (uint256) {
        // Mint renBTC tokens
        uint256 _mintAmount = registry.getGatewayBySymbol("BTC").mint(pHash, _amount, _nHash, _sig);

        // Get price
        uint256 dy = exchange.get_dy(0, 1, _mintAmount);
        _slippage = uint256(1e4).sub(_slippage);
        uint256 min_dy = dy.mul(_slippage).div(1e4);

        uint256 _startBalance = wBTC.balanceOf(address(this));
        try exchange.exchange(0, 1, _mintAmount, min_dy)  {
            uint256 _endBalance = wBTC.balanceOf(address(this));
            uint256 _wbtcAmount = _endBalance.sub(_startBalance);
            uint256 _fee = _processFee(wBTC, _wbtcAmount, mintFeeBps);
            emit MintWBTC(_mintAmount, _wbtcAmount, _fee);

            // Send converted wBTC to user.
            require(wBTC.transfer(_destination, _wbtcAmount.sub(_fee)));
        } catch Error(string memory _error) {
            emit ExchangeWBTCStringError(_error);
            _fallbackTransferRenBTC(_destination, _mintAmount);
        } catch (bytes memory _error) {
            emit ExchangeWBTCBytesError(_error);
            _fallbackTransferRenBTC(_destination, _mintAmount);
        }
    }

    // _fallbackTransferRenBTC transfers minted renBTC to user when an exchange fails.
    function _fallbackTransferRenBTC(address _destination, uint256 _amount) internal {
            uint256 _fee = _processFee(renBTC, _amount, mintFeeBps);
            emit MintRenBTC(_amount, _fee);
            require(renBTC.transfer(_destination, _amount.sub(_fee)));
    }

    function _processFee(
        IERC20 token,
        uint256 amount,
        uint256 feeBps
    ) internal returns (uint256) {
        if (feeBps == 0) {
            return 0;
        }
        uint256 fee = amount.mul(feeBps).div(MAX_BPS);
        uint256 governanceFee = fee.mul(percentageFeeGovernanceBps).div(MAX_BPS);
        uint256 rewardsFee = fee.mul(percentageFeeRewardsBps).div(MAX_BPS);
        IERC20(token).safeTransfer(governance, governanceFee);
        IERC20(token).safeTransfer(rewards, rewardsFee);
        return fee;
    }

    // Admin methods.
    function setMintFeeBps(uint256 _mintFeeBps) external onlyOwner {
        require(_mintFeeBps <= MAX_BPS, "badger-ren-adapter/excessive-mint-fee");
        mintFeeBps = _mintFeeBps;
    }

    function setPercentageFeeGovernanceBps(uint256 _percentageFeeGovernanceBps) external onlyOwner {
        require(_percentageFeeGovernanceBps + percentageFeeRewardsBps <= MAX_BPS,
            "badger-ren-adapter/excessive-percentage-fee-governance");
        percentageFeeGovernanceBps = _percentageFeeGovernanceBps;
    }

    function setPercentageFeeRewardsBps(uint256 _percentageFeeRewardsBps) external onlyOwner {
        require(_percentageFeeRewardsBps + percentageFeeGovernanceBps <= MAX_BPS,
            "badger-ren-adapter/excessive-percentage-fee-rewards");
        percentageFeeRewardsBps = _percentageFeeRewardsBps;
    }

    function setRewards(address _rewards) external onlyOwner {
        rewards = _rewards;
    }
}
