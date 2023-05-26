// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./TokenListingProposal.sol";
import "hardhat/console.sol";

contract MasterChefProposal is Ownable {
    uint256 asxFee = 10000;
    event NewSmartChefContract(address indexed tokenListingProposal);

    function deployProposal(
        address _incentiveTokenAddress,
        uint256 _incentiveTokenAmount,
        uint256 _destributionPeriod,
        uint256 _proposalDeadline,
        address _admin
    ) external onlyOwner returns (address) {
        bytes32 salt = keccak256(
            abi.encodePacked(_incentiveTokenAddress, _destributionPeriod)
        );
        address tokenListingAddress;
        tokenListingAddress = address(new TokenListingProposal{salt: salt}());

        if (
            IERC20Upgradeable(_incentiveTokenAddress).allowance(
                address(this),
                tokenListingAddress
            ) < _incentiveTokenAmount
        ) {
            IERC20Upgradeable(_incentiveTokenAddress).approve(
                tokenListingAddress,
                type(uint256).max
            );
        }
        IERC20Upgradeable(_incentiveTokenAddress).transferFrom(
            msg.sender,
            tokenListingAddress,
            _incentiveTokenAmount
        );
        //  IERC20Upgradeable(_incentiveTokenAddress).transferFrom(tokenListingAddress, tokenListingAddress, _incentiveTokenAmount);

        TokenListingProposal(tokenListingAddress).initialize(
            _incentiveTokenAddress,
            _incentiveTokenAmount,
            _destributionPeriod,
            _proposalDeadline,
            asxFee,
            _admin
        );

        emit NewSmartChefContract(tokenListingAddress);
        return tokenListingAddress;
    }

    function setAsxFee(uint256 _asxFee) external onlyOwner {
        asxFee = _asxFee;
    }
}
