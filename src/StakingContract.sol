// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract StakingContract is ReentrancyGuard, Ownable {
    IERC20 public basicToken;

    uint256 public totalStaked;
    uint256 public rewardRate;  // The rate of reward per second.
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public unstakeTimeLock = 15 days; // Default time lock for unstaking
    uint256 public unstakeFeePercent = 0; // Fee for unstaking early, in basis points
    uint256 public emissionStart;
    uint256 public emissionEnd;

    struct Staker {
        uint256 amountStaked;
        uint256 rewardDebt;
        uint256 rewards;
        uint256 unstakeInitTime; // Time when the user initiated unstaking
    }

    mapping(address => Staker) public stakers;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event UnstakeInitiated(address indexed user);

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastApplicableTime();
        if (account != address(0)) {
            stakers[account].rewards = earned(account);
            stakers[account].rewardDebt = rewardPerTokenStored;
        }
        _;
    }

    constructor(IERC20 _basicToken, uint256 _rewardRate, uint256 _emissionDuration) Ownable(msg.sender) {
        basicToken = _basicToken;
        rewardRate = _rewardRate;
        emissionStart = block.timestamp;
        emissionEnd = emissionStart + _emissionDuration;
    }

    function lastApplicableTime() public view returns (uint256) {
        return block.timestamp < emissionEnd ? block.timestamp : emissionEnd;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored + (
            (lastApplicableTime() - lastUpdateTime) * rewardRate * 1e18 / totalStaked
        );
    }

    // function earned(address account) public view returns (uint256) {
        //return (
        //    stakers[account].amountStaked * (rewardPerToken() - stakers[account].rewardDebt) / 1e18
        //) + stakers[account].rewards;
   // }

    function earned(address account) public view returns (uint256) {
        Staker storage staker = stakers[account];
        uint256 lastTimeRewardApplicable = lastApplicableTime();
        if (staker.unstakeInitTime != 0 && staker.unstakeInitTime < lastTimeRewardApplicable) {
            lastTimeRewardApplicable = staker.unstakeInitTime;
        }
        return (
            staker.amountStaked *
            (rewardPerToken() - staker.rewardDebt) / 1e18
        ) + staker.rewards;
    }

    function stake(uint256 _amount) external nonReentrant updateReward(msg.sender) {
        require(_amount > 0, "Cannot stake 0");
        Staker storage staker = stakers[msg.sender];
        require(staker.unstakeInitTime == 0, "Cannot stake after initiating unstake.");
        totalStaked += _amount;
        staker.amountStaked += _amount;
        require(basicToken.transferFrom(msg.sender, address(this), _amount), "Token deposit failed");
        emit Staked(msg.sender, _amount);
    }

    function initiateUnstake() external nonReentrant updateReward(msg.sender) {
        Staker storage staker = stakers[msg.sender];
        require(staker.amountStaked > 0, "No tokens staked");
        require(staker.unstakeInitTime == 0, "Unstake already initiated");
        staker.unstakeInitTime = block.timestamp;
        emit UnstakeInitiated(msg.sender);
    }

    function completeUnstake() external nonReentrant updateReward(msg.sender) {
        Staker storage staker = stakers[msg.sender];
        require(staker.amountStaked > 0, "No tokens staked");
        require(block.timestamp >= staker.unstakeInitTime + unstakeTimeLock, "Timelock not yet passed");

        uint256 amount = staker.amountStaked;
        uint256 reward = staker.rewards;
        uint256 fee = amount * unstakeFeePercent / 10000;
        uint256 amountAfterFee = amount - fee;

        totalStaked -= amount;
        
        // If there are rewards, combine them with the staked amount after fees for a single transfer
        if (reward > 0) {
            uint256 totalAmount = amountAfterFee + reward;
            require(basicToken.transfer(msg.sender, totalAmount), "Transfer failed");
            staker.rewards = 0; // Reset rewards
            emit RewardPaid(msg.sender, reward);
        } else {
            // If there are no rewards, just transfer the staked amount after fees
            require(basicToken.transfer(msg.sender, amountAfterFee), "Unstake transfer failed");
        }

        delete stakers[msg.sender]; // Cleanup staker info

        emit Unstaked(msg.sender, amount);
    }

    function claimReward() external nonReentrant updateReward(msg.sender) {
        uint256 reward = stakers[msg.sender].rewards;
        if (reward > 0) {
            stakers[msg.sender].rewards = 0;
            require(basicToken.transfer(msg.sender, reward), "Reward transfer failed");
            emit RewardPaid(msg.sender, reward);
        }
    }

    function setUnstakeFeePercent(uint256 _newFee) external onlyOwner {
        require(_newFee <= 200, "Unstake fee exceeds 2%, maximum allowed"); // Assuming basis points
        unstakeFeePercent = _newFee;
    }

    function setUnstakeTimeLock(uint256 _newTimeLock) external onlyOwner {
        require(_newTimeLock <= 15 days, "Time lock must be between 0 to 15 days");
        unstakeTimeLock = _newTimeLock;
    }

    function getRemainingUnstakeTime(address _staker) external view returns (uint256) {
        Staker storage staker = stakers[_staker];
        if (block.timestamp < staker.unstakeInitTime + unstakeTimeLock) {
            return (staker.unstakeInitTime + unstakeTimeLock) - block.timestamp;
        } else {
            return 0;
        }
    }

    // Optionally, a function to allow the owner to update emission details
    function setEmissionDetails(uint256 _rewardRate, uint256 _emissionDuration) external onlyOwner {
        rewardRate = _rewardRate;
        emissionEnd = block.timestamp + _emissionDuration;
    }
}