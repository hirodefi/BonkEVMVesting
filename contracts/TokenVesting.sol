// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title TokenVesting
 * @dev A contract for vesting ERC20 tokens with linear or step-based release schedules
 */
contract TokenVesting is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum ReleaseType {
        LINEAR,
        STEP_BASED
    }

    enum ReleaseFrequency {
        MINUTELY,
        HOURLY,
        DAILY,
        WEEKLY,
        MONTHLY
    }

    enum VestingStatus {
        ACTIVE,
        COMPLETED
    }

    struct Vesting {
        uint256 id;
        address creator;
        address token;
        address beneficiary;
        uint256 totalAmount;
        uint256 startTime;
        uint256 endTime;
        ReleaseType releaseType;
        ReleaseFrequency releaseFrequency;
        uint256 amountReleased;
        VestingStatus status;
    }

    // State variables
    uint256 private _nextVestingId;
    mapping(uint256 => Vesting) public vestings;
    mapping(address => uint256[]) private _creatorVestings;
    mapping(address => uint256[]) private _beneficiaryVestings;

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

    /**
     * @dev Creates a new vesting schedule
     * @param token The ERC20 token to vest
     * @param beneficiary The address that will receive tokens (use address(0) for creator)
     * @param totalAmount Total amount of tokens to vest
     * @param startTime Unix timestamp when vesting starts
     * @param endTime Unix timestamp when vesting ends
     * @param releaseType LINEAR or STEP_BASED
     * @param releaseFrequency MINUTELY, HOURLY, DAILY, WEEKLY, or MONTHLY (for step-based)
     */
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

        // If no beneficiary provided, use creator
        address actualBeneficiary = beneficiary == address(0) ? msg.sender : beneficiary;

        // Transfer tokens from creator to this contract
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

    /**
     * @dev Claims vested tokens for a specific vesting schedule
     * @param vestingId The ID of the vesting schedule
     */
    function claim(uint256 vestingId) external nonReentrant {
        Vesting storage vesting = vestings[vestingId];
        require(vesting.id == vestingId, "Vesting does not exist");
        require(msg.sender == vesting.beneficiary, "Only beneficiary can claim");
        require(vesting.status == VestingStatus.ACTIVE, "Vesting is not active");

        uint256 claimable = getClaimableAmount(vestingId);
        require(claimable > 0, "No tokens available to claim");

        vesting.amountReleased += claimable;

        // Check if vesting is completed
        if (vesting.amountReleased >= vesting.totalAmount) {
            vesting.status = VestingStatus.COMPLETED;
            emit VestingCompleted(vestingId);
        }

        IERC20(vesting.token).safeTransfer(vesting.beneficiary, claimable);

        emit TokensClaimed(vestingId, vesting.beneficiary, claimable);
    }

    /**
     * @dev Calculates the amount of tokens that can be claimed
     * @param vestingId The ID of the vesting schedule
     * @return The amount of tokens available to claim
     */
    function getClaimableAmount(uint256 vestingId) public view returns (uint256) {
        Vesting memory vesting = vestings[vestingId];

        if (vesting.status != VestingStatus.ACTIVE) {
            return 0;
        }

        if (block.timestamp < vesting.startTime) {
            return 0;
        }

        uint256 vestedAmount;

        if (block.timestamp >= vesting.endTime) {
            // All tokens are vested
            vestedAmount = vesting.totalAmount;
        } else {
            if (vesting.releaseType == ReleaseType.LINEAR) {
                // Linear vesting: proportional to time elapsed
                uint256 timeElapsed = block.timestamp - vesting.startTime;
                uint256 totalTime = vesting.endTime - vesting.startTime;
                vestedAmount = (vesting.totalAmount * timeElapsed) / totalTime;
            } else {
                // Step-based vesting: tokens unlock at intervals
                vestedAmount = _calculateStepBasedVesting(vesting);
            }
        }

        return vestedAmount - vesting.amountReleased;
    }

    /**
     * @dev Calculates vested amount for step-based vesting
     * @param vesting The vesting schedule
     * @return The total vested amount
     */
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

    /**
     * @dev Returns all vesting IDs created by a specific address
     * @param creator The creator address
     * @return Array of vesting IDs
     */
    function getVestingsByCreator(address creator) external view returns (uint256[] memory) {
        return _creatorVestings[creator];
    }

    /**
     * @dev Returns all vesting IDs where an address is the beneficiary
     * @param beneficiary The beneficiary address
     * @return Array of vesting IDs
     */
    function getVestingsByBeneficiary(address beneficiary) external view returns (uint256[] memory) {
        return _beneficiaryVestings[beneficiary];
    }

    /**
     * @dev Returns detailed information about a vesting schedule
     * @param vestingId The ID of the vesting schedule
     * @return The vesting details
     */
    function getVesting(uint256 vestingId) external view returns (Vesting memory) {
        require(vestings[vestingId].id == vestingId, "Vesting does not exist");
        return vestings[vestingId];
    }

    /**
     * @dev Returns all vesting schedules (for admin view)
     * @return Array of all vestings
     */
    function getAllVestings() external view returns (Vesting[] memory) {
        Vesting[] memory allVestings = new Vesting[](_nextVestingId);

        for (uint256 i = 0; i < _nextVestingId; i++) {
            allVestings[i] = vestings[i];
        }

        return allVestings;
    }

    /**
     * @dev Returns the total number of vesting schedules
     * @return The total count
     */
    function getTotalVestings() external view returns (uint256) {
        return _nextVestingId;
    }
}
