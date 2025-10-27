// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// token vesting contract - lock tokens, release over time
// two modes: linear (smooth release) or steps (chunks at intervals)
contract TokenVesting is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum ReleaseType {
        LINEAR,        // smooth release over time
        STEP_BASED     // chunks at set intervals
    }

    enum ReleaseFrequency {
        MINUTELY,      // for testing
        HOURLY,        // for testing
        DAILY,         // normal use
        WEEKLY,        // normal use
        MONTHLY        // normal use
    }

    enum VestingStatus {
        ACTIVE,
        COMPLETED
    }

    struct Vesting {
        uint256 id;
        address creator;          // who made it
        address token;            // what token
        address beneficiary;      // who gets it
        uint256 totalAmount;      // how much total
        uint256 startTime;        // when it starts
        uint256 endTime;          // when it ends
        ReleaseType releaseType;  // how it releases
        ReleaseFrequency releaseFrequency;  // step frequency if step-based
        uint256 amountReleased;   // already claimed
        VestingStatus status;     // active or done
    }

    // track everything
    uint256 private _nextVestingId;
    mapping(uint256 => Vesting) public vestings;
    mapping(address => uint256[]) private _creatorVestings;     // vestings by creator
    mapping(address => uint256[]) private _beneficiaryVestings; // vestings by receiver

    // Events
    event VestingCreated(
        uint256 indexed vestingId,
        address indexed creator,
        address indexed beneficiary,
        address token,
        uint256 amount,
        uint256 startTime,
        uint256 endTime
    );

    event TokensClaimed(
        uint256 indexed vestingId,
        address indexed beneficiary,
        uint256 amount
    );

    event VestingCompleted(uint256 indexed vestingId);

    // create new vesting - locks tokens from creator, releases to beneficiary over time
    // pass address(0) as beneficiary to vest to yourself
    function createVesting(
        address token,
        address beneficiary,
        uint256 totalAmount,
        uint256 startTime,
        uint256 endTime,
        ReleaseType releaseType,
        ReleaseFrequency releaseFrequency
    ) external nonReentrant returns (uint256) {
        require(token != address(0), "Invalid token address");
        require(totalAmount > 0, "Amount must be greater than 0");
        require(startTime >= block.timestamp, "Start time must be in the future");
        require(endTime > startTime, "End time must be after start time");

        // default to self if no beneficiary
        address actualBeneficiary = beneficiary == address(0) ? msg.sender : beneficiary;

        // pull tokens from creator
        IERC20(token).safeTransferFrom(msg.sender, address(this), totalAmount);

        uint256 vestingId = _nextVestingId++;

        vestings[vestingId] = Vesting({
            id: vestingId,
            creator: msg.sender,
            token: token,
            beneficiary: actualBeneficiary,
            totalAmount: totalAmount,
            startTime: startTime,
            endTime: endTime,
            releaseType: releaseType,
            releaseFrequency: releaseFrequency,
            amountReleased: 0,
            status: VestingStatus.ACTIVE
        });

        _creatorVestings[msg.sender].push(vestingId);
        _beneficiaryVestings[actualBeneficiary].push(vestingId);

        emit VestingCreated(
            vestingId,
            msg.sender,
            actualBeneficiary,
            token,
            totalAmount,
            startTime,
            endTime
        );

        return vestingId;
    }

    // claim unlocked tokens - only beneficiary can call this
    function claim(uint256 vestingId) external nonReentrant {
        Vesting storage vesting = vestings[vestingId];
        require(vesting.id == vestingId, "Vesting does not exist");
        require(msg.sender == vesting.beneficiary, "Only beneficiary can claim");
        require(vesting.status == VestingStatus.ACTIVE, "Vesting is not active");

        uint256 claimable = getClaimableAmount(vestingId);
        require(claimable > 0, "No tokens available to claim");

        vesting.amountReleased += claimable;

        // mark complete if all tokens claimed
        if (vesting.amountReleased >= vesting.totalAmount) {
            vesting.status = VestingStatus.COMPLETED;
            emit VestingCompleted(vestingId);
        }

        IERC20(vesting.token).safeTransfer(vesting.beneficiary, claimable);

        emit TokensClaimed(vestingId, vesting.beneficiary, claimable);
    }

    // check how many tokens are claimable right now
    function getClaimableAmount(uint256 vestingId) public view returns (uint256) {
        Vesting memory vesting = vestings[vestingId];

        if (vesting.status != VestingStatus.ACTIVE) {
            return 0;
        }

        if (block.timestamp < vesting.startTime) {
            return 0;  // hasn't started yet
        }

        uint256 vestedAmount;

        if (block.timestamp >= vesting.endTime) {
            // past end time - everything is vested
            vestedAmount = vesting.totalAmount;
        } else {
            if (vesting.releaseType == ReleaseType.LINEAR) {
                // linear - smooth proportional release
                uint256 timeElapsed = block.timestamp - vesting.startTime;
                uint256 totalTime = vesting.endTime - vesting.startTime;
                vestedAmount = (vesting.totalAmount * timeElapsed) / totalTime;
            } else {
                // step-based - chunks at intervals
                vestedAmount = _calculateStepBasedVesting(vesting);
            }
        }

        return vestedAmount - vesting.amountReleased;
    }

    // calculate step-based vesting - tokens unlock at set intervals
    function _calculateStepBasedVesting(Vesting memory vesting) private view returns (uint256) {
        uint256 intervalDuration;

        if (vesting.releaseFrequency == ReleaseFrequency.MINUTELY) {
            intervalDuration = 1 minutes;
        } else if (vesting.releaseFrequency == ReleaseFrequency.HOURLY) {
            intervalDuration = 1 hours;
        } else if (vesting.releaseFrequency == ReleaseFrequency.DAILY) {
            intervalDuration = 1 days;
        } else if (vesting.releaseFrequency == ReleaseFrequency.WEEKLY) {
            intervalDuration = 7 days;
        } else {
            intervalDuration = 30 days; // MONTHLY
        }

        uint256 timeElapsed = block.timestamp - vesting.startTime;
        uint256 totalDuration = vesting.endTime - vesting.startTime;
        uint256 totalIntervals = totalDuration / intervalDuration;

        if (totalIntervals == 0) {
            totalIntervals = 1;
        }

        uint256 intervalsCompleted = timeElapsed / intervalDuration;

        if (intervalsCompleted >= totalIntervals) {
            return vesting.totalAmount;
        }

        uint256 amountPerInterval = vesting.totalAmount / totalIntervals;
        return intervalsCompleted * amountPerInterval;
    }

    // get all vestings created by an address
    function getVestingsByCreator(address creator) external view returns (uint256[] memory) {
        return _creatorVestings[creator];
    }

    // get all vestings where address is beneficiary
    function getVestingsByBeneficiary(address beneficiary) external view returns (uint256[] memory) {
        return _beneficiaryVestings[beneficiary];
    }

    // get full vesting details
    function getVesting(uint256 vestingId) external view returns (Vesting memory) {
        require(vestings[vestingId].id == vestingId, "Vesting does not exist");
        return vestings[vestingId];
    }

    // get all vestings - for admin view
    function getAllVestings() external view returns (Vesting[] memory) {
        Vesting[] memory allVestings = new Vesting[](_nextVestingId);

        for (uint256 i = 0; i < _nextVestingId; i++) {
            allVestings[i] = vestings[i];
        }

        return allVestings;
    }

    // get total vesting count
    function getTotalVestings() external view returns (uint256) {
        return _nextVestingId;
    }
}
