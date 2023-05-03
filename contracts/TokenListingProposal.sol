// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import 'hardhat/console.sol';

contract TokenListingProposal is Initializable, UUPSUpgradeable, OwnableUpgradeable, AccessControlUpgradeable {
    bytes32 public constant ADMIN = keccak256("ADMIN");
    IERC20Upgradeable public asxAddress = IERC20Upgradeable(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48); // USDC
    address public incentiveTokenAddress; // адрес инсентив токена
    uint256 public destributionPeriod; // период, в течение которого после апрува будут рапределяться награды
    uint256 public proposalDeadline; // время, когда пропозал будет Removed
    uint256 public proposalCreationTimestamp; // timestamp создания пропозала
    uint256 public hostAmount; // сумма от которой юзер считается хостом

    uint256 approveAmount;
    uint256 removeAmount;

    uint256 public totalAsxOnProposalStakeAmount; // всего ASX застейкано на пропозале
    uint256 public incentiveTokenTotalAmount; // всего инсентив токенов застейкано на пропозале

    address public immutable SMART_CHEF_FACTORY; // The address of the smart chef factory
    enum State {
        Default,
        Approved,
        Removed
    }
    State state;

    struct StakeInfo {
        uint256 stakeAmount;
        uint256 stakeAmountWithTimeLock;
        uint256 unlockTimestamp;
        uint256 rewardTimestamp;
    }

    struct UserInfo {
        StakeInfo[] allStakes;
        uint256 totalStakeAmount;
        uint256 totalStakeAmountWithTimeLock;
        uint256 totalDiscountAmount;
        uint256 incentiveTokenAmount;
    }

    mapping(address => UserInfo) public accountsStakingInfo;

    event CreatedProposal(address incentivelToken, uint256 destributionPeriod, uint256 proposalDeadline);
    event CanApproveProposal(uint256 totalStakeAmount);
    event NeedApproveProposal(uint256 totalAsxOnProposalStakeAmount);
    event DepositOnProposal(uint256 amount);
    event ApprovedProposal(uint256 timestamp);
    event RemovedProposal(uint256 timestamp);

    modifier isApproved {
      require(state == State.Approved, "Not Approved");
      _;
    }

    modifier isRemoved {
      require(state == State.Removed, "Not Removed");
      _;
    }

    constructor() {
        SMART_CHEF_FACTORY = msg.sender;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function initialize(
        address _incentiveTokenAddress,
        uint256 _incentiveTokenAmount,
        uint256 _destributionPeriod,
        uint256 _proposalDeadline,
        uint256 _asxFee,
        address _admin
    ) external initializer {
        require(msg.sender == SMART_CHEF_FACTORY, "Not factory");

        // if (IERC20Upgradeable(_incentiveTokenAddress).allowance(msg.sender, address(this)) < _incentiveTokenAmount) {
        //     IERC20Upgradeable(_incentiveTokenAddress).approve(address(this), type(uint256).max);
        // } // It is does not work

        // if (asxAddress.allowance(msg.sender, address(0)) < _asxFee) {
        //     asxAddress.approve(address(0), type(uint256).max);
        // } Error: approve on 0 address

        // asxAddress.transferFrom(msg.sender, address(0), _asxFee); Error: transfer on 0 address (need burn)
        IERC20Upgradeable(_incentiveTokenAddress).transferFrom(msg.sender, address(this), _incentiveTokenAmount);

        incentiveTokenAddress = _incentiveTokenAddress;
        proposalDeadline = block.timestamp + _proposalDeadline;
        destributionPeriod = _destributionPeriod;
        accountsStakingInfo[msg.sender].incentiveTokenAmount += _incentiveTokenAmount;
        incentiveTokenTotalAmount += _incentiveTokenAmount;
        proposalCreationTimestamp = block.timestamp;

        state = State.Default;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        // transferOwnership(_admin);

        emit CreatedProposal(incentiveTokenAddress, destributionPeriod, proposalDeadline);
    }

    function stakeOnProposal(uint256 _amountToStake, uint256 _lockPeriod) external {
        require(state != State.Removed);
        // минимальная сумма стейка = минимальная сумма withdraw

        // if (IERC20Upgradeable(asxAddress).allowance(msg.sender, address(this)) < _amountToStake) {
        //     IERC20Upgradeable(asxAddress).approve(address(this), type(uint256).max);
        // }
        IERC20Upgradeable(asxAddress).transferFrom(msg.sender, address(this), _amountToStake);

        uint256 amountWithTimeLock;
        if (_lockPeriod >= 90 days) {
            amountWithTimeLock = (_amountToStake * 125) / 100;
        } else if (_lockPeriod >= 180 days) {
            amountWithTimeLock = (_amountToStake * 170) / 100;
        } else if (_lockPeriod >= 365 days) {
            amountWithTimeLock = _amountToStake * 3;
        } else if (_lockPeriod >= 730 days) {
            amountWithTimeLock = _amountToStake * 6;
        }

        totalAsxOnProposalStakeAmount += amountWithTimeLock;

        StakeInfo memory newStake = StakeInfo({
            stakeAmount: _amountToStake,
            stakeAmountWithTimeLock: amountWithTimeLock,
            unlockTimestamp: block.timestamp + _lockPeriod,
            rewardTimestamp: block.timestamp
        });
        accountsStakingInfo[msg.sender].allStakes.push(newStake);
        accountsStakingInfo[msg.sender].totalStakeAmount += _amountToStake;
        accountsStakingInfo[msg.sender].totalStakeAmountWithTimeLock += amountWithTimeLock;

        if (totalAsxOnProposalStakeAmount >= approveAmount) {
            emit CanApproveProposal(totalAsxOnProposalStakeAmount);
        }
    }

    function claimRewards() external isApproved {
        uint256 userReward = calcRewards();
        incentiveTokenTotalAmount -= userReward;

        asxAddress.transfer(msg.sender, userReward);
    }

    function compoundRewards() external {
        require(state == State.Approved);

        uint256 userReward = calcRewards();

        // Обменивает incentiveToken реварды на ASX и оставляет их на контракте
        // Увеличивает долю юзера в общем стейке пропозала
    }

    function calcRewards() public returns(uint256) {
        uint256 generelRewardPerSecond = incentiveTokenTotalAmount / destributionPeriod;
        uint256 userReward;
        for (uint256 i = 0; i < accountsStakingInfo[msg.sender].allStakes.length; i++) {
            uint256 stakeShareOfTotalStake = accountsStakingInfo[msg.sender].allStakes[i].stakeAmountWithTimeLock / totalAsxOnProposalStakeAmount;
            uint256 rewardPerSecondForStake;
            if (accountsStakingInfo[msg.sender].allStakes[i].rewardTimestamp < proposalCreationTimestamp) {
                rewardPerSecondForStake = generelRewardPerSecond * (block.timestamp - proposalCreationTimestamp) * stakeShareOfTotalStake;
            } else {
                rewardPerSecondForStake = generelRewardPerSecond * (block.timestamp - accountsStakingInfo[msg.sender].allStakes[i].rewardTimestamp) * stakeShareOfTotalStake;
            }
            userReward += rewardPerSecondForStake;
            accountsStakingInfo[msg.sender].allStakes[i].rewardTimestamp = block.timestamp;
        }
        return userReward;
    }

    function withdrawWhenApproved(uint256 _amount) external isApproved {
        // минимальная сумма стейка = минимальная сумма withdraw

        uint256 amountToWithdraw;
        uint256 amountToWithdrawWithTimeLock;
        for (uint256 i = 0; i < accountsStakingInfo[msg.sender].allStakes.length; i++) {
            if (accountsStakingInfo[msg.sender].allStakes[i].unlockTimestamp < block.timestamp) {
                if (amountToWithdraw < _amount) {
                    amountToWithdraw += accountsStakingInfo[msg.sender].allStakes[i].stakeAmount;
                    amountToWithdrawWithTimeLock += accountsStakingInfo[msg.sender].allStakes[i].stakeAmountWithTimeLock;
                    accountsStakingInfo[msg.sender].allStakes[i].stakeAmount = 0;
                    accountsStakingInfo[msg.sender].allStakes[i].stakeAmountWithTimeLock = 0;
                }
            }
        }
        require(amountToWithdraw >= _amount, "Can't withdraw this amount");

        uint256 newStakeAmount = amountToWithdraw - _amount;
        StakeInfo memory newStake = StakeInfo({
            stakeAmount: newStakeAmount,
            stakeAmountWithTimeLock: newStakeAmount,
            unlockTimestamp: block.timestamp,
            rewardTimestamp: block.timestamp
        });
        accountsStakingInfo[msg.sender].allStakes.push(newStake);
        accountsStakingInfo[msg.sender].totalStakeAmount -= _amount;
        accountsStakingInfo[msg.sender].totalStakeAmountWithTimeLock -= amountToWithdrawWithTimeLock;

        accountsStakingInfo[msg.sender].totalStakeAmount += newStakeAmount;
        accountsStakingInfo[msg.sender].totalStakeAmountWithTimeLock += newStakeAmount;

        totalAsxOnProposalStakeAmount -= amountToWithdrawWithTimeLock;
        totalAsxOnProposalStakeAmount += newStakeAmount;
        asxAddress.transfer(msg.sender, _amount);

        if (totalAsxOnProposalStakeAmount < removeAmount) {
            state = State.Removed;
            emit NeedApproveProposal(totalAsxOnProposalStakeAmount);
        }
    }

    function withdrawWhenRemoved() external isRemoved {
        uint256 amountToWithdraw = accountsStakingInfo[msg.sender].totalStakeAmount - (accountsStakingInfo[msg.sender].totalStakeAmount / 100);
        accountsStakingInfo[msg.sender].totalStakeAmount = 0;
        accountsStakingInfo[msg.sender].totalStakeAmountWithTimeLock = 0;

        totalAsxOnProposalStakeAmount -= accountsStakingInfo[msg.sender].totalStakeAmountWithTimeLock = 0;
        asxAddress.transfer(msg.sender, amountToWithdraw);
    }

    function withdrawIncentiveTokenWhenRemoved() external isRemoved {
        uint256 amountToWithdraw = accountsStakingInfo[msg.sender].incentiveTokenAmount;
        incentiveTokenTotalAmount -= amountToWithdraw;
        accountsStakingInfo[msg.sender].incentiveTokenAmount = 0;

        IERC20Upgradeable(incentiveTokenAddress).transfer(msg.sender, amountToWithdraw);
    }

    function depositIncentiveToken(uint256 _incentiveTokenAmount) external {
        if (IERC20Upgradeable(incentiveTokenAddress).allowance(msg.sender, address(this)) < _incentiveTokenAmount) {
            IERC20Upgradeable(incentiveTokenAddress).approve(address(this), type(uint256).max);
        }
        IERC20Upgradeable(incentiveTokenAddress).transferFrom(msg.sender, address(this), _incentiveTokenAmount);

        accountsStakingInfo[msg.sender].incentiveTokenAmount += _incentiveTokenAmount;
        incentiveTokenTotalAmount += _incentiveTokenAmount;
        emit DepositOnProposal(_incentiveTokenAmount);
    }

    function burnAsx(uint256 _amount) external isApproved {
        uint256 amountToBurn;
        uint256 amountToBurnWithTimeLock;
        // можно начинать цикл с последнего элемента, делая i-- 
        // Так как если юзер в самом начале застейкал ASX на год, то мы уменьшаем его долю с учетом Timlock Bonus
        // аналогично в функции withdrawWhenApproved
        for (uint256 i = 0; i < accountsStakingInfo[msg.sender].allStakes.length; i++) {
            if (amountToBurn < _amount) {
                amountToBurn += accountsStakingInfo[msg.sender].allStakes[i].stakeAmount;
                amountToBurnWithTimeLock += accountsStakingInfo[msg.sender].allStakes[i].stakeAmountWithTimeLock;
                accountsStakingInfo[msg.sender].allStakes[i].stakeAmount = 0;
                accountsStakingInfo[msg.sender].allStakes[i].stakeAmountWithTimeLock = 0;
            }
        }
        require(amountToBurn >= _amount, "Can't burn this amount");

        if (asxAddress.allowance(msg.sender, address(0)) < _amount) {
            asxAddress.approve(address(0), type(uint256).max);
        }

        asxAddress.transferFrom(msg.sender, address(0), _amount);

        uint256 newStakeAmount = amountToBurn - _amount;
        StakeInfo memory newStake = StakeInfo({
            stakeAmount: newStakeAmount,
            stakeAmountWithTimeLock: newStakeAmount,
            unlockTimestamp: block.timestamp,
            rewardTimestamp: block.timestamp
        });
        accountsStakingInfo[msg.sender].allStakes.push(newStake);
        accountsStakingInfo[msg.sender].totalStakeAmount -= _amount;
        accountsStakingInfo[msg.sender].totalStakeAmountWithTimeLock -= amountToBurnWithTimeLock;

        accountsStakingInfo[msg.sender].totalDiscountAmount += _amount;
        accountsStakingInfo[msg.sender].totalStakeAmount += newStakeAmount;
        accountsStakingInfo[msg.sender].totalStakeAmountWithTimeLock += newStakeAmount;

        totalAsxOnProposalStakeAmount -= amountToBurnWithTimeLock;
        totalAsxOnProposalStakeAmount += newStakeAmount;

        if (totalAsxOnProposalStakeAmount < removeAmount) {
            state = State.Removed;
            emit NeedApproveProposal(totalAsxOnProposalStakeAmount);
        }
    }

    function decreaseDiscountAmount(address _user, uint256 _amount) external onlyRole(ADMIN) {
        require(accountsStakingInfo[_user].totalDiscountAmount >= _amount, "Not enough discount amount");
        accountsStakingInfo[_user].totalDiscountAmount -= _amount;
    }

    function checkUserTier(address _user) external view returns (uint8 userTier) {
        uint256 userTotalStakeAmount = accountsStakingInfo[_user].totalStakeAmountWithTimeLock;

        if (userTotalStakeAmount < 10000) {
            return 0; // 0% discount
        } else if (userTotalStakeAmount < 20000) {
            return 1; // 10% fee discount
        }else if (userTotalStakeAmount < 30000) {
            return 2; // 15% fee discount
        } else if (userTotalStakeAmount < 40000) {
            return 3; // 30% fee discount
        } else if (userTotalStakeAmount >= 40000) {
            return 5; // 50% fee discount
        }
    }

    // Hosts
    function checkHost(address _user) external view returns (bool) {
        uint256 userTotalStakeAmount = accountsStakingInfo[_user].totalStakeAmountWithTimeLock;
        return userTotalStakeAmount >= hostAmount;
    }

    function checkHostTier(address _hostAddress) external view returns (uint8 hostTier) {
        uint256 userTotalStakeAmount = accountsStakingInfo[_hostAddress].totalStakeAmountWithTimeLock;

        // % of assetux profit from the pool with that host / % of volume minted as ASX to host
        if (userTotalStakeAmount < hostAmount + 10000) {
            return 0; // 10% / 0.1%
        } else if (userTotalStakeAmount < hostAmount + 20000) {
            return 1; // 20% / 0.2%
        }else if (userTotalStakeAmount < hostAmount + 30000) {
            return 2; // 30% / 0.3%
        } else if (userTotalStakeAmount < hostAmount + 40000) {
            return 3; // 40%% / 0.4%
        } else if (userTotalStakeAmount >= hostAmount + 40000) {
            return 5; // 50% / 0.5%
        }
    }

    // function mintAsxForHost(address _hostAddress, uint256 _amountToMint) external onlyRole(ADMIN) {
    //     asxAddress.mint(_hostAddress, _amountToMint);
    // }

    function approveProposal() external onlyRole(ADMIN) {
        require(totalAsxOnProposalStakeAmount >= approveAmount);
        require(proposalDeadline <= block.timestamp);

        state = State.Approved;
        emit ApprovedProposal(block.timestamp);
    }

    function removeProposal() external onlyRole(ADMIN) {
        require(proposalDeadline >= block.timestamp);

        state = State.Removed;
        emit RemovedProposal(block.timestamp);
    }

    function setHostAmount(uint256 _hostAmount) external onlyRole(ADMIN) {
        hostAmount = _hostAmount;
    }

    function setApproveAmount(uint256 _approveAmount) external onlyRole(ADMIN) {
      approveAmount = _approveAmount;
    }

    function setRemoveAmount(uint256 _removeAmount) external onlyRole(ADMIN) {
      removeAmount = _removeAmount;
    }
}
